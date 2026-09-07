/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

/*
 * T17 / Wave 3: VMX nested-virt register-virt tests.
 *
 * Five kernel-side sanity checks for the register-virtualization
 * additions to the VMX (Intel) nested-virt path.  The module runs
 * every test at kldload(8) time and prints PASS/FAIL/SKIP lines to
 * dmesg with a final "N/5 PASS" summary.
 *
 * Test map (see sys/amd64/vmm/intel/vmx.c, vmx.h, vmx_msr.c):
 *   1. MSR_VMX_BASIC reads back non-zero (regression for the old
 *      "vmm_dev_machdep.c wrote 0 to the rdmsr handler" bug).
 *   2. vmx_nested_status sysctl == 1 -> nested hardware ready
 *      (skipped when vmm.ko is not loaded).
 *   3. struct vmx_vcpu carries the per-vCPU nvmcs12 shadow region,
 *      and that struct vmcs is exactly PAGE_SIZE (which the
 *      vmx_vcpu_init() allocator in vmx.c relies on).
 *   4. CR4.VMXE is the well-known 0x2000 bit and can be set on the
 *      host CR4 (i.e. the host CPU genuinely has VMX enabled).
 *   5. MSR_VMX_CR0_FIXED0 forces PE (bit 0) and PG (bit 31);
 *      MSR_VMX_CR0_FIXED1 is non-zero (architectural sanity).
 */

#include <sys/param.h>
#include <sys/kernel.h>
#include <sys/malloc.h>
#include <sys/module.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/systm.h>

#include <machine/cpufunc.h>
#include <machine/specialreg.h>
#include <x86/x86_var.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/vmm.h>

/*
 * Forward-declare struct seg_desc and struct vcpu before pulling in
 * vmcs.h / x86.h.  vmcs.h declares prototypes
 * (vmcs_getdesc/vmcs_setdesc) whose parameter type is
 * `struct seg_desc *`; x86.h declares x86_emulate_cpuid and
 * vm_cpuid_capability with `struct vcpu *` parameters.  Both
 * structs are otherwise defined further along the include chain
 * (via sys/dev/vmm/vmm_vm.h), but the visibility warning fires at
 * the prototype site.  Forward declarations keep -Werror
 * -Wvisibility quiet when the kernel module is built in isolation
 * (without the full vmm.ko SRCS set).
 */
struct seg_desc;
struct vcpu;

#include "vmcs.h"
#include "vmx.h"
#include "vmx_nested.h"
#include "vmx_nested_layout.h"

/*
 * Compile-time guarantees about the nested-VMX additions.  Both
 * predicates must hold for vmcs12 allocation to work (T15).
 *
 * - struct vmcs must be exactly PAGE_SIZE (declared in vmcs.h).
 * - struct vmx_vcpu must carry the nvmcs12 pointer (T15).
 *
 * If either invariant is violated the test module refuses to load
 * so a future regression is caught at kldload time, not at first
 * nested-enabled VM launch.
 */
CTASSERT(sizeof(struct vmcs) == PAGE_SIZE);
CTASSERT(__offsetof(struct vmx_vcpu, nvmcs12) != __offsetof(struct vmx_vcpu, vmcs));

/*
 * vmx_nested_status lives in sys/amd64/vmm/intel/vmx.c as the
 * canonical read-only gate for "this host's VMX can back a nested
 * guest".  It is a boolean:
 *   0 = the CPU does not have what the nested paths need
 *   1 = ready
 *
 * We intentionally do not take a hard extern dependency on the
 * variable: reading it indirectly through the hw.vmm.nested.vmx
 * sysctl lets the test module load against any vmm.ko (including
 * an upstream one without nested-virt additions) and SKIP cleanly
 * when the sysctl is missing.
 */

