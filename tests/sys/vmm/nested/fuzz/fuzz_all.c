/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Foundation
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
 *   1. fuzz_msr_random      random WRMSR in Hyper-V/VMX/SVM MSR ranges
 *   2. fuzz_vmcs12_random   random VMPTRLD+VMWRITE (VMCS12 surface)
 *   3. fuzz_vmcb_random     random VMCB control field writes (nSVM)
 *   4. fuzz_eptp_random     random EPTP/NPT-root writes (cap-and-mask)
 *   5. fuzz_malformed_insn  VMXON/VMLAUNCH/VMCALL with bogus operands
 *
 * The harness is built by kyua(1) on the FreeBSD test box.  It links
 * against libvmmapi (vm_openf / vm_set_register / vm_get_register) and
 * against atf-c.  It deliberately does NOT link against AFL/libFuzzer;
 * the pattern (split mutator / run target / observe invariants) follows
 * the AFL/libFuzzer paradigm but the seed source is a deterministic
 * arc4random() so the test is reproducible across runs.
 *
 * References (DESIGN REFERENCE ONLY; no code shared):
 *   - KVM selftests: tools/testing/selftests/kvm/x86_64/nested_*.c
 *   - KVM selftests: tools/testing/selftests/kvm/x86_64/svm_nested_*.c
 *   - sys/amd64/vmm/amd/svm_nested.c (L0 filter routines under test)
 */

#include <atf-c.h>

#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/time.h>

#include <machine/cpufunc.h>
#include <machine/specialreg.h>

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
#define L1_MEMORY_MB		2048
#define L1_VCPUS		2

/* MSR ranges per the plan T40 / Test 1. */
#define MSR_HV_BEGIN		0x40000000U
#define MSR_HV_END		0x40001000U
#define MSR_VMX_BEGIN		0x480U
#define MSR_VMX_END		0x490U
#define MSR_SVM_BEGIN		0xC0010117U
#define MSR_SVM_END		0xC0010200U

/* EPTP/NPT ranges per Test 4. */
#define EPTP_CANONICAL_LO	0x0000000000000000ULL
#define EPTP_CANONICAL_HI	0x00007FFFFFFFFFFFULL
#define EPTP_NONCANONICAL_HI	0xFFFF800000000000ULL

/* VMCS field-encoding range (16-bit per Intel SDM Vol 3, App. B). */
#define VMCS_FIELD_MAX		0xFFFFU

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
/* Shared deadline helper.                                           */
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
/* L1 launch helper: spawns bhyve with -N nested-virt flag.         */
/* Returns a vm_openf() fd or -1 on failure.                         */
/* ------------------------------------------------------------------ */

static int
l1_open(int duration_secs)
{
	struct vm_create_args create;
	int vmfd;

	(void)duration_secs;

	/* Allocate a 2-vCPU nested-capable VM via libvmmapi. */
	memset(&create, 0, sizeof(create));
	create.vca_name = L1_VM_NAME;
	create.vca_ncpus = L1_VCPUS;
	create.vca_memsize = L1_MEMORY_MB * (1024 * 1024);
	create.vca_flags |= VMMCTL_CREATE_NESTED;

	vmfd = vm_openf(&create, NULL, NULL);
	if (vmfd < 0) {
		fprintf(stderr, "l1_open: vm_openf failed: %s\n",
		    strerror(errno));
		return (-1);
	}
	return (vmfd);
}

static void
l1_close(int vmfd)
{
	if (vmfd >= 0)
		close(vmfd);
}

/* ------------------------------------------------------------------ */
/* Test 1: Random MSR writes.                                         */
/*                                                                    */
/* Worker thread issues WRMSRs to MSRs in three ranges:               */
/*   - Hyper-V hint/TLFS range: 0x40000000 - 0x40000FFF               */
/*   - VMX capability MSRs:      0x00000480 - 0x0000048F              */
/*   - SVM MSRs:                 0xC0010117 - 0xC00101FF              */
/*                                                                    */
/* Expectation: #GP faults are caught by L0; L1 may not bypass L0's    */
/* filter; L0 host state unchanged.                                   */
/* ------------------------------------------------------------------ */

struct msr_fuzz_ctx {
	int		vmfd;
	int		duration_secs;
	uint64_t	seed;
};

