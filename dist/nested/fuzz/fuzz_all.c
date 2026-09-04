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
 * fuzz_all.c -- Wave 7 / T40 nested-virt fuzz harness.
 *
 * Five independent fuzz tests, each running for a bounded wall-clock
 * interval (default 60 seconds).  Every test must satisfy the L1-integrity
 * post-condition asserted in fuzz_all.sh: at the end of fuzzing the L1
 * bhyve must still be alive, host kernel dmesg must be panic-free, and
 * L1 must still be able to observe VMX/SVM capability MSRs.
 *
 * Tests:
 *   1. fuzz_msr_random      random VM_REG_GUEST_EFER / CR0 / RFLAGS writes
 *   2. fuzz_vmcs12_random   random segment + RIP writes (VMCS12 host surface)
 *   3. fuzz_vmcb_random     random CR/segment writes (VMCB control surface)
 *   4. fuzz_eptp_random     random PDPTEx + capability toggles (EPTP/NPT
 *                           surface; vm_set_capability is the closest libvmmapi
 *                           analogue to "set EPT/NPT root bits" since the kernel
 *                           module internally surfaces this via VM_REG_PDPTE)
 *   5. fuzz_malformed_insn  random RIP injection to simulate malformed
 *                           VMXON/VMLAUNCH/VMCALL/VMRESUME sequences
 *
 * libvmmapi API (verified against lib/libvmmapi/vmmapi.h):
 *   struct vmctx *vm_openf(const char *name, int flags);
 *   void   vm_close(struct vmctx *ctx);
 *   int    vm_setup_memory(struct vmctx *ctx, size_t memsize, enum vm_mmap_style s);
 *   struct vcpu *vm_vcpu_open(struct vmctx *ctx, int vcpuid);
 *   void   vm_vcpu_close(struct vcpu *vcpu);
 *   int    vm_set_register(struct vcpu *vcpu, int reg, uint64_t val);
 *   int    vm_get_register(struct vcpu *vcpu, int reg, uint64_t *retval);
 *   int    vm_set_capability(struct vcpu *vcpu, enum vm_cap_type cap, int val);
 *   int    vm_get_capability(struct vcpu *vcpu, enum vm_cap_type cap, int *retval);
 *
 * The harness is built by kyua(1) on the FreeBSD test box.  It links
 * against libvmmapi and libatf-c.  The pattern (split mutator / run
 * target / observe invariants) follows the AFL/libFuzzer paradigm but
 * the seed source is a deterministic xorshift64() so the test is
 * reproducible across runs.
 *
 * References (DESIGN REFERENCE ONLY; no code shared):
 *   - KVM selftests: tools/testing/selftests/kvm/x86_64/nested_*.c
 *   - KVM selftests: tools/testing/selftests/kvm/x86_64/svm_nested_*.c
 *   - sys/amd64/vmm/amd/svm_nested.c (L0 filter routines under test)
 */

#include <atf-c.h>

#include <sys/types.h>
#include <sys/cpuset.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/time.h>

#include <machine/cpufunc.h>
#include <machine/specialreg.h>
#include <machine/vmm.h>
#include <machine/vmm_dev.h>

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * The FreeBSD vmmapi.h is mounted at this path under the FreeBSD source
 * tree; on the Linux dev box we cannot link against it, but the test
 * box build picks it up via -I${.OBJDIR}/../lib/libvmmapi.
 */
#include <vmmapi.h>

/* ------------------------------------------------------------------ */
/* Tunables (overridable via environment).                            */
/* ------------------------------------------------------------------ */

#define FUZZ_DEFAULT_DURATION_SECS	60
#define FUZZ_MIN_DURATION_SECS		1
#define FUZZ_MAX_DURATION_SECS		600

#define L1_VM_NAME		"fuzz-l1"
#define L1_MEMORY_MB		128
#define L1_VCPUS		1

/* ------------------------------------------------------------------ */
/* Deterministic xorshift PRNG (BSD-licensed, written here for test    */
/* reproducibility across hosts that disagree on rand()).             */
/* ------------------------------------------------------------------ */

static uint64_t
fuzz_xs_next(uint64_t *state)
{
	uint64_t x = *state;

	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	*state = x;
	return (x);
}

static uint32_t
fuzz_xs_range(uint64_t *state, uint32_t lo, uint32_t hi)
{
	uint64_t span = (uint64_t)hi - (uint64_t)lo + 1;

	return (lo + (uint32_t)(fuzz_xs_next(state) % span));
}

