/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Nested SVM instruction emulation (VMRUN/VMLOAD/VMSAVE/CLGI/STGI/SKINIT).
 *
 * Original BSD code. AMD APM Vol 2 §15.5 / §15.19 are referenced for
 * the instruction semantics only. KVM nSVM was consulted for dispatch
 * order; no GPL source is copied.
 *
 * Limitation (v1): L0 nested-page tables are not composed with L1 NPT.
 * L2 GPA is translated with the existing L0 NPT (L2 GPA treated as L1
 * GPA). Full NPT12 walks belong in a later wave.
 */

#include <sys/cdefs.h>
#include <sys/param.h>
#include <sys/systm.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/vmm.h>

#include <dev/vmm/vmm_mem.h>
#include <dev/vmm/vmm_ktr.h>

#include "svm_softc.h"
#include "svm_nested.h"
#include "svm_nested_exit.h"
#include "svm_nested_stubs.h"
#include "vmcb.h"

static void
svm_nested_copy_sys_msrs(struct vmcb_state *dst, const struct vmcb_state *src)
{

	dst->fs = src->fs;
	dst->gs = src->gs;
	dst->kernelgsbase = src->kernelgsbase;
	dst->star = src->star;
	dst->lstar = src->lstar;
	dst->cstar = src->cstar;
	dst->sfmask = src->sfmask;
	dst->sysenter_cs = src->sysenter_cs;
	dst->sysenter_esp = src->sysenter_esp;
	dst->sysenter_eip = src->sysenter_eip;
}

static struct vmcb *
svm_nested_hold_vmcb(struct svm_vcpu *vcpu, uint64_t gpa, int prot,
    void **cookie)
{
	void *mapping;

	if (vcpu == NULL || vcpu->vcpu == NULL)
		return (NULL);
	if ((gpa & PAGE_MASK) != 0)
		return (NULL);
	mapping = vm_gpa_hold(vcpu->vcpu, gpa, PAGE_SIZE, prot, cookie);
	if (mapping == NULL)
		return (NULL);
	return (mapping);
}

int
svm_nested_vmrun(struct svm_vcpu *vcpu, struct vmcb *l1_vmcb)
{
	struct svm_nested *ns;
	struct vmcb *vmcb12;
	uint64_t gpa;
	void *cookie;

	if (vcpu == NULL || l1_vmcb == NULL)
		return (1);

	ns = svm_nested_lookup(vcpu);
	if (ns == NULL)
		return (1);

	gpa = l1_vmcb->state.rax;
	vmcb12 = svm_nested_hold_vmcb(vcpu, gpa,
	    VM_PROT_READ | VM_PROT_WRITE, &cookie);
	if (vmcb12 == NULL)
		return (1);

	/*
	 * APM Vol 2: VMRUN is illegal unless the VMCB intercepts VMRUN.
	 * ASID 0 is reserved on SVM.
	 */
	if ((vmcb12->ctrl.intercept[VMCB_CTRL2_INTCPT] &
	    VMCB_INTCPT_VMRUN) == 0 || vmcb12->ctrl.asid == 0) {
		vm_gpa_release(cookie);
		return (1);
	}

	svm_nested_release_vmcb12(vcpu);

	ns->l1_state = l1_vmcb->state;
	ns->vmcb12_gpa = gpa;
	ns->vmcb12 = vmcb12;
	ns->vmcb12_cookie = cookie;
	ns->nested_in_l2 = true;
	ns->gif = true;

	/* Enter L2: load L2 save area into the hardware VMCB. */
	l1_vmcb->state = vmcb12->state;
	l1_vmcb->ctrl.intercept[VMCB_CTRL2_INTCPT] |=
	    VMCB_INTCPT_VMRUN | VMCB_INTCPT_VMLOAD | VMCB_INTCPT_VMSAVE |
	    VMCB_INTCPT_STGI | VMCB_INTCPT_CLGI | VMCB_INTCPT_SKINIT;

	svm_nested_set_vmcb12(vmcb12);
	svm_set_dirty(vcpu, 0xffffffff);
	vcpu->nextrip = l1_vmcb->state.rip;
	SVM_CTR1(vcpu, "nested VMRUN vmcb12_gpa=%#lx", (unsigned long)gpa);
	return (0);
}

int
svm_nested_vmsave(struct svm_vcpu *vcpu)
{
	struct vmcb *vmcb, *dst;
	uint64_t gpa;
	void *cookie;

	if (vcpu == NULL)
		return (1);
	vmcb = svm_get_vmcb(vcpu);
	gpa = vmcb->state.rax;
	dst = svm_nested_hold_vmcb(vcpu, gpa, VM_PROT_READ | VM_PROT_WRITE,
	    &cookie);
	if (dst == NULL)
		return (1);
	svm_nested_copy_sys_msrs(&dst->state, &vmcb->state);
	vm_gpa_release(cookie);
	return (0);
}

int
svm_nested_vmload(struct svm_vcpu *vcpu)
{
	struct vmcb *vmcb, *src;
	uint64_t gpa;
	void *cookie;

	if (vcpu == NULL)
		return (1);
	vmcb = svm_get_vmcb(vcpu);
	gpa = vmcb->state.rax;
	src = svm_nested_hold_vmcb(vcpu, gpa, VM_PROT_READ, &cookie);
	if (src == NULL)
		return (1);
	svm_nested_copy_sys_msrs(&vmcb->state, &src->state);
	svm_set_dirty(vcpu, VMCB_CACHE_SEG);
	vm_gpa_release(cookie);
	return (0);
}

int
svm_nested_clgi(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;

	ns = svm_nested_lookup(vcpu);
	if (ns == NULL)
		return (1);
	ns->gif = false;
	return (0);
}

int
svm_nested_stgi(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;

	ns = svm_nested_lookup(vcpu);
	if (ns == NULL)
		return (1);
	ns->gif = true;
	return (0);
}

void
svm_nested_skinit(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;
	struct vmcb *vmcb12;

	ns = svm_nested_lookup(vcpu);
	vmcb12 = (ns != NULL) ? ns->vmcb12 : NULL;
	svm_nested_handle_vmexit(vcpu, vmcb12, VMCB_EXIT_INVALID, 0, 0);
}

void
svm_nested_tlb_flush(struct svm_vcpu *vcpu)
{
	struct vmcb_ctrl *ctrl;

	if (vcpu == NULL || vcpu->vmcb == NULL)
		return;
	ctrl = svm_get_vmcb_ctrl(vcpu);
	ctrl->tlb_ctrl = VMCB_TLB_FLUSH_GUEST;
	svm_set_dirty(vcpu, VMCB_CACHE_ASID);
}
