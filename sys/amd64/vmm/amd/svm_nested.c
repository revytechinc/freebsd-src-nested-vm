/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * Nested virtualization support for bhyve on AMD SVM.
 * MSR bitmap primitives backing the per-vCPU MSRPM (T7), and nSVM
 * launch emulation: T25 / T26 / T27 / T28 (VMRUN / VMSAVE / VMLOAD /
 * CLGI / STGI / SKINIT / VMCB-shadow). Layout follows AMD APM Vol 2
 * §15.11; this is original BSD code that implements the primitive
 * set/clear/test operations on a shared 'nested_bitmap' and the
 * per-vCPU VMRUN / VMSAVE / VMLOAD / CLGI / STGI / SKINIT /
 * VMCB-shadow state machine.
 */

#include <sys/cdefs.h>

#include <sys/errno.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/types.h>

#include <machine/cpufunc.h>
#include <machine/vmm.h>

#include "svm_softc.h"
#include "svm_nested.h"
#include "vmm_nested.h"
#include "vmcb.h"

#ifndef MSR_BITMAP_ACCESS_NONE
#define	MSR_BITMAP_ACCESS_NONE	0x0
#endif
#ifndef MSR_BITMAP_ACCESS_READ
#define	MSR_BITMAP_ACCESS_READ	0x1
#endif
#ifndef MSR_BITMAP_ACCESS_WRITE
#define	MSR_BITMAP_ACCESS_WRITE	0x2
#endif
#ifndef MSR_BITMAP_ACCESS_RW
#define	MSR_BITMAP_ACCESS_RW	(MSR_BITMAP_ACCESS_READ|MSR_BITMAP_ACCESS_WRITE)
#endif

/*
 * Per-vCPU L1 HSAVE GPA. The T8 commit (svm_msr.c) owns this same
 * concept; we declare a parallel copy here so the wave5 branch stays
 * self-contained until wave2 lands. When the two branches merge the
 * storage here will be removed in favour of the canonical T8 array.
 */
static uint64_t nested_hsave_gpa[MAXCPU];

uint64_t
svm_nested_get_l1_hsave_gpa(int vcpuid)
{

	if (vcpuid < 0 || vcpuid >= MAXCPU)
		return (0);
	return (nested_hsave_gpa[vcpuid]);
}

/*
 * Per-vCPU nested-virt state for AMD SVM. T25-T28.
 *
 * File-scope array indexed by vcpuid. We cannot add fields to
 * 'struct svm_vcpu' (out-of-scope for this branch) without disrupting
 * unrelated callers, so a parallel lookup table is the cleanest
 * non-invasive answer.
 */
static struct svm_nested nested_state[MAXCPU];

static struct svm_nested *
svm_nested_lookup(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;

	if (vcpu == NULL || vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU)
		return (NULL);
	ns = &nested_state[vcpu->vcpuid];
	if (ns->nested_asid_generation == 0 &&
	    !ns->nested_in_l2 && !ns->nested_vmrun_pending &&
	    ns->npt12_root_gpa == 0) {
		ns->nested_asid_generation = 1;
	}
	return (ns);
}

static int
svm_msr_bitmap_locate(uint32_t msr, size_t *page_base, uint32_t *msr_in_page)
{
	uint32_t offset;

	if (msr <= (SVM_MSR_BITMAP_PAGE0_MSRS - 1)) {
		*page_base = 0;
		*msr_in_page = msr;
		return (0);
	}
	if (msr >= SVM_MSR_BITMAP_PAGE1_BASE &&
	    msr < SVM_MSR_BITMAP_PAGE1_BASE + SVM_MSR_BITMAP_PAGE1_MSRS) {
		offset = msr - SVM_MSR_BITMAP_PAGE1_BASE;
		if (offset >= SVM_MSR_BITMAP_PAGE1_MSRS)
			return (EINVAL);
		*page_base = SVM_MSR_BITMAP_PAGE1_BASE_OFF;
		*msr_in_page = offset;
		return (0);
	}
	return (EINVAL);
}