/*
 * vmxtest_vmm_loaded
 *
 * Return non-zero if vmm.ko is currently loaded, zero otherwise.
 *
 * Probe via kernel_sysctlbyname("hw.vmm.vmx.initialized", ...).
 * That sysctl is registered by vmm.ko's MOD_LOAD path; if the
 * lookup returns ENOENT the module is not loaded.  This avoids
 * module_lookupbyname(), which would require holding modules_sx
 * (a sleepable sx lock that is not safe to acquire during another
 * module's MOD_LOAD callback).
 */
static int
vmxtest_vmm_loaded(void)
{
	uint32_t init;
	size_t initlen;

	init = 0;
	initlen = sizeof(init);
	if (kernel_sysctlbyname(&thread0, "hw.vmm.vmx.initialized", &init,
	    &initlen, NULL, 0, NULL, 0) == 0)
		return (1);
	return (0);
}

static int vmxtest_pass;
static int vmxtest_fail;
static int vmxtest_skip;

#define	VMXTEST_PASS(n)	do {						\
	printf("vmx_nested_test: PASS test-%d\n", (n));		\
	vmxtest_pass++;						\
} while (0)

#define	VMXTEST_FAIL(n, fmt, ...)	do {				\
	printf("vmx_nested_test: FAIL test-%d " fmt "\n",		\
	    (n), ## __VA_ARGS__);				\
	vmxtest_fail++;						\
} while (0)

#define	VMXTEST_SKIP(n, fmt, ...)	do {				\
	printf("vmx_nested_test: SKIP test-%d " fmt "\n",		\
	    (n), ## __VA_ARGS__);				\
	vmxtest_skip++;						\
} while (0)

/*
 * Test 1: VMX-capability MSR (MSR_VMX_BASIC 0x480) reads back non-zero.
 *
 * Historical regression: an early wave-3 prototype returned 0 from
 * the capability-MSR read handler, which caused bhyve to think the
 * host had no VMX support and refuse to start.  Verify the live MSR
 * returns something with the revision-ID high-bit pattern that all
 * production Intel parts set in MSR_VMX_BASIC[30:0].
 */
static int
vmxtest_is_intel(void)
{

	return (strcmp(cpu_vendor, "GenuineIntel") == 0);
}

static void
vmxtest_cap_msr_read(void)
{
	uint64_t basic;
	uint32_t revid;

	if (!vmxtest_is_intel()) {
		VMXTEST_SKIP(1, "not Intel; skip VMX MSRs");
		return;
	}

	basic = rdmsr(MSR_VMX_BASIC);
	if (basic == 0) {
		VMXTEST_FAIL(1, "MSR_VMX_BASIC=0 (regression: rdmsr returns zero)");
		return;
	}
	revid = (uint32_t)(basic & 0xffffffff);
	if ((revid & 0x80000000U) != 0) {
		/*
		 * Bits 30:0 are the VMCS revision
		 * identifier; bit 31 is reserved and must be 0.
		 */
		VMXTEST_FAIL(1,
		    "MSR_VMX_BASIC reserved bit 31 set: revid=%#x",
		    revid);
		return;
	}
	if ((revid & 0x7fffffffU) == 0) {
		VMXTEST_FAIL(1, "MSR_VMX_BASIC revision-id bits 30:0 zero");
		return;
	}
	printf("vmx_nested_test: test-1 MSR_VMX_BASIC=%#lx revid=%#x\n",
	    (unsigned long)basic, revid);
	VMXTEST_PASS(1);
}

/*
 * Test 2: nested hardware gate (vmx_nested_status).
 *
 * This is the value exposed by hw.vmm.nested.vmx: 1 means the CPU has
 * the VMX features the nested paths need (EPT and unrestricted guest),
 * so an L1 guest can be nested-virtualized.  0 means it does not.
 * The probe deliberately does not test for bare metal, so a guest with
 * VMX exposed to it also reports 1 and can host a deeper guest.
 *
 * Skipped when vmm.ko is not loaded because vmx_nested_status is
 * only initialized in vmx_init(); the variable is in BSS until
 * then.
 */
