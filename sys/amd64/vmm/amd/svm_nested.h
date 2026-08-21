/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * Nested virtualization support for bhyve on AMD SVM.
 * Original BSD code; AMD APM Vol 2 §15.11 is referenced for layout only.
 */

#ifndef _VMM_SVM_NESTED_H_
#define _VMM_SVM_NESTED_H_

#include <sys/types.h>

#include "vmm_nested.h"
#include "vmcb.h"

/*
 * AMD SVM MSR Permission Map (MSRPM) layout.
 *
 * The MSRPM is an 8-Kbyte (2 page) bitmap. Per AMD APM Vol 2 §15.11:
 *
 *   Page 0 (offsets 0x0000-0x0FFF): MSRs 0x00000000-0x00001FFF
 *     - Read map : offsets 0x0000-0x07FF (2 KB)
 *     - Write map: offsets 0x0800-0x0FFF (2 KB)
 *   Page 1 (offsets 0x1000-0x1FFF): MSRs 0xC0000000-0xC001FFFF
 *     - Read map : offsets 0x1000-0x17FF (2 KB)
 *     - Write map: offsets 0x1800-0x1FFF (2 KB)
 *
 * The C001 bank uses the same page-1 positions as the C000 bank; the
 * bank-select bits do not contribute to the offset within the page.
 *
 * Within each 2 KB read or write map, 4 MSRs are encoded per byte:
 *   byte_offset_within_2KB = (msr_index_within_page) / 4
 *   bit_position_within_byte = (msr_index_within_page % 4) * 2
 *     - bit b+0: read intercept for that MSR
 *     - bit b+1: write intercept for that MSR
 *
 * Bit semantics follow the existing bhyve convention (see svm.c):
 * bit cleared (0) = access is allowed (no intercept),
 * bit set   (1)   = access is intercepted.
 */
#define	SVM_MSR_BITMAP_PAGE0_MSRS	0x2000
#define	SVM_MSR_BITMAP_PAGE1_BASE	0xC0000000U
#define	SVM_MSR_BITMAP_PAGE1_END	0xC001FFFFU
#define	SVM_MSR_BITMAP_PAGE1_INDEX_MASK	0x00001FFFU

#define	SVM_MSR_BITMAP_PAGE1_BASE_OFF	0x1000	/* page 1 starts at 4 KB */
#define	SVM_MSR_BITMAP_WRITE_HALF_OFF	0x0800	/* write map offset within
						   a 4 KB page */
#define	SVM_MSR_BITMAP_MSRS_PER_BYTE	4
#define	SVM_MSR_BITMAP_BITS_PER_MSR	2

struct svm_softc;
struct svm_vcpu;

/*
 * Per-vCPU nested-virt state. Currently a minimal stub sufficient for
 * the wave-5 vmexit dispatcher to clear 'nested_in_l2' on
 * SHUTDOWN/exit; future waves extend it with the L1-stated VMCB12
 * pointer, the cached L2 VMCB, and the L2 IDT/GDT/CR state.
 */
struct svm_nested {
	bool		nested_in_l2;
	bool		gif;		/* STGI/CLGI guest interrupt flag */
	uint64_t	vmcb12_gpa;
	struct vmcb	*vmcb12;
	void		*vmcb12_cookie;
	struct vmcb_state l1_state;	/* L1 save area parked during L2 */
};

/*
 * Attach a backing buffer (already page-aligned and SVM_MSR_BITMAP_SIZE
 * bytes long) to 'nb' and fill it with the AMD-default "intercept all"
 * pattern (every bit set).
 */
void	 svm_msr_bitmap_init(struct nested_bitmap *nb, void *backing);

/*
 * Mark 'msr' as intercepted for the access bits selected in 'rw'
 * (MSR_BITMAP_ACCESS_READ/WRITE/RW). Returns 0 on success, EINVAL if
 * the MSR is outside the two supported ranges.
 */
int	 svm_msr_bitmap_set_intercept(struct nested_bitmap *nb, uint32_t msr,
	     int rw);

/*
 * Clear the intercept bits for 'msr' for the selected accesses
 * (i.e. allow the guest to access this MSR). Returns 0 on success,
 * EINVAL if the MSR is outside the two supported ranges.
 */
int	 svm_msr_bitmap_clear_intercept(struct nested_bitmap *nb, uint32_t msr,
	     int rw);

/*
 * Return non-zero if any of the access bits in 'rw' are intercepted for
 * 'msr'. Returns 0 if the MSR is outside the two supported ranges (no
 * possible intercept in the bitmap).
 */
int	 svm_msr_bitmap_test_intercept(const struct nested_bitmap *nb,
	     uint32_t msr, int rw);

/*
 * Builder entry point. Composes the per-vCPU MSRPM by composing MSR
 * ranges one at a time. It always installs the MSR_VM_HSAVE_PA
 * intercept required by T8; later tasks add model-specific MSRs, perf
 * counters and the final L1 deny-list. Called only when
 * 'vm->nested_enabled'.
 */
void	 svm_nested_build_msrpm(struct svm_softc *sc, struct svm_vcpu *vcpu);

/*
 * Install the per-thread 'current VMCB12' pointer that the
 * svm_nested_handle_vmexit dispatcher writes to. The wave-5 entry
 * path calls this once on each L2 entry; if no VMCB12 is installed,
 * the reflection helpers degrade to no-ops so the unit tests can
 * exercise the dispatcher without a real L1 mapping.
 */
struct svm_nested *svm_nested_lookup(struct svm_vcpu *vcpu);
void	 svm_nested_set_vmcb12(struct vmcb *vmcb12);
void	 svm_nested_release_vmcb12(struct svm_vcpu *vcpu);

/*
 * Drop L2-translated TLB entries so L1 cannot observe them. Called
 * from the svm_nested_handle_vmexit epilogue (T29b).
 */
void	 svm_nested_tlb_flush(struct svm_vcpu *vcpu);

#ifdef SVM_NESTED_TEST
void	 svm_nested_test_msrpm_range(void);
#endif

#endif /* _VMM_SVM_NESTED_H_ */