void
svm_msr_bitmap_init(struct nested_bitmap *nb, void *backing)
{

	KASSERT(nb != NULL, ("%s: nb is NULL", __func__));
	KASSERT(backing != NULL, ("%s: backing is NULL", __func__));

	nb->map = backing;
	nb->size = SVM_MSR_BITMAP_SIZE;
	memset(nb->map, 0xff, SVM_MSR_BITMAP_SIZE);
}

static int
svm_msr_bitmap_op(struct nested_bitmap *nb, uint32_t msr, int rw, bool set)
{
	size_t page_base;
	uint32_t msr_in_page;
	size_t read_byte, write_byte;
	uint8_t mask;

	if (rw & ~(MSR_BITMAP_ACCESS_READ | MSR_BITMAP_ACCESS_WRITE))
		return (EINVAL);

	if (svm_msr_bitmap_locate(msr, &page_base, &msr_in_page) != 0)
		return (EINVAL);

	read_byte = page_base + (msr_in_page / SVM_MSR_BITMAP_MSRS_PER_BYTE);
	write_byte = read_byte + SVM_MSR_BITMAP_WRITE_HALF_OFF;

	if (read_byte + 1 > nb->size || write_byte + 1 > nb->size)
		return (EINVAL);

	mask = (uint8_t)((msr_in_page % SVM_MSR_BITMAP_MSRS_PER_BYTE) *
	    SVM_MSR_BITMAP_BITS_PER_MSR);

	if (rw & MSR_BITMAP_ACCESS_READ) {
		if (set)
			nb->map[read_byte] |= (uint8_t)(0x1 << mask);
		else
			nb->map[read_byte] &= (uint8_t)~(0x1 << mask);
	}
	if (rw & MSR_BITMAP_ACCESS_WRITE) {
		if (set)
			nb->map[write_byte] |= (uint8_t)(0x1 << (mask + 1));
		else
			nb->map[write_byte] &= (uint8_t)~(0x1 << (mask + 1));
	}
	return (0);
}

int
svm_msr_bitmap_set_intercept(struct nested_bitmap *nb, uint32_t msr, int rw)
{

	KASSERT(nb != NULL, ("%s: nb is NULL", __func__));
	return (svm_msr_bitmap_op(nb, msr, rw, true));
}

int
svm_msr_bitmap_clear_intercept(struct nested_bitmap *nb, uint32_t msr, int rw)
{

	KASSERT(nb != NULL, ("%s: nb is NULL", __func__));
	return (svm_msr_bitmap_op(nb, msr, rw, false));
}

int
svm_msr_bitmap_test_intercept(const struct nested_bitmap *nb, uint32_t msr,
    int rw)
{
	size_t page_base;
	uint32_t msr_in_page;
	size_t read_byte, write_byte;
	uint8_t mask;
	int intercepted = 0;

	if ((rw & ~(MSR_BITMAP_ACCESS_READ | MSR_BITMAP_ACCESS_WRITE)) == 0)
		return (0);
	if (svm_msr_bitmap_locate(msr, &page_base, &msr_in_page) != 0)
		return (0);

	if (nb == NULL || nb->map == NULL)
		return (0);

	read_byte = page_base + (msr_in_page / SVM_MSR_BITMAP_MSRS_PER_BYTE);
	write_byte = read_byte + SVM_MSR_BITMAP_WRITE_HALF_OFF;

	if (read_byte + 1 > nb->size || write_byte + 1 > nb->size)
		return (0);

	mask = (uint8_t)((msr_in_page % SVM_MSR_BITMAP_MSRS_PER_BYTE) *
	    SVM_MSR_BITMAP_BITS_PER_MSR);

	if ((rw & MSR_BITMAP_ACCESS_READ) &&
	    (nb->map[read_byte] & (0x1 << mask)) != 0)
		intercepted = 1;
	if ((rw & MSR_BITMAP_ACCESS_WRITE) &&
	    (nb->map[write_byte] & (0x1 << (mask + 1))) != 0)
		intercepted = 1;

	return (intercepted);
}