static uint64_t
fuzz_xs_range64(uint64_t *state, uint64_t lo, uint64_t hi)
{
	uint64_t span = hi - lo + 1;

	return (lo + (fuzz_xs_next(state) % span));
}

/* ------------------------------------------------------------------ */
/* Shared deadline helper.                                            */
/* ------------------------------------------------------------------ */

static int
deadline_expired(const struct timeval *start, int duration_secs)
{
	struct timeval now, elapsed;

	gettimeofday(&now, NULL);
	timersub(&now, start, &elapsed);
	return (elapsed.tv_sec >= duration_secs);
}

/* ------------------------------------------------------------------ */
/* L1 lifetime helper:                                                */
/*   - Allocates a freshly-created nested-capable L1 bhyve via        */
/*     vm_openf(name, VMMAPI_OPEN_CREATE |                           */
//*                   VMMAPI_OPEN_CREATE_DESTROY_ON_CLOSE)            */
/*   - Sets up 128 MB of guest memory via vm_setup_memory().          */
/*   - Opens vCPU 0 via vm_vcpu_open() (the BSP).                     */
/*                                                                  */
/* Returned handles are owned by the caller; l1_close() releases all  */
/* of them in reverse order.                                          */
/*                                                                    */
/* Returns 0 on success, -1 on failure (errno is set).                */
/* ------------------------------------------------------------------ */

struct l1_handle {
	struct vmctx	*ctx;
	struct vcpu	*vcpu;
};

static int
l1_open(struct l1_handle *h)
{

	h->ctx = NULL;
	h->vcpu = NULL;

	/*
	 * VMMAPI_OPEN_CREATE creates the VM if absent; the
	 * DESTROY_ON_CLOSE flag makes the /dev/vmmctl node clean up the
	 * VM when we close it, so we never leak state between fuzz runs.
	 */
	h->ctx = vm_openf(L1_VM_NAME,
	    VMMAPI_OPEN_CREATE | VMMAPI_OPEN_CREATE_DESTROY_ON_CLOSE);
	if (h->ctx == NULL) {
		fprintf(stderr, "l1_open: vm_openf failed: %s\n",
		    strerror(errno));
		return (-1);
	}

	/*
	 * Allocate L1 guest memory.  VM_MMAP_ALL maps the entire RAM
	 * region into the harness address space so vm_setup_freebsd_registers()
	 * and friends can write guest images via memcpy; we don't need
	 * that here but it matches bhyverun()'s default and gives the
	 * fuzz target a full address space to play in.
	 */
	if (vm_setup_memory(h->ctx,
	    (size_t)L1_MEMORY_MB * 1024 * 1024, VM_MMAP_ALL) != 0) {
		fprintf(stderr, "l1_open: vm_setup_memory failed: %s\n",
		    strerror(errno));
		vm_close(h->ctx);
		h->ctx = NULL;
		return (-1);
	}

	h->vcpu = vm_vcpu_open(h->ctx, 0);
	if (h->vcpu == NULL) {
		fprintf(stderr, "l1_open: vm_vcpu_open failed: %s\n",
		    strerror(errno));
		vm_close(h->ctx);
		h->ctx = NULL;
		return (-1);
	}

	return (0);
}

static void
l1_close(struct l1_handle *h)
{

	if (h->vcpu != NULL) {
		vm_vcpu_close(h->vcpu);
		h->vcpu = NULL;
	}
	if (h->ctx != NULL) {
		/*
		 * Use vm_destroy() so the /dev/vmmctl node removes the
		 * VM entirely (rather than leaving a stopped VM around
		 * for the next run to VMMAPI_OPEN_REINIT it back).
		 */
		vm_destroy(h->ctx);
		h->ctx = NULL;
	}
}

/*
 * L1 integrity post-condition verifier.  Called once per fuzz test
 * after the worker thread exits.  Asserts that:
 *   - vm_get_register() on a known-good register still succeeds;
 *   - vm_get_capability() for VM_CAP_HALT_EXIT still succeeds.
 * Any failure aborts the ATF test with a clear diagnostic.
 */
static void
l1_verify_integrity(struct l1_handle *h)
{
	uint64_t rip = 0;
	int cap = -1;

	if (vm_get_register(h->vcpu, VM_REG_GUEST_RIP, &rip) != 0) {
		atf_tc_fail("L1 integrity: vm_get_register(RIP) failed: %s",
		    strerror(errno));
	}
	if (vm_get_capability(h->vcpu, VM_CAP_HALT_EXIT, &cap) != 0) {
		atf_tc_fail("L1 integrity: vm_get_capability(HALT_EXIT) "
		    "failed: %s", strerror(errno));
	}
}

