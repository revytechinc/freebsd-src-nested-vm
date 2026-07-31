/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * Nested virtualization support for bhyve.
 * Original BSD code; KVM is referenced only for design.
 */

#ifndef _VMM_NESTED_H_
#define _VMM_NESTED_H_

#include <sys/systm.h>
#include <sys/types.h>

/*
 * Shared bitmap primitives used by both SVM and VMX nested-virt code.
 * Layout mirrors the AMD MSRPM (2 KB read + 2 KB write per 4 KB page, two
 * pages) and the Intel VMX MSR bitmap (one 4 KB page shared across all
 * regions); the per-platform callers know which layout is in use.
 */
struct nested_bitmap {
	uint8_t	*map;
	size_t	 size;
};

static __inline void
nested_bitmap_init(struct nested_bitmap *nb, void *backing, size_t size)
{
	nb->map = backing;
	nb->size = size;
	memset(nb->map, 0, size);
}

/* SVM-only: 0x0000-0x1FFF page 0, 0xC0000000-0xC0001FFF page 1. */
#define SVM_MSR_BITMAP_PAGE0	0x0000
#define SVM_MSR_BITMAP_PAGE1	0xC0000000

#define NV_MAGIC_INTEL	0x564E4E49	/* 'INNV' */
#define NV_MAGIC_AMD	0x534E4E41	/* 'ANNS' */

enum nested_platform {
	NV_PLATFORM_INTEL = 0,
	NV_PLATFORM_AMD   = 1,
};

/*
 * Hyper-V Synthetic MSR constants used by bhyve's nested-virt L1
 * guest enlightenment code path (sys/amd64/vmm/amd/svm_msr.c,
 * sys/amd64/vmm/intel/vmx_msr.c, usr.sbin/bhyve/amd64/xmsr.c).
 *
 * Per Hyper-V TLFS 7.8b §3.1. These addresses are *only* in the
 * 0x40000000 range -- never in the AMD SVM MSRPM (0x0000-0x1FFF,
 * 0xC0000000-0xC0001FFF) and never in the Intel VMX MSR bitmap
 * (same ranges). For both vendors, accesses in the 0x40000000 range
 * auto-exit on RDMSR/WRMSR; no bitmap registration is required.
 *
 * Architectural separation: this is the BHYVE guest-enlightenment
 * namespace. The FreeBSD host hyperv *driver* lives in sys/dev/hyperv
 * and uses its own MSR_HV_* copies in sys/dev/hyperv/vmbus/x86/hyperv_reg.h
 * (we MUST NOT touch that file -- it is a distinct namespace).
 *
 * Stats MSRs (0x40000081-0x40000088) are deliberately DEFERRED to v2
 * because they overlap the SVERSION range used by the host driver;
 * importing them now would create a name collision (see T31 plan).
 * The host driver retains its own MSR values for SVERSION etc.
 */
#define	MSR_HV_GUEST_OS_ID		0x40000000U
#define	MSR_HV_HYPERCALL		0x40000001U
#define	MSR_HV_VP_INDEX			0x40000002U
#define	MSR_HV_TIME_REF_COUNT		0x40000020U
#define	MSR_HV_REFERENCE_TSC		0x40000021U
#define	MSR_HV_APIC_EOI			0x40000070U	/* EOI assist */
#define	MSR_HV_APIC_ICR			0x40000078U	/* ICR assist */
#define	MSR_HV_APIC_TPR			0x40000079U	/* TPR assist */
#define	MSR_HV_SCONTROL			0x40000080U
#define	MSR_HV_SIEFP			0x40000082U	/* SynIC event flag */
#define	MSR_HV_SIMP			0x40000083U	/* SynIC message */
#define	MSR_HV_EOM			0x40000084U	/* End-of-message */
#define	MSR_HV_SINT0			0x40000090U
#define	MSR_HV_SINT15			0x4000009FU
#define	MSR_HV_VP_RUNTIME		0x40000102U
#define	MSR_HV_RESET			0x40000103U
#define	MSR_HV_GUEST_IDLE		0x40000122U

/* SINT MSR stride and count per TLFS 7.8b §3.1.4 */
#define	MSR_HV_SINT_COUNT		16
#define	MSR_HV_SINT_STRIDE		0x10U	/* 16 bytes (4 64-bit words) */

/* Enable bit in MSR_HV_HYPERCALL (TLFS 7.8b §3.1.3). */
#define	MSR_HV_HYPERCALL_ENABLE		0x00000001ULL
/* Hypercall page must be page-aligned (TLFS 7.8b §3.1.3). */
#define	MSR_HV_HYPERCALL_PAGE_SHIFT	12
#define	MSR_HV_HYPERCALL_PAGE_MASK	\
    (~((1ULL << MSR_HV_HYPERCALL_PAGE_SHIFT) - 1))

/* MSR_HV_GUEST_OS_ID default for "I don't know" (Windows 10 / 2016). */
#define	MSR_HV_GUEST_OS_ID_WINDOWS	0x00008100U

/* Per-vCPU nested state. Platform-specific extension struct is allocated
 * by the factory and tacked on via the cookie. */
struct nested_vcpu_state {
	uint32_t	magic;
	enum nested_platform platform;
};

/* Factory: returns a zeroed per-vCPU nested state. */
struct nested_vcpu_state *nested_vcpu_state_factory(enum nested_platform p,
    struct vm *vm, int vcpuid);

#endif /* _VMM_NESTED_H_ */