static void
vmxtest_nested_gate(void)
{
	if (!vmxtest_is_intel()) {
		VMXTEST_SKIP(2, "not Intel; skip nested hardware gate");
		return;
	}
	if (!vmxtest_vmm_loaded()) {
		VMXTEST_SKIP(2, "vmm.ko not loaded (vmx_nested_status uninitialised)");
		return;
	}

	{
		int status;
		size_t slen;

		slen = sizeof(status);
		if (kernel_sysctlbyname(&thread0, "hw.vmm.nested.vmx", &status,
		    &slen, NULL, 0, NULL, 0) != 0) {
			VMXTEST_SKIP(2, "hw.vmm.nested.vmx sysctl missing");
			return;
		}
		printf("vmx_nested_test: test-2 hw.vmm.nested.vmx=%d\n", status);
		if (status == 1) {
			VMXTEST_PASS(2);
		} else if (status == 0) {
			VMXTEST_SKIP(2, "nested.vmx=0 (CPU lacks unrestricted guest)");
		} else {
			VMXTEST_FAIL(2, "nested.vmx=%d (not a boolean)", status);
		}
	}
}

/*
 * Test 3: VMCS12 allocation.
 *
 * Two layered checks, both compile-time and runtime:
 *   (a) struct vmx_vcpu carries the nvmcs12 pointer (T15).
 *   (b) struct vmcs is exactly PAGE_SIZE (vmcs.h CTASSERT).
 *   (c) The two addresses differ in the enclosing struct (guards
 *       against a regression where someone replaces nvmcs12 with a
 *       duplicate of vmcs by accident).
 *
 * Skipped when vmm.ko is not loaded because the production code
 * path that exercises this allocation runs inside vmm.
 */
static void
vmxtest_vmcs12_alloc(void)
{
	size_t off_nvmcs12, off_vmcs;

	if (!vmxtest_vmm_loaded()) {
		VMXTEST_SKIP(3, "vmm.ko not loaded (nvmcs12 layout not in active use)");
		return;
	}

	off_nvmcs12 = __offsetof(struct vmx_vcpu, nvmcs12);
	off_vmcs = __offsetof(struct vmx_vcpu, vmcs);
	if (off_nvmcs12 == off_vmcs) {
		VMXTEST_FAIL(3,
		    "nvmcs12 overlaps vmcs at offset %zu", off_nvmcs12);
		return;
	}
	if (sizeof(struct vmcs) != PAGE_SIZE) {
		VMXTEST_FAIL(3,
		    "sizeof(struct vmcs)=%zu, expected PAGE_SIZE=%d",
		    sizeof(struct vmcs), (int)PAGE_SIZE);
		return;
	}
	printf("vmx_nested_test: test-3 nvmcs12@%zu vmcs@%zu sizeof(vmcs)=%zu "
	    "PAGE_SIZE=%d\n",
	    off_nvmcs12, off_vmcs, sizeof(struct vmcs), (int)PAGE_SIZE);
	VMXTEST_PASS(3);
}

/*
 * Test 4: CR4.VMXE gate.
 *
 * Sanity-checks that CR4_VMXE is the well-known bit 13 (0x2000)
 * and that the host CPU genuinely allows us to set it.  Note we
 * only toggle CR4 with VMXE; we do NOT execute VMXON here, since
 * that would consume the host VMCS region and break any running
 * bhyve.  The test leaves CR4 in its previous state on exit.
 */
static void
vmxtest_cr4_vmxe(void)
{
	uint64_t before, after;

	if (!vmxtest_is_intel()) {
		VMXTEST_SKIP(4, "not Intel; skip CR4.VMXE toggle");
		return;
	}

	if (CR4_VMXE != 0x2000U) {
		VMXTEST_FAIL(4, "CR4_VMXE=%#x expected 0x2000",
		    (unsigned)CR4_VMXE);
		return;
	}

	before = rcr4();
	load_cr4(before | CR4_VMXE);
	after = rcr4();
	if ((after & CR4_VMXE) == 0) {
		load_cr4(before);
		VMXTEST_FAIL(4,
		    "CR4.VMXE did not stick: before=%#lx after=%#lx",
		    (unsigned long)before, (unsigned long)after);
		return;
	}
	load_cr4(before);
	printf("vmx_nested_test: test-4 CR4.VMXE=0x2000 toggled ok "
	    "(before=%#lx after=%#lx)\n",
	    (unsigned long)before, (unsigned long)after);
	VMXTEST_PASS(4);
}