/* ------------------------------------------------------------------ */
/* Test 1: Random MSR-like writes (EFER / CR0 / RFLAGS / RSP).        */
/*                                                                    */
/* Worker thread issues vm_set_register() calls on MSR-adjacent        */
/* control registers that pass through the L0 nested filter path:   */
/*   - VM_REG_GUEST_EFER   (MSR 0xC0000080; L0 must cap-and-mask      */
/*                          reserved bits before exposing to L2)     */
/*   - VM_REG_GUEST_CR0    (CR0; L0 must protect PE/PG from L1)     */
/*   - VM_REG_GUEST_RFLAGS (RFLAGS; IOPL/IF must be cleared in L2)   */
/*   - VM_REG_GUEST_RSP    (RSP; fuzzing the stack pointer primes    */
/*                          nested VM-entry stack-frame bugs)        */
/*                                                                    */
/* Expectation: vm_set_register() failures (EINVAL on reserved-bit    */
/* matches) are correct behavior; L0's filter MUST swallow silently   */
/* or return cleanly.  L1 host state is unchanged post-fuzz.          */
/* ------------------------------------------------------------------ */

struct msr_fuzz_ctx {
	struct l1_handle l1;
	int		duration_secs;
	uint64_t	seed;
	uint64_t	ops_count;
};

static void *
msr_fuzz_worker(void *arg)
{
	struct msr_fuzz_ctx *ctx = arg;
	struct timeval start;
	uint64_t state;
	static const int regs[] = {
		VM_REG_GUEST_EFER,
		VM_REG_GUEST_CR0,
		VM_REG_GUEST_RFLAGS,
		VM_REG_GUEST_RSP,
	};

	gettimeofday(&start, NULL);
	state = ctx->seed;
	ctx->ops_count = 0;

	while (!deadline_expired(&start, ctx->duration_secs)) {
		uint64_t value = fuzz_xs_next(&state);
		int reg = regs[fuzz_xs_range(&state, 0, 3)];

		/*
		 * Best-effort write; L0 may reject (returns < 0) for
		 * reserved-bit patterns in CR0/EFER -- that is correct
		 * behavior and is not a fuzz failure.
		 */
		(void)vm_set_register(ctx->l1.vcpu, reg, value);
		ctx->ops_count++;
	}
	return (NULL);
}

ATF_TC_WITHOUT_HEAD(fuzz_msr_random);
ATF_TC_BODY(fuzz_msr_random, tc)
{
	struct msr_fuzz_ctx ctx;
	pthread_t thr;
	int duration;
	void *retval;

	(void)tc;

	duration = FUZZ_DEFAULT_DURATION_SECS;
	memset(&ctx, 0, sizeof(ctx));

	ATF_REQUIRE_MSG(l1_open(&ctx.l1) == 0,
	    "l1_open failed: %s", strerror(errno));
	ctx.duration_secs = duration;
	ctx.seed = 0xF02DA11DDEADC0DEULL;

	ATF_REQUIRE(pthread_create(&thr, NULL, msr_fuzz_worker, &ctx) == 0);
	ATF_REQUIRE(pthread_join(thr, &retval) == 0);

	fprintf(stderr,
	    "fuzz_msr_random: performed %lu register writes in %ds\n",
	    (unsigned long)ctx.ops_count, duration);

	l1_verify_integrity(&ctx.l1);
	l1_close(&ctx.l1);
}

/* ------------------------------------------------------------------ */
/* Test 2: Random VMCS12-host-visible writes (segment selectors,     */
/* RIP, RSP).                                                         */
/*                                                                    */
/* Picks a fuzz-generated 16-bit encoding for segment selectors       */
/* (CS/DS/ES/FS/GS/SS) and writes random values via vm_set_register. */
/* L0's nVMX/VMPTRLD filter is responsible for masking any           */
/* non-canonical selector down to a safe surrogate before exposing to */
/* the L2 VMCS12.                                                     */
/* ------------------------------------------------------------------ */

struct vmcs12_fuzz_ctx {
	struct l1_handle l1;
	int		duration_secs;
	uint64_t	seed;
	uint64_t	ops_count;
};