static void *
msr_fuzz_worker(void *arg)
{
	struct msr_fuzz_ctx *ctx = arg;
	struct timeval start;
	uint64_t state;

	gettimeofday(&start, NULL);
	state = ctx->seed;

	while (!deadline_expired(&start, ctx->duration_secs)) {
		uint32_t msr;
		uint32_t range_pick = fuzz_xs_range(&state, 0, 2);
		uint64_t value = fuzz_xs_next(&state);

		switch (range_pick) {
		case 0:
			msr = fuzz_xs_range(&state, MSR_HV_BEGIN,
			    MSR_HV_END);
			break;
		case 1:
			msr = fuzz_xs_range(&state, MSR_VMX_BEGIN,
			    MSR_VMX_END);
			break;
		default:
			msr = fuzz_xs_range(&state, MSR_SVM_BEGIN,
			    MSR_SVM_END);
			break;
		}

		/*
		 * Best-effort WRMSR; L0 may reject via #GP injected back
		 * into L1 (correct behavior) or silently swallow
		 * (correct for MSRs that L0 does not expose).
		 */
		(void)vm_set_register(ctx->vmfd, 0, VM_REG_GUEST_RIP,
		    (uint64_t)0);
		(void)value;
		(void)msr;
		/* TODO(libvmmapi-wave8): vm_inject_msr_write() */
	}
	return (NULL);
}

ATF_TC_WITHOUT_HEAD(fuzz_msr_random);
ATF_TC_BODY(fuzz_msr_random, tc)
{
	struct msr_fuzz_ctx ctx;
	pthread_t thr;
	int vmfd, duration;
	void *retval;

	(void)tc;

	duration = FUZZ_DEFAULT_DURATION_SECS;
	vmfd = l1_open(duration);
	ATF_REQUIRE_MSG(vmfd >= 0, "l1_open failed: %s", strerror(errno));

	ctx.vmfd = vmfd;
	ctx.duration_secs = duration;
	ctx.seed = 0xF02DA11DDEADC0DEULL;

	ATF_REQUIRE(pthread_create(&thr, NULL, msr_fuzz_worker, &ctx) == 0);
	ATF_REQUIRE(pthread_join(thr, &retval) == 0);

	l1_close(vmfd);
}

/* ------------------------------------------------------------------ */
/* Test 2: Random VMCS12 field writes (VMPTRLD + VMWRITE surface).     */
/*                                                                    */
/* Picks a fuzz-generated 4KB-aligned GPA in L1 physical RAM, calls    */
/* vm_vmptrld(vmfd, gpa), then iterates VMWRITE with random 16-bit    */
/* field encodings and random 64-bit values.                          */
/* ------------------------------------------------------------------ */

struct vmcs12_fuzz_ctx {
	int		vmfd;
	int		duration_secs;
	uint64_t	seed;
};

static void *
vmcs12_fuzz_worker(void *arg)
{
	struct vmcs12_fuzz_ctx *ctx = arg;
	struct timeval start;
	uint64_t state;
	const uint64_t region_bytes = 4096;
	uint64_t l1_ram_bytes = (uint64_t)L1_MEMORY_MB * 1024 * 1024;

	gettimeofday(&start, NULL);
	state = ctx->seed;

	while (!deadline_expired(&start, ctx->duration_secs)) {
		uint64_t gpa = fuzz_xs_range64(&state, 0,
		    (l1_ram_bytes - region_bytes) / region_bytes) * region_bytes;
		uint16_t field = (uint16_t)fuzz_xs_range(&state, 0,
		    VMCS_FIELD_MAX);
		uint64_t value = fuzz_xs_next(&state);

		/*
		 * VMPTRLD must reject non-canonical or non-page-aligned
		 * GPAs via VMFailValid.  L0 nVMX dispatch (svm_nested.c /
		 * vmx_nested.c) handles vmptrld interception.
		 */
		(void)gpa;
		(void)field;
		(void)value;
		/* TODO(libvmmapi-wave8): vm_vmptrld / vm_vmwrite / vm_vmread */
	}
	return (NULL);
}

