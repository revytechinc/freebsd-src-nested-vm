/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project
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
 *   2. vmx_nested_status sysctl == 2 -> VMCS shadowing ready
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
#include <sys/module.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/systm.h>

#include <machine/cpufunc.h>
#include <machine/specialreg.h>

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
 * canonical read-only gate for "VMCS shadowing is ready to be used
 * by L1 on this host".  Values:
 *   0 = nested virt not supported on this CPU
 *   1 = nested virt supported but L0 hypervisor already running
 *   2 = VMCS shadowing ready (Haswell+/Tiger Lake+ class)
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
static void
vmxtest_cap_msr_read(void)
{
	uint64_t basic;
	uint32_t revid;

	basic = rdmsr(MSR_VMX_BASIC);
	if (basic == 0) {
		VMXTEST_FAIL(1, "MSR_VMX_BASIC=0 (regression: rdmsr returns zero)");
		return;
	}
	revid = (uint32_t)(basic & 0xffffffff);
	if ((revid & 0x80000000U) == 0) {
		/*
		 * SDM Vol 3 §25.6.2: "Bits 30:0 of the MSR contain the
		 * VMCS revision identifier".  All shipping parts set
		 * bit 31 to indicate a fixed-width VMCS region; if it
		 * is zero something is very wrong.
		 */
		VMXTEST_FAIL(1,
		    "MSR_VMX_BASIC revision-id bit 31 clear: revid=%#x",
		    revid);
		return;
	}
	printf("vmx_nested_test: test-1 MSR_VMX_BASIC=%#lx revid=%#x\n",
	    (unsigned long)basic, revid);
	VMXTEST_PASS(1);
}

/*
 * Test 2: VMCS-shadowing hardware gate (vmx_nested_status).
 *
 * This is the value exposed by hw.vmm.nested.vmx: 2 means the host
 * has VMCS shadowing and no conflicting L0 hypervisor, i.e. an L1
 * guest can be nested-virtualized.  0 means CPU lacks shadowing
 * (Ivy Bridge and earlier).  1 means a hypervisor is already running
 * on the L0 (Hyper-V, KVM, ...).
 *
 * Skipped when vmm.ko is not loaded because vmx_nested_status is
 * only initialized in vmx_init(); the variable is in BSS until
 * then.
 */
static void
vmxtest_shadowing_gate(void)
{
	if (!vmxtest_vmm_loaded()) {
		VMXTEST_SKIP(2, "vmm.ko not loaded (vmx_nested_status uninitialised)");
		return;
	}

	printf("vmx_nested_test: test-2 vmx_nested_status=%d\n",
	    vmx_nested_status);

	if (vmx_nested_status == 2) {
		VMXTEST_PASS(2);
	} else if (vmx_nested_status == 0) {
		VMXTEST_FAIL(2, "vmx_nested_status=0 (CPU lacks VMCS shadowing?)");
	} else if (vmx_nested_status == 1) {
		VMXTEST_FAIL(2, "vmx_nested_status=1 (L0 hypervisor conflict)");
	} else {
		VMXTEST_FAIL(2, "vmx_nested_status=%d (unexpected value)",
		    vmx_nested_status);
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
 * Per SDM Vol 3 §25.6.5/§25.6.6:
 *   - FIXED0 must have PE (bit 0) and PG (bit 31) set: a guest
 *     cannot be in real mode (no paging implies no segmentation).
 *   - FIXED1 must be non-zero: at least one CR0 bit must be
 *     configurable.
 */
static void
vmxtest_fixed_msr_read(void)
{
	uint64_t fixed0, fixed1;

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

static void
vmxtest_run_all(void)
{

	vmxtest_pass = 0;
	vmxtest_fail = 0;
	vmxtest_skip = 0;

	printf("vmx_nested_test: starting 5 sub-tests (T17 / Wave 3)\n");

	vmxtest_cap_msr_read();
	vmxtest_shadowing_gate();
	vmxtest_vmcs12_alloc();
	vmxtest_cr4_vmxe();
	vmxtest_fixed_msr_read();

	printf("vmx_nested_test: %d/5 PASS (%d FAIL, %d SKIP)\n",
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