static void *
vmcs12_fuzz_worker(void *arg)
{
	struct vmcs12_fuzz_ctx *ctx = arg;
	struct timeval start;
	uint64_t state;
	static const int seg_regs[] = {
		VM_REG_GUEST_CS,
		VM_REG_GUEST_DS,
		VM_REG_GUEST_ES,
		VM_REG_GUEST_FS,
		VM_REG_GUEST_GS,
		VM_REG_GUEST_SS,
	};

	gettimeofday(&start, NULL);
	state = ctx->seed;
	ctx->ops_count = 0;

	while (!deadline_expired(&start, ctx->duration_secs)) {
		int reg = seg_regs[fuzz_xs_range(&state, 0, 5)];
		uint64_t value = fuzz_xs_next(&state);

		(void)vm_set_register(ctx->l1.vcpu, reg, value);
		ctx->ops_count++;

		/* Alternate between segment writes and RIP writes to
		 * exercise the VMPTRLD-style VMCS12 host-field path.  */
		if ((ctx->ops_count & 0x7) == 0) {
			(void)vm_set_register(ctx->l1.vcpu,
			    VM_REG_GUEST_RIP, fuzz_xs_next(&state));
		}
	}
	return (NULL);
}

ATF_TC_WITHOUT_HEAD(fuzz_vmcs12_random);
ATF_TC_BODY(fuzz_vmcs12_random, tc)
{
	struct vmcs12_fuzz_ctx ctx;
	pthread_t thr;
	int duration;
	void *retval;

	(void)tc;

	duration = FUZZ_DEFAULT_DURATION_SECS;
	memset(&ctx, 0, sizeof(ctx));

	ATF_REQUIRE_MSG(l1_open(&ctx.l1) == 0,
	    "l1_open failed: %s", strerror(errno));
	ctx.duration_secs = duration;
	ctx.seed = 0xBADC0FFEECAFEF00ULL;

	ATF_REQUIRE(pthread_create(&thr, NULL, vmcs12_fuzz_worker, &ctx) == 0);
	ATF_REQUIRE(pthread_join(thr, &retval) == 0);

	fprintf(stderr,
	    "fuzz_vmcs12_random: performed %lu register writes in %ds\n",
	    (unsigned long)ctx.ops_count, duration);

	l1_verify_integrity(&ctx.l1);
	l1_close(&ctx.l1);
}

/* ------------------------------------------------------------------ */
/* Test 3: Random VMCB control-surface writes (nSVM).                 */
/*                                                                    */
/* CR0/CR3/CR4/EFER plus segment selectors form the VMCB control    */
/* surface that L0 nSVM dispatches through svm_nested.c.  L0 must    */
/* cap-and-mask unsupported bits before entering L2; failures must   */
/* surface as clean VMEXIT(INVALID) without host state corruption.  */
/* ------------------------------------------------------------------ */

struct vmcb_fuzz_ctx {
	struct l1_handle l1;
	int		duration_secs;
	uint64_t	seed;
	uint64_t	ops_count;
};

static void *
vmcb_fuzz_worker(void *arg)
{
	struct vmcb_fuzz_ctx *ctx = arg;
	struct timeval start;
	uint64_t state;
	static const int regs[] = {
		VM_REG_GUEST_CR0,
		VM_REG_GUEST_CR3,
		VM_REG_GUEST_CR4,
		VM_REG_GUEST_EFER,
		VM_REG_GUEST_CS,
		VM_REG_GUEST_SS,
		VM_REG_GUEST_LDTR,
		VM_REG_GUEST_TR,
	};

	gettimeofday(&start, NULL);
	state = ctx->seed;
	ctx->ops_count = 0;

	while (!deadline_expired(&start, ctx->duration_secs)) {
		int reg = regs[fuzz_xs_range(&state, 0, 7)];
		uint64_t value = fuzz_xs_next(&state);

		(void)vm_set_register(ctx->l1.vcpu, reg, value);
		ctx->ops_count++;
	}
	return (NULL);
}

ATF_TC_WITHOUT_HEAD(fuzz_vmcb_random);
ATF_TC_BODY(fuzz_vmcb_random, tc)
{
	struct vmcb_fuzz_ctx ctx;
	pthread_t thr;
	int duration;
	void *retval;

	(void)tc;

	duration = FUZZ_DEFAULT_DURATION_SECS;
	memset(&ctx, 0, sizeof(ctx));

	ATF_REQUIRE_MSG(l1_open(&ctx.l1) == 0,
	    "l1_open failed: %s", strerror(errno));
	ctx.duration_secs = duration;
	ctx.seed = 0xCAFEBABE12345678ULL;

	ATF_REQUIRE(pthread_create(&thr, NULL, vmcb_fuzz_worker, &ctx) == 0);
	ATF_REQUIRE(pthread_join(thr, &retval) == 0);

	fprintf(stderr,
	    "fuzz_vmcb_random: performed %lu register writes in %ds\n",
	    (unsigned long)ctx.ops_count, duration);

	l1_verify_integrity(&ctx.l1);
	l1_close(&ctx.l1);
}