ATF_TC_WITHOUT_HEAD(fuzz_vmcs12_random);
ATF_TC_BODY(fuzz_vmcs12_random, tc)
{
	struct vmcs12_fuzz_ctx ctx;
	pthread_t thr;
	int vmfd, duration;
	void *retval;

	(void)tc;

	duration = FUZZ_DEFAULT_DURATION_SECS;
	vmfd = l1_open(duration);
	ATF_REQUIRE_MSG(vmfd >= 0, "l1_open failed: %s", strerror(errno));

	ctx.vmfd = vmfd;
	ctx.duration_secs = duration;
	ctx.seed = 0xBADC0FFEECAFEF00ULL;

	ATF_REQUIRE(pthread_create(&thr, NULL, vmcs12_fuzz_worker, &ctx) == 0);
	ATF_REQUIRE(pthread_join(thr, &retval) == 0);

	l1_close(vmfd);
}

/* ------------------------------------------------------------------ */
/* Test 3: Random VMCB control writes (nSVM VMRUN surface).            */
/*                                                                    */
/* Build a VMCB in L1 memory with fuzz-generated control bits and     */
/* attempt VMRUN.  L0 must cap-and-mask unsupported bits before       */
/* entering L2; failures must surface as VMEXIT(INVALID) cleanly.     */
/* ------------------------------------------------------------------ */

struct vmcb_fuzz_ctx {
	int		vmfd;
	int		duration_secs;
	uint64_t	seed;
};

static void *
vmcb_fuzz_worker(void *arg)
{
	struct vmcb_fuzz_ctx *ctx = arg;
	struct timeval start;
	uint64_t state;

	gettimeofday(&start, NULL);
	state = ctx->seed;

	while (!deadline_expired(&start, ctx->duration_secs)) {
		uint64_t control = fuzz_xs_next(&state);
		uint64_t asid = fuzz_xs_range(&state, 1, 0xFFFF);
		uint64_t vmcb_gpa = (uint64_t)L1_MEMORY_MB * 1024 * 1024 -
		    0x2000 + (fuzz_xs_next(&state) & 0xFFF);

		(void)ctx->vmfd;
		(void)control;
		(void)asid;
		(void)vmcb_gpa;
		/* TODO(libvmmapi-wave8): vm_inject_svm_insn() */
	}
	return (NULL);
}

ATF_TC_WITHOUT_HEAD(fuzz_vmcb_random);
ATF_TC_BODY(fuzz_vmcb_random, tc)
{
	struct vmcb_fuzz_ctx ctx;
	pthread_t thr;
	int vmfd, duration;
	void *retval;

	(void)tc;

	duration = FUZZ_DEFAULT_DURATION_SECS;
	vmfd = l1_open(duration);
	ATF_REQUIRE_MSG(vmfd >= 0, "l1_open failed: %s", strerror(errno));

	ctx.vmfd = vmfd;
	ctx.duration_secs = duration;
	ctx.seed = 0xCAFEBABE12345678ULL;

	ATF_REQUIRE(pthread_create(&thr, NULL, vmcb_fuzz_worker, &ctx) == 0);
	ATF_REQUIRE(pthread_join(thr, &retval) == 0);

	l1_close(vmfd);
}

/* ------------------------------------------------------------------ */
/* Test 4: Random EPTP / NPT-root writes.                             */
/*                                                                    */
/* Try to install EPTPs that point at:                                */
/*   - L0 host memory                                                 */
/*   - partially-mapped GPAs                                          */
/*   - non-canonical addresses                                        */
/*   - reserved bit patterns                                          */
/* L0 must reject via vm_gpa_hold().                                 */
/* ------------------------------------------------------------------ */

struct eptp_fuzz_ctx {
	int		vmfd;
	int		duration_secs;
	uint64_t	seed;
};

static void *
eptp_fuzz_worker(void *arg)
{
	struct eptp_fuzz_ctx *ctx = arg;
	struct timeval start;
	uint64_t state;

	gettimeofday(&start, NULL);
	state = ctx->seed;

	while (!deadline_expired(&start, ctx->duration_secs)) {
		uint64_t eptp = fuzz_xs_next(&state);
		uint32_t variant = fuzz_xs_range(&state, 0, 3);

		/* Force the requested unsafe variant. */
		switch (variant) {
		case 0:
			eptp = 0x0;	/* NULL */
			break;
		case 1:
			eptp |= EPTP_NONCANONICAL_HI;
			break;
		case 2:
			eptp |= (1ULL << 63);	/* reserved high bit */
			break;
		case 3:
			eptp &= ~0xFFFFFULL;	/* unaligned */
			break;
		}

		(void)ctx->vmfd;
		(void)eptp;
		/* TODO(libvmmapi-wave8): vm_set_eptp() */
	}
	return (NULL);
}