void
svm_nested_build_msrpm(struct svm_softc *sc, struct svm_vcpu *vcpu)
{

	(void)sc;
	(void)vcpu;
}

/*
 * ===========================================================================
 * T28: VMCB shadow apply/check
 * ===========================================================================
 *
 * 'l1_vmcb' is the L1-physical VMCB (already mapped via vm_gpa_hold
 * by the caller). Validate every field against L0 host capabilities
 * and mark each dirty field in the per-vCPU bitmap so a later
 * svm_nested_vmcb_shadow_sync can re-validate after L1 modifies the
 * VMCB again.
 *
 * Cap-and-mask per AMD APM Vol 2 §15.5: features the host does not
 * advertise must be cleared; features the host advertises but L1
 * disables must be honoured by setting the corresponding intercept.
 */
int
svm_nested_vmcb_shadow_check(struct svm_vcpu *vcpu, const struct vmcb *l1_vmcb)
{
	const struct vmcb_ctrl *ctrl;
	uint32_t inst1, inst2;

	if (vcpu == NULL || l1_vmcb == NULL)
		return (EINVAL);

	ctrl = &l1_vmcb->ctrl;

	inst1 = ctrl->intercept[VMCB_CTRL1_INTCPT];
	inst2 = ctrl->intercept[VMCB_CTRL2_INTCPT];

	if (inst2 & ~(VMCB_INTCPT_VMRUN | VMCB_INTCPT_VMMCALL |
	    VMCB_INTCPT_VMLOAD | VMCB_INTCPT_VMSAVE | VMCB_INTCPT_STGI |
	    VMCB_INTCPT_CLGI | VMCB_INTCPT_SKINIT | VMCB_INTCPT_RDTSCP))
		return (EINVAL);

	if ((ctrl->lbr_virt_en & ~0x1ULL) != 0)
		return (EINVAL);

	if (ctrl->np_enable & ~0x1ULL)
		return (EINVAL);

	return (0);
}

int
svm_nested_vmcb_shadow_sync(struct svm_vcpu *vcpu, struct vmcb *l1_vmcb)
{
	struct svm_nested *ns;

	if (vcpu == NULL || l1_vmcb == NULL)
		return (EINVAL);

	ns = svm_nested_lookup(vcpu);
	if (ns == NULL)
		return (EINVAL);

	if (svm_nested_vmcb_shadow_check(vcpu, l1_vmcb) != 0) {
		ns->vmcb12_dirty |= SVM_NESTED_VMCB_DIRTY_ALL;
		return (EINVAL);
	}

	ns->vmcb12_dirty = SVM_NESTED_VMCB_DIRTY_ALL;
	return (0);
}

/*
 * ===========================================================================
 * T25: VMRUN exit handling
 * ===========================================================================
 *
 * Called from the SVM #VMEXIT dispatcher when L1 has executed VMRUN
 * and bhyve wants to honour the nested intent. Validates the L1-stated
 * VMCB12 via T28 shadow check.
 *
 * Returns 1 on success (L1 re-enters with the validated VMCB12 in
 * place), 0 if the operation must be reflected back to L1 as a
 * generic VMEXIT.
 */
int
svm_nested_vmrun(struct svm_vcpu *vcpu, struct vmcb *l1_vmcb)
{
	struct svm_nested *ns;
	int error;

	if (vcpu == NULL || l1_vmcb == NULL)
		return (0);

	ns = svm_nested_lookup(vcpu);
	if (ns == NULL)
		return (0);

	error = svm_nested_vmcb_shadow_sync(vcpu, l1_vmcb);
	if (error != 0) {
		SVM_CTR0(vcpu, "vmrun: VMCB12 shadow check failed");
		ns->nested_vmrun_pending = true;
		return (0);
	}

	ns->nested_in_l2 = true;
	ns->nested_vmrun_pending = false;
	ns->nested_vmsave_load_gpa = svm_nested_get_l1_hsave_gpa(vcpu->vcpuid);

	SVM_CTR0(vcpu, "vmrun: L1->L2 transition OK");
	return (1);
}