/*
 * Test 5: VMX_FIXED MSR reads.
 *
 * MSR_VMX_CR0_FIXED0 (0x486) and MSR_VMX_CR0_FIXED1 (0x487) report
 * which CR0 bits are forced to 0 or forced to 1 inside a VMX guest.
 * Architecturally:
 *   - FIXED0 must have PE (bit 0) and PG (bit 31) set: a guest
 *     cannot be in real mode (no paging implies no segmentation).
 *   - FIXED1 must be non-zero: at least one CR0 bit must be
 *     configurable.
 */
static void
vmxtest_fixed_msr_read(void)
{
	uint64_t fixed0, fixed1;

	if (!vmxtest_is_intel()) {
		VMXTEST_SKIP(5, "not Intel; skip VMX FIXED MSRs");
		return;
	}

	fixed0 = rdmsr(MSR_VMX_CR0_FIXED0);
	fixed1 = rdmsr(MSR_VMX_CR0_FIXED1);

	if ((fixed0 & 0x80000001U) != 0x80000001U) {
		VMXTEST_FAIL(5,
		    "MSR_VMX_CR0_FIXED0 missing PE|PG: %#lx",
		    (unsigned long)fixed0);
		return;
	}
	if (fixed1 == 0) {
		VMXTEST_FAIL(5,
		    "MSR_VMX_CR0_FIXED1=0 (expected non-zero)");
		return;
	}
	printf("vmx_nested_test: test-5 FIXED0=%#lx FIXED1=%#lx\n",
	    (unsigned long)fixed0, (unsigned long)fixed1);
	VMXTEST_PASS(5);
}

/*
 * A zero-length layout table would make every loop below iterate nothing and
 * report PASS, which is the one result this suite must never produce by
 * accident: the bounds check is the guest-facing trust boundary, and "we
 * checked nothing" would print identically to "we checked everything".  An
 * empty table is also a real defect in its own right -- nested VMREAD and
 * VMWRITE cannot resolve a single encoding without it -- so this fails rather
 * than skips.
 */
static bool
vmxtest_layout_present(int test)
{

	if (vmcs12_fields_count == 0) {
		VMXTEST_FAIL(test, "layout table is empty; nothing was checked");
		return (false);
	}
	return (true);
}

/*
 * Test 6: every VMCS12 layout entry lies inside struct vmcs12.
 *
 * This is the security-relevant one.  vmcs12_lookup() is reached with an
 * encoding supplied by L1 (through emulated VMREAD/VMWRITE), and the offset
 * it returns is used directly as a memcpy offset into the vmcs12 page.  A
 * single entry whose offset+width runs past the end of the structure turns a
 * guest-controlled read into an out-of-bounds kernel read, so the table is a
 * guest-facing trust boundary and every entry must be inside the page.
 */
static void
vmxtest_vmcs12_layout_bounds(void)
{
	const struct vmcs12_layout *f;
	u_int i;

	if (!vmxtest_layout_present(6))
		return;

	for (i = 0; i < vmcs12_fields_count; i++) {
		f = vmcs12_at(i);
		if (f == NULL) {
			VMXTEST_FAIL(6, "vmcs12_at(%u) returned NULL with "
			    "count %u", i, vmcs12_fields_count);
			return;
		}
		if ((size_t)f->offset + f->width > sizeof(struct vmcs12)) {
			VMXTEST_FAIL(6, "entry %u (encoding 0x%x) offset %u "
			    "width %u runs past sizeof(struct vmcs12) %zu",
			    i, f->encoding, f->offset, f->width,
			    sizeof(struct vmcs12));
			return;
		}
	}
	VMXTEST_PASS(6);
}