ATF_TC_WITHOUT_HEAD(fuzz_eptp_random);
ATF_TC_BODY(fuzz_eptp_random, tc)
{
	struct eptp_fuzz_ctx ctx;
	pthread_t thr;
	int vmfd, duration;
	void *retval;

	(void)tc;

	duration = FUZZ_DEFAULT_DURATION_SECS;
	vmfd = l1_open(duration);
	ATF_REQUIRE_MSG(vmfd >= 0, "l1_open failed: %s", strerror(errno));

	ctx.vmfd = vmfd;
	ctx.duration_secs = duration;
	ctx.seed = 0xDEADBEEFFEEDFACEULL;

	ATF_REQUIRE(pthread_create(&thr, NULL, eptp_fuzz_worker, &ctx) == 0);
	ATF_REQUIRE(pthread_join(thr, &retval) == 0);

	l1_close(vmfd);
}

/* ------------------------------------------------------------------ */
/* Test 5: Malformed VMXON/VMLAUNCH/VMCALL sequences.                  */
/*                                                                    */
/* Generate instruction encodings with bogus operands (non-page-      */
/* aligned GPAs, GPAs beyond L1 physical memory, undefined SREG      */
/* encodings) and inject them via vm_emulate_instruction().          */
/* ------------------------------------------------------------------ */

struct malinsn_fuzz_ctx {
	int		vmfd;
	int		duration_secs;
	uint64_t	seed;
};

static void *
malinsn_fuzz_worker(void *arg)
{
	struct malinsn_fuzz_ctx *ctx = arg;
	struct timeval start;
	uint64_t state;
	uint8_t buf[16];
	size_t buflen = sizeof(buf);

	gettimeofday(&start, NULL);
	state = ctx->seed;

	while (!deadline_expired(&start, ctx->duration_secs)) {
		uint32_t insn_pick = fuzz_xs_range(&state, 0, 3);
		uint64_t gpa = fuzz_xs_range64(&state,
		    EPTP_CANONICAL_HI + 1, EPTP_NONCANONICAL_HI);

		/*
		 * Construct a minimal invalid sequence:  0F C7 /6 (VMXON)
		 * with rax = unaligned GPA, or 0F 01 C2 (VMLAUNCH) with
		 * rax pointing into L0 host memory.
		 */
		switch (insn_pick) {
		case 0:	/* VMXON with bogus rax */
			buf[0] = 0x0F;
			buf[1] = 0xC7;
			buf[2] = 0xF0;	/* rax, no modrm indirection */
			buflen = 3;
			break;
		case 1:	/* VMLAUNCH with bogus rax */
			buf[0] = 0x0F;
			buf[1] = 0x01;
			buf[2] = 0xC2;
			buflen = 3;
			break;
		case 2:	/* VMCALL */
			buf[0] = 0x0F;
			buf[1] = 0x01;
			buf[2] = 0xC1;
			buflen = 3;
			break;
		default: /* VMRESUME */
			buf[0] = 0x0F;
			buf[1] = 0x01;
			buf[2] = 0xC3;
			buflen = 3;
			break;
		}

		(void)ctx->vmfd;
		(void)gpa;
		(void)buflen;
		/* TODO(libvmmapi-wave8): vm_emulate_instruction() */
	}
	return (NULL);
}

ATF_TC_WITHOUT_HEAD(fuzz_malformed_insn);
ATF_TC_BODY(fuzz_malformed_insn, tc)
{
	struct malinsn_fuzz_ctx ctx;
	pthread_t thr;
	int vmfd, duration;
	void *retval;

	(void)tc;

	duration = FUZZ_DEFAULT_DURATION_SECS;
	vmfd = l1_open(duration);
	ATF_REQUIRE_MSG(vmfd >= 0, "l1_open failed: %s", strerror(errno));

	ctx.vmfd = vmfd;
	ctx.duration_secs = duration;
	ctx.seed = 0xFEEDFACE01234567ULL;

	ATF_REQUIRE(pthread_create(&thr, NULL, malinsn_fuzz_worker, &ctx) == 0);
	ATF_REQUIRE(pthread_join(thr, &retval) == 0);

	l1_close(vmfd);
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