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
 * AMD SVM MSR permission map helpers; layout documented in svm_nested.c
 * (APM Vol 2 §15.11). Access selectors for the *_intercept() calls:
 */
#ifndef MSR_BITMAP_ACCESS_READ
#define	MSR_BITMAP_ACCESS_READ	0x1
#endif
#ifndef MSR_BITMAP_ACCESS_WRITE
#define	MSR_BITMAP_ACCESS_WRITE	0x2
#endif
#ifndef MSR_BITMAP_ACCESS_RW
#define	MSR_BITMAP_ACCESS_RW	(MSR_BITMAP_ACCESS_READ | MSR_BITMAP_ACCESS_WRITE)
#endif

int	 svm_msr_bitmap_locate(uint32_t msr, size_t *byte, unsigned *bit);

struct pmap;
struct svm_softc;
struct svm_vcpu;

/*
 * Per-vCPU nested-virt state. Currently a minimal stub sufficient for
 * the wave-5 vmexit dispatcher to clear 'nested_in_l2' on
 * SHUTDOWN/exit; future waves extend it with the L1-stated VMCB12
 * pointer, the cached L2 VMCB, and the L2 IDT/GDT/CR state.
 */
struct svm_nested {
	bool		nested_in_l2;	/* hardware VMCB holds L2 state */
	bool		gif;		/* global interrupt flag (STGI/CLGI) */
	uint64_t	vmcb12_gpa;	/* L1 GPA of the VMCB passed to VMRUN */
	struct vmcb	*vmcb12;	/* held mapping of that page, while in L2 */
	void		*vmcb12_cookie;
	struct vmcb_state l1_state;	/* L1 save area parked during L2 */
	uint64_t	l1_intr_shadow;	/* L1 interrupt shadow during L2 */
	uint32_t	l0_intercept[5]; /* L0 intercept vectors during L2 */
	uint64_t	l0_tsc_offset;
	uint64_t	l0_vintr;	/* VMCB ctrl bytes 0x60-0x67 (V_TPR..) */
	uint64_t	pir[4];		/* pending L2 vectors (svm_nested_intr.c) */
	struct pmap	*npt02;		/* shadow NPT: L2 GPA -> host */
	uint64_t	npt02_pa;
	uint64_t	l0_ncr3;	/* L0 N_CR3 parked during L2 */
	uint64_t	l1_ncr3;	/* VMCB12.N_CR3 the shadow was built for */
	int		debug_count;	/* hw.vmm.nested.svm_debug budget */
	/*
	 * L1's IOPM (3 pages) and MSRPM (2 pages), held while L2 runs so
	 * the exit handler can consult them without taking locks.
	 */
	uint8_t		*l1_iopm[3];
	void		*l1_iopm_cookie[3];
	uint8_t		*l1_msrpm[2];
	void		*l1_msrpm_cookie[2];
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
 * Per-vCPU nested state, and the VMCB12 mapping held while L2 runs.
 */
struct svm_nested *svm_nested_lookup(struct svm_vcpu *vcpu);
void	 svm_nested_release_vmcb12(struct svm_vcpu *vcpu);
bool	 svm_nested_in_l2(struct svm_vcpu *vcpu);

/*
 * Force a TLB flush before the next VMRUN (L1 and L2 share L0's ASID).
 */
void	 svm_nested_tlb_flush(struct svm_vcpu *vcpu);

/* svm_nested_npt.c */
int	 svm_nested_npt_init(struct svm_vcpu *vcpu);
void	 svm_nested_npt_flush(struct svm_vcpu *vcpu);
void	 svm_nested_npt_cleanup(struct svm_vcpu *vcpu);
int	 svm_nested_npt_fault(struct svm_vcpu *vcpu, uint64_t g2,
	     uint64_t exitinfo1);

#endif /* _VMM_SVM_NESTED_H_ */