/*
 * Test 7: every entry declares one of the three architectural widths.
 *
 * vmcs12_read_field() switches on width and returns -1 for anything else, so
 * a bad width is not itself unsafe -- but it silently makes that field
 * unreadable, which is a defect worth catching in the table rather than in a
 * guest that cannot read its own VMCS.
 */
static void
vmxtest_vmcs12_layout_widths(void)
{
	const struct vmcs12_layout *f;
	u_int i;

	if (!vmxtest_layout_present(7))
		return;

	for (i = 0; i < vmcs12_fields_count; i++) {
		f = vmcs12_at(i);
		if (f == NULL) {
			VMXTEST_FAIL(7, "vmcs12_at(%u) returned NULL", i);
			return;
		}
		if (f->width != VMCS_W_16 && f->width != VMCS_W_32 &&
		    f->width != VMCS_W_64) {
			VMXTEST_FAIL(7, "entry %u (encoding 0x%x) has width "
			    "%u, not 2/4/8", i, f->encoding, f->width);
			return;
		}
	}
	VMXTEST_PASS(7);
}

/*
 * Test 8: no two fields occupy the same bytes, and no encoding appears twice.
 *
 * Overlapping entries would make a write to one field silently corrupt
 * another; a duplicated encoding would make lookup order decide which field
 * L1 gets.  Both are table bugs that no boot test would reveal.
 */
static void
vmxtest_vmcs12_layout_no_overlap(void)
{
	const struct vmcs12_layout *a, *b;
	u_int i, j;

	if (!vmxtest_layout_present(8))
		return;

	for (i = 0; i < vmcs12_fields_count; i++) {
		a = vmcs12_at(i);
		if (a == NULL) {
			VMXTEST_FAIL(8, "vmcs12_at(%u) returned NULL", i);
			return;
		}
		for (j = i + 1; j < vmcs12_fields_count; j++) {
			b = vmcs12_at(j);
			if (b == NULL) {
				VMXTEST_FAIL(8, "vmcs12_at(%u) returned NULL",
				    j);
				return;
			}
			if (a->encoding == b->encoding) {
				VMXTEST_FAIL(8, "encoding 0x%x appears at "
				    "both %u and %u", a->encoding, i, j);
				return;
			}
			if (a->offset < b->offset + b->width &&
			    b->offset < a->offset + a->width) {
				VMXTEST_FAIL(8, "entries %u (0x%x) and %u "
				    "(0x%x) overlap at offsets %u/%u",
				    i, a->encoding, j, b->encoding,
				    a->offset, b->offset);
				return;
			}
		}
	}
	VMXTEST_PASS(8);
}

/*
 * Test 9: an encoding L1 invents is refused, and *val is left alone.
 *
 * The caller is expected to VMfail into L1 on -1.  If the value were written
 * anyway, L1 would receive uninitialised stack as though it were VMCS data.
 */
static void
vmxtest_vmcs12_unknown_encoding(void)
{
	struct vmcs12 *v;
	uint64_t val = 0xdeadbeefcafef00dULL;

	if (vmcs12_lookup(0xfffffffeU) != NULL) {
		VMXTEST_FAIL(9, "lookup of a bogus encoding returned an entry");
		return;
	}

	v = malloc(sizeof(*v), M_TEMP, M_WAITOK | M_ZERO);
	if (vmcs12_read_field(v, 0xfffffffeU, &val) != -1) {
		VMXTEST_FAIL(9, "read of a bogus encoding did not fail");
		free(v, M_TEMP);
		return;
	}
	if (val != 0xdeadbeefcafef00dULL) {
		VMXTEST_FAIL(9, "failed read still wrote *val (0x%lx)", val);
		free(v, M_TEMP);
		return;
	}
	free(v, M_TEMP);
	VMXTEST_PASS(9);
}