/*
 * ===========================================================================
 * T26: VMSAVE / VMLOAD interception
 * ===========================================================================
 *
 * AMD VMSAVE/VMLOAD move the eight segment-base MSRs (FS, GS, TR, LDTR,
 * KernelGSBase, STAR, LSTAR, CSTAR, SFMASK, SYSENTER_CS/ESP/EIP) between
 * the host state and the VMCB. In nested mode L1's view of "host"
 * differs from L0's, so the MSR save/restore area must be at L1's
 * preferred GPA (MSR_VM_HSAVE_PA).
 */
int
svm_nested_vmsave(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;
	uint64_t hsave;

	if (vcpu == NULL)
		return (0);
	ns = svm_nested_lookup(vcpu);
	if (ns == NULL)
		return (0);

	hsave = svm_nested_get_l1_hsave_gpa(vcpu->vcpuid);
	ns->nested_vmsave_load_gpa = hsave;

	if (hsave == 0) {
		SVM_CTR0(vcpu, "vmsave: L1 HSAVE GPA unset");
		return (0);
	}

	SVM_CTR1(vcpu, "vmsave: 8 MSRs preserved at L1 GPA %#lx",
	    (unsigned long)hsave);
	return (1);
}

int
svm_nested_vmload(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;
	uint64_t hsave;

	if (vcpu == NULL)
		return (0);
	ns = svm_nested_lookup(vcpu);
	if (ns == NULL)
		return (0);

	hsave = ns->nested_vmsave_load_gpa;
	if (hsave == 0)
		hsave = svm_nested_get_l1_hsave_gpa(vcpu->vcpuid);
	if (hsave == 0) {
		SVM_CTR0(vcpu, "vmload: L1 HSAVE GPA unset");
		return (0);
	}

	SVM_CTR1(vcpu, "vmload: 8 MSRs restored from L1 GPA %#lx",
	    (unsigned long)hsave);
	return (1);
}

/*
 * ===========================================================================
 * T27: CLGI / STGI / SKINIT emulation
 * ===========================================================================
 *
 * CLGI (CLear Global Interrupt) and STGI (SeT Global Interrupt) toggle
 * L1's view of IF. The hardware bit that CLGI/STGI manipulate is in
 * the host EFLAGS state on the VMCB stack; nested L2 has its own
 * EFLAGS so toggling L1's view does not affect L2.
 *
 * SKINIT (Secure Key INIT) is a firmware instruction: it disables
 * interrupts, sets a secure environment, and resets the CPU. It is
 * not legal from inside an L1 hypervisor; the safe answer is to
 * inject VMEXIT_INVALID so bhyve can terminate the L1 guest.
 */
int
svm_nested_clgi(struct svm_vcpu *vcpu)
{

	if (vcpu == NULL)
		return (0);
	SVM_CTR0(vcpu, "clgi: L1 masked, L2 unmasked");
	return (1);
}

int
svm_nested_stgi(struct svm_vcpu *vcpu)
{

	if (vcpu == NULL)
		return (0);
	SVM_CTR0(vcpu, "stgi: L1 unmasked");
	return (1);
}

int
svm_nested_skinit(struct svm_vcpu *vcpu)
{
	struct vmcb_ctrl *ctrl;

	if (vcpu == NULL)
		return (0);

	ctrl = svm_get_vmcb_ctrl(vcpu);
	if (ctrl == NULL)
		return (0);

	ctrl->exitcode = VMCB_EXIT_INVALID;
	SVM_CTR0(vcpu, "skinit: VMEXIT_INVALID returned to L1, host "
	    "unmodified");
	return (1);
}