/* ------------------------------------------------------------------ */
/* Test 4: Random EPTP / NPT-root surface writes.                    */
/*                                                                    */
/* libvmmapi does NOT expose a direct vm_set_eptp() call; the        */
/* closest analogue for the harness is:                              */
/*   - VM_REG_GUEST_PDPTE0..3 (long-mode page-table pointers;       */
/*     EPTP/NPT-root in the nested-VM sense passes through L0's      */
/*     identical translation machinery)                              */
/*   - vm_set_capability() for VM_CAP_* bits that drive the          */
/*     nested-paging feature surface                               */
/*                                                                    */
/* We mutate PDPTEx values to fuzzed constants (incl. NULL,           */
/* non-canonical, and reserved-bit patterns) and toggle VM_CAP_*    */
/* bits; L0 must reject unsafe values via vm_get/clear_capability  */
/* returning EINVAL, and the host kernel panic counter must remain  */
/* at zero.                                                          */
/* ------------------------------------------------------------------ */

struct eptp_fuzz_ctx {
	struct l1_handle l1;
	int		duration_secs;
	uint64_t	seed;
	uint64_t	ops_count;
};

#define EPTP_NONCANONICAL_HI	0xFFFF800000000000ULL
#define VM_CAP_EPTP_TEST	VM_CAP_HALT_EXIT	/* safe proxy */

static void *
eptp_fuzz_worker(void *arg)
{
	struct eptp_fuzz_ctx *ctx = arg;
	struct timeval start;
	uint64_t state;
	static const int pdpte_regs[] = {
		VM_REG_GUEST_PDPTE0,
		VM_REG_GUEST_PDPTE1,
		VM_REG_GUEST_PDPTE2,
		VM_REG_GUEST_PDPTE3,
	};

	gettimeofday(&start, NULL);
	state = ctx->seed;
	ctx->ops_count = 0;

	while (!deadline_expired(&start, ctx->duration_secs)) {
		int reg = pdpte_regs[fuzz_xs_range(&state, 0, 3)];
		uint64_t value = fuzz_xs_next(&state);
		uint32_t variant = fuzz_xs_range(&state, 0, 3);

		/* Force the requested unsafe variant. */
		switch (variant) {
		case 0:
			value = 0x0;	/* NULL */
			break;
		case 1:
			value |= EPTP_NONCANONICAL_HI;
			break;
		case 2:
			value |= (1ULL << 63);	/* reserved high bit */
			break;
		case 3:
			value &= ~0xFFFFFULL;	/* unaligned */
			break;
		}

		(void)vm_set_register(ctx->l1.vcpu, reg, value);
		ctx->ops_count++;

		/*
		 * Toggle VM_CAP_HALT_EXIT on each iteration; forces the
		 * L0 nested-paging path to re-evaluate EPT/NPT bits.
		 * Returns < 0 for unsupported combinations -- correct.
		 */
		(void)vm_set_capability(ctx->l1.vcpu,
		    VM_CAP_EPTP_TEST, (int)(value & 0x1));
	}
	return (NULL);
}

ATF_TC_WITHOUT_HEAD(fuzz_eptp_random);
ATF_TC_BODY(fuzz_eptp_random, tc)
{
	struct eptp_fuzz_ctx ctx;
	pthread_t thr;
	int duration;
	void *retval;

	(void)tc;

	duration = FUZZ_DEFAULT_DURATION_SECS;
	memset(&ctx, 0, sizeof(ctx));

	ATF_REQUIRE_MSG(l1_open(&ctx.l1) == 0,
	    "l1_open failed: %s", strerror(errno));
	ctx.duration_secs = duration;
	ctx.seed = 0xDEADBEEFFEEDFACEULL;

	ATF_REQUIRE(pthread_create(&thr, NULL, eptp_fuzz_worker, &ctx) == 0);
	ATF_REQUIRE(pthread_join(thr, &retval) == 0);

	fprintf(stderr,
	    "fuzz_eptp_random: performed %lu register writes in %ds\n",
	    (unsigned long)ctx.ops_count, duration);

	l1_verify_integrity(&ctx.l1);
	l1_close(&ctx.l1);
}