/*
 * Test 10: NULL arguments are refused rather than dereferenced.
 *
 * vmcs12_read_field() guards both the vmcs12 and the out-pointer, so both are
 * exercised.  If a future change dropped either guard this test panics rather
 * than printing FAIL -- unavoidable when the thing under test is whether a
 * pointer is dereferenced.  That is tolerable only because this module is
 * never loaded by a running system on its own; a panic here is a loud,
 * diagnosable result on a machine that was booted to run it.
 */
static void
vmxtest_vmcs12_null_args(void)
{
	const struct vmcs12_layout *f;
	struct vmcs12 *v;
	uint64_t val = 0;

	/* Any real encoding will do; take the first table entry. */
	f = vmcs12_at(0);
	if (f == NULL) {
		VMXTEST_SKIP(10, "layout table is empty");
		return;
	}
	if (vmcs12_read_field(NULL, f->encoding, &val) != -1) {
		VMXTEST_FAIL(10, "read with a NULL vmcs12 did not fail");
		return;
	}
	v = malloc(sizeof(*v), M_TEMP, M_WAITOK | M_ZERO);
	if (vmcs12_read_field(v, f->encoding, NULL) != -1) {
		VMXTEST_FAIL(10, "read with a NULL value pointer did not fail");
		free(v, M_TEMP);
		return;
	}
	free(v, M_TEMP);
	VMXTEST_PASS(10);
}

/*
 * Test 11: a value written to a field reads back from that field.
 *
 * Round-tripping every entry at its own width checks the table's offsets and
 * widths against the accessors that use them, which is the pair that has to
 * agree for L1 to see its own VMCS correctly.
 *
 * Every entry is written, including the ones test 12 asserts are read-only,
 * and that is deliberate rather than an oversight: vmcs12_write_field() is the
 * unpoliced accessor L0 uses to fill in exit information, and the read-only
 * rule is enforced a layer up in vmx_nested_vmwrite() where L1's writes
 * arrive.  The exit-information fields need their offsets checked as much as
 * any other -- L1 reads them.  If enforcement is ever pushed down into the
 * accessor, this test is the one that will notice, and the fix then is to skip
 * VMCS12_F_READONLY entries here, not to relax test 12.
 */
static void
vmxtest_vmcs12_roundtrip(void)
{
	const struct vmcs12_layout *f;
	struct vmcs12 *v;
	uint64_t wrote, read_back, mask;
	u_int i;

	if (!vmxtest_layout_present(11))
		return;

	v = malloc(sizeof(*v), M_TEMP, M_WAITOK | M_ZERO);
	for (i = 0; i < vmcs12_fields_count; i++) {
		f = vmcs12_at(i);
		if (f == NULL) {
			VMXTEST_FAIL(11, "vmcs12_at(%u) returned NULL", i);
			goto out;
		}
		/* A pattern that differs in every byte of every width. */
		wrote = 0x0123456789abcdefULL;
		mask = (f->width == VMCS_W_64) ? ~0ULL :
		    ((1ULL << (f->width * 8)) - 1);

		if (vmcs12_write_field(v, f->encoding, wrote) != 0) {
			VMXTEST_FAIL(11, "write of encoding 0x%x failed",
			    f->encoding);
			goto out;
		}
		if (vmcs12_read_field(v, f->encoding, &read_back) != 0) {
			VMXTEST_FAIL(11, "read of encoding 0x%x failed",
			    f->encoding);
			goto out;
		}
		if (read_back != (wrote & mask)) {
			VMXTEST_FAIL(11, "encoding 0x%x width %u: wrote "
			    "0x%lx, read 0x%lx, expected 0x%lx",
			    f->encoding, f->width, wrote, read_back,
			    wrote & mask);
			goto out;
		}
	}
	free(v, M_TEMP);
	VMXTEST_PASS(11);
	return;
out:
	free(v, M_TEMP);
}

