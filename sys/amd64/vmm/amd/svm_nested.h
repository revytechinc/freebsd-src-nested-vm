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

/*
 * AMD SVM MSR Permission Map (MSRPM) layout.
 *
 * The MSRPM is an 8-Kbyte (2 page) bitmap. Per AMD APM Vol 2 §15.11:
 *
 *   Page 0 (offsets 0x0000-0x0FFF): MSRs 0x00000000-0x00001FFF
 *     - Read map : offsets 0x0000-0x07FF (2 KB)
 *     - Write map: offsets 0x0800-0x0FFF (2 KB)
 *   Page 1 (offsets 0x1000-0x1FFF): MSRs 0xC0000000-0xC0001FFF
 *     - Read map : offsets 0x1000-0x17FF (2 KB)
 *     - Write map: offsets 0x1800-0x1FFF (2 KB)
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
#define	SVM_MSR_BITMAP_PAGE1_MSRS	0x2000

#define	SVM_MSR_BITMAP_PAGE1_BASE_OFF	0x1000	/* page 1 starts at 4 KB */
#define	SVM_MSR_BITMAP_WRITE_HALF_OFF	0x0800	/* write map offset within
						   a 4 KB page */
#define	SVM_MSR_BITMAP_MSRS_PER_BYTE	4
#define	SVM_MSR_BITMAP_BITS_PER_MSR	2

struct svm_softc;
struct svm_vcpu;

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
 * ranges one at a time. Currently a placeholder; T8/T9/T10/T11 add
 * MSR_VM_HSAVE_PA, vCPU model-specific MSRs, perf counters and the
 * final L1 deny-list. Called only when 'vm->nested_enabled'.
 */
void	 svm_nested_build_msrpm(struct svm_softc *sc, struct svm_vcpu *vcpu);

#endif /* _VMM_SVM_NESTED_H_ */