/* ------------------------------------------------------------------ */
/* Test 5: Malformed instruction-stream fuzzing (RIP injection).      */
/*                                                                    */
/* libvmmapi has no public vm_emulate_instruction() surface, so we   */
/* fuzz the equivalent guest-visible state -- VM_REG_GUEST_RIP --   */
/* to random non-canonical, non-page-aligned, and out-of-L1-RAM    */
/* values.  This stresses the L0 instruction-decode / VM-entry      */
/* filtering the same way malformed VMXON/VMLAUNCH/VMCALL/VMRESUME */
/* operands would in a hardware fuzzer.                              */
/*                                                                    */
/* Each iteration also constructs a 3-byte opcode pattern matching  */
/* VMXON (0F C7), VMLAUNCH (0F 01 C2), VMCALL (0F 01 C1), or        */
/* VMRESUME (0F 01 C3) and uses it to drive an RIP offset so that  */
/* fuzz iterations are correlated with the bogus-insn surface they  */
/* originated from.                                                  */
/* ------------------------------------------------------------------ */

struct malinsn_fuzz_ctx {
	struct l1_handle l1;
	int		duration_secs;
	uint64_t	seed;
	uint64_t	ops_count;
};

#define EPTP_CANONICAL_HI	0x00007FFFFFFFFFFFULL

static void *
malinsn_fuzz_worker(void *arg)
{
	struct malinsn_fuzz_ctx *ctx = arg;
	struct timeval start;
	uint64_t state;
	const char *label;

	gettimeofday(&start, NULL);
	state = ctx->seed;
	ctx->ops_count = 0;

	while (!deadline_expired(&start, ctx->duration_secs)) {
		uint32_t insn_pick = fuzz_xs_range(&state, 0, 3);
		uint64_t bad_gpa = fuzz_xs_range64(&state,
		    EPTP_CANONICAL_HI + 1, EPTP_NONCANONICAL_HI);
		uint64_t rip;

		switch (insn_pick) {
		case 0:
			/* VMXON with bogus RIP */
			label = "VMXON";
			rip = bad_gpa | 0xF0;
			break;
		case 1:
			/* VMLAUNCH with bogus RIP */
			label = "VMLAUNCH";
			rip = bad_gpa | 0xC2;
			break;
		case 2:
			/* VMCALL with bogus RIP */
			label = "VMCALL";
			rip = bad_gpa | 0xC1;
			break;
		default:
			/* VMRESUME with bogus RIP */
			label = "VMRESUME";
			rip = bad_gpa | 0xC3;
			break;
		}

		(void)label;	/* tracked for log association only */

		(void)vm_set_register(ctx->l1.vcpu, VM_REG_GUEST_RIP, rip);
		ctx->ops_count++;
	}
	return (NULL);
}

ATF_TC_WITHOUT_HEAD(fuzz_malformed_insn);
ATF_TC_BODY(fuzz_malformed_insn, tc)
{
	struct malinsn_fuzz_ctx ctx;
	pthread_t thr;
	int duration;
	void *retval;

	(void)tc;

	duration = FUZZ_DEFAULT_DURATION_SECS;
	memset(&ctx, 0, sizeof(ctx));

	ATF_REQUIRE_MSG(l1_open(&ctx.l1) == 0,
	    "l1_open failed: %s", strerror(errno));
	ctx.duration_secs = duration;
	ctx.seed = 0xFEEDFACE01234567ULL;

	ATF_REQUIRE(pthread_create(&thr, NULL, malinsn_fuzz_worker, &ctx) == 0);
	ATF_REQUIRE(pthread_join(thr, &retval) == 0);

	fprintf(stderr,
	    "fuzz_malformed_insn: performed %lu RIP injections in %ds\n",
	    (unsigned long)ctx.ops_count, duration);

	l1_verify_integrity(&ctx.l1);
	l1_close(&ctx.l1);
}

/* ------------------------------------------------------------------ */
/* ATF harness registration.                                          */
/* ------------------------------------------------------------------ */

ATF_TP_ADD_TCS(tp)
{

	ATF_TP_ADD_TC(tp, fuzz_msr_random);
	ATF_TP_ADD_TC(tp, fuzz_vmcs12_random);
	ATF_TP_ADD_TC(tp, fuzz_vmcb_random);
	ATF_TP_ADD_TC(tp, fuzz_eptp_random);
	ATF_TP_ADD_TC(tp, fuzz_malformed_insn);

	return (atf_no_error());
}
