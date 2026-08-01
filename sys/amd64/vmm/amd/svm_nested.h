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

#define	SVM_MSR_BITMAP_PAGE1_BASE_OFF	0x1000
#define	SVM_MSR_BITMAP_WRITE_HALF_OFF	0x0800
#define	SVM_MSR_BITMAP_MSRS_PER_BYTE	4
#define	SVM_MSR_BITMAP_BITS_PER_MSR	2

struct svm_softc;
struct svm_vcpu;
struct vmcb;

/*
 * Dirty bitmap of VMCB fields that an L1 hypervisor may have modified.
 * Per AMD APM Vol 2 §15.11 (VMCB Clean Bits). When the VMCB-clean-bits
 * CPUID feature is present, hardware can skip re-writing fields that
 * match their previous value; the bitmap records which fields L1
 * touched so T28 (VMCB shadow) can re-validate them.
 */
#define	SVM_NESTED_VMCB_DIRTY_CR_INTCPT		0x00000001U
#define	SVM_NESTED_VMCB_DIRTY_DR_INTCPT		0x00000002U
#define	SVM_NESTED_VMCB_DIRTY_EXC_INTCPT		0x00000004U
#define	SVM_NESTED_VMCB_DIRTY_INST1_INTCPT	0x00000008U
#define	SVM_NESTED_VMCB_DIRTY_INST2_INTCPT	0x00000010U
#define	SVM_NESTED_VMCB_DIRTY_IOPM		0x00000020U
#define	SVM_NESTED_VMCB_DIRTY_MSRPM		0x00000040U
#define	SVM_NESTED_VMCB_DIRTY_TSC_OFFSET		0x00000080U
#define	SVM_NESTED_VMCB_DIRTY_ASID		0x00000100U
#define	SVM_NESTED_VMCB_DIRTY_VIRQ		0x00000200U
#define	SVM_NESTED_VMCB_DIRTY_NP_ENABLE		0x00000400U
#define	SVM_NESTED_VMCB_DIRTY_NPT_BASE		0x00000800U
#define	SVM_NESTED_VMCB_DIRTY_LBR_VIRT		0x00001000U
#define	SVM_NESTED_VMCB_DIRTY_VMCB_CLEAN		0x00002000U
#define	SVM_NESTED_VMCB_DIRTY_EVENTINJ		0x00004000U

#define	SVM_NESTED_VMCB_DIRTY_ALL						\
	(SVM_NESTED_VMCB_DIRTY_CR_INTCPT |					\
	 SVM_NESTED_VMCB_DIRTY_DR_INTCPT |					\
	 SVM_NESTED_VMCB_DIRTY_EXC_INTCPT |					\
	 SVM_NESTED_VMCB_DIRTY_INST1_INTCPT |					\
	 SVM_NESTED_VMCB_DIRTY_INST2_INTCPT |					\
	 SVM_NESTED_VMCB_DIRTY_IOPM |						\
	 SVM_NESTED_VMCB_DIRTY_MSRPM |						\
	 SVM_NESTED_VMCB_DIRTY_TSC_OFFSET |					\
	 SVM_NESTED_VMCB_DIRTY_ASID |						\
	 SVM_NESTED_VMCB_DIRTY_VIRQ |						\
	 SVM_NESTED_VMCB_DIRTY_NP_ENABLE |					\
	 SVM_NESTED_VMCB_DIRTY_NPT_BASE |					\
	 SVM_NESTED_VMCB_DIRTY_LBR_VIRT |					\
	 SVM_NESTED_VMCB_DIRTY_VMCB_CLEAN |					\
	 SVM_NESTED_VMCB_DIRTY_EVENTINJ)