/*
 * Test 12: the fields L1 must not be able to write are still marked read-only.
 *
 * vmx_nested_vmwrite() refuses a write on one signal alone -- the entry's
 * VMCS12_F_READONLY flag -- while vmcs12_write_field() below it writes
 * anything it is given, because L0 has to fill the exit-information fields
 * itself.  So the flag in the table is the whole boundary.  An entry that
 * lost it would let L1 forge its own exit reason and exit qualification,
 * which L0 then reads back to decide how to handle the exit, and no boot or
 * round-trip test would notice: the guest would simply be believed.
 *
 * The expected set is written out rather than derived so that removing a
 * flag from the table fails here instead of silently agreeing with itself.
 */
static const uint32_t vmxtest_readonly_encodings[] = {
	VMCS_GUEST_PHYSICAL_ADDRESS,
	VMCS_INSTRUCTION_ERROR,
	VMCS_EXIT_REASON,
	VMCS_EXIT_INTR_INFO,
	VMCS_EXIT_INTR_ERRCODE,
	VMCS_IDT_VECTORING_INFO,
	VMCS_IDT_VECTORING_ERROR,
	VMCS_EXIT_INSTRUCTION_LENGTH,
	VMCS_EXIT_INSTRUCTION_INFO,
	VMCS_EXIT_QUALIFICATION,
	VMCS_IO_RCX,
	VMCS_IO_RSI,
	VMCS_IO_RDI,
	VMCS_IO_RIP,
	VMCS_GUEST_LINEAR_ADDRESS,
};

static void
vmxtest_vmcs12_readonly_flags(void)
{
	const struct vmcs12_layout *f;
	u_int i;

	if (!vmxtest_layout_present(12))
		return;

	for (i = 0; i < nitems(vmxtest_readonly_encodings); i++) {
		f = vmcs12_lookup(vmxtest_readonly_encodings[i]);
		if (f == NULL) {
			VMXTEST_FAIL(12, "encoding 0x%x is not in the layout "
			    "table at all", vmxtest_readonly_encodings[i]);
			return;
		}
		if ((f->flags & VMCS12_F_READONLY) == 0) {
			VMXTEST_FAIL(12, "encoding 0x%x is no longer marked "
			    "read-only; L1 could write it",
			    vmxtest_readonly_encodings[i]);
			return;
		}
	}
	VMXTEST_PASS(12);
}

static void
vmxtest_run_all(void)
{

	vmxtest_pass = 0;
	vmxtest_fail = 0;
	vmxtest_skip = 0;

	printf("vmx_nested_test: starting 12 sub-tests\n");

	vmxtest_cap_msr_read();
	vmxtest_nested_gate();
	vmxtest_vmcs12_alloc();
	vmxtest_cr4_vmxe();
	vmxtest_fixed_msr_read();
	vmxtest_vmcs12_layout_bounds();
	vmxtest_vmcs12_layout_widths();
	vmxtest_vmcs12_layout_no_overlap();
	vmxtest_vmcs12_unknown_encoding();
	vmxtest_vmcs12_null_args();
	vmxtest_vmcs12_roundtrip();
	vmxtest_vmcs12_readonly_flags();

	printf("vmx_nested_test: %d/12 PASS (%d FAIL, %d SKIP)\n",
	    vmxtest_pass, vmxtest_fail, vmxtest_skip);
}

static int
vmxtest_modevent(module_t mod __unused, int what, void *arg __unused)
{
	int err = 0;

	switch (what) {
	case MOD_LOAD:
		vmxtest_run_all();
		break;
	case MOD_UNLOAD:
		break;
	default:
		err = EOPNOTSUPP;
		break;
	}
	return (err);
}

static moduledata_t vmx_nested_test_mod = {
	"vmx_nested_test",
	vmxtest_modevent,
	NULL
};

MODULE_VERSION(vmx_nested_test, 1);
DECLARE_MODULE(vmx_nested_test, vmx_nested_test_mod, SI_SUB_PSEUDO,
    SI_ORDER_ANY);