/*
 * Per-vCPU nested-virt state for AMD SVM. Allocated as part of
 * 'struct svm_vcpu' (or via the factory) and lives for the lifetime
 * of the vCPU.
 *
 *  nested_in_l2   : set while L2 is the active guest. L1 is parked.
 *  nested_vmrun_pending : set on VMEXIT_VMRUN from L1; cleared when
 *                         the L2 transition has been validated.
 *  nested_vmsave_load_gpa : L1-stated destination for VMSAVE/VMLOAD
 *                           MSR save/restore area (only used when L1
 *                           sets MSR_VM_HSAVE_PA before VMRUN).
 *  nested_asid_generation : incremented on every TLB flush so that
 *                           reused ASIDs cannot accidentally hit a
 *                           stale TLB entry (T29b).
 *  vmcb12_dirty   : bitmap of fields L1 has modified since the last
 *                   shadow sync (T28).
 *  npt12_root_gpa : L1-stated NPT root for L2 (T29). 0 = no NPT.
 */
struct svm_nested {
	bool		nested_in_l2;
	bool		nested_vmrun_pending;
	uint64_t	nested_vmsave_load_gpa;
	uint64_t	nested_asid_generation;
	uint32_t	vmcb12_dirty;
	uint64_t	npt12_root_gpa;
	uint64_t	npt12_asid;
	uint64_t	l1_prev_n_cr3;
	uint32_t	l1_prev_asid;
};

void	 svm_msr_bitmap_init(struct nested_bitmap *nb, void *backing);

int	 svm_msr_bitmap_set_intercept(struct nested_bitmap *nb, uint32_t msr,
	     int rw);

int	 svm_msr_bitmap_clear_intercept(struct nested_bitmap *nb, uint32_t msr,
	     int rw);

int	 svm_msr_bitmap_test_intercept(const struct nested_bitmap *nb,
	     uint32_t msr, int rw);

void	 svm_nested_build_msrpm(struct svm_softc *sc, struct svm_vcpu *vcpu);

/*
 * T25 / T26 / T27 / T28: nSVM launch emulation. Called from the SVM
 * #VMEXIT dispatcher when the L1 hypervisor has executed VMRUN /
 * VMSAVE / VMLOAD / CLGI / STGI / SKINIT and bhyve wants to honour
 * the nested intent rather than #UD-injecting.
 *
 * All functions return 1 on success (the L1 guest can be re-entered
 * with the modified state), 0 if the operation must be reflected
 * back to L1 as a generic VMEXIT (e.g., VMRUN with an invalid VMCB12
 * that L0 cannot fix up).
 */
int	 svm_nested_vmrun(struct svm_vcpu *vcpu, struct vmcb *l1_vmcb);
int	 svm_nested_vmsave(struct svm_vcpu *vcpu);
int	 svm_nested_vmload(struct svm_vcpu *vcpu);
int	 svm_nested_clgi(struct svm_vcpu *vcpu);
int	 svm_nested_stgi(struct svm_vcpu *vcpu);
int	 svm_nested_skinit(struct svm_vcpu *vcpu);

/*
 * T28: VMCB shadow apply/check. Called from T25 (VMRUN) right before
 * L1 is allowed to re-enter with the L2 VMCB. 'l1_vmcb' is the L1
 * physical VMCB that L0 has mapped into kernel memory (must remain
 * mapped for the duration of the call).
 *
 * Returns 0 if the shadow is in sync, EINVAL if the L1-supplied
 * VMCB fails cap-and-mask against L0 host capabilities.
 */
int	 svm_nested_vmcb_shadow_sync(struct svm_vcpu *vcpu,
	     struct vmcb *l1_vmcb);
int	 svm_nested_vmcb_shadow_check(struct svm_vcpu *vcpu,
	     const struct vmcb *l1_vmcb);

/*
 * File-scope accessor for the per-vCPU L1 HSAVE GPA. The T8 commit
 * adds this to svm_msr.c; when that lands, this declaration will be
 * removed in favour of including 'svm_msr.h'. Until then, a local
 * copy lives in svm_nested.c so this header remains self-contained.
 */
uint64_t svm_nested_get_l1_hsave_gpa(int vcpuid);

#endif /* _VMM_SVM_NESTED_H_ */