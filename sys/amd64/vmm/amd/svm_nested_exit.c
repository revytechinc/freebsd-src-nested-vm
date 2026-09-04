/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 *
 * Nested SVM #VMEXIT reflection: L2 -> L1.
 *
 * Every #VMEXIT taken while the vCPU is running L2 comes through
 * svm_nested_l2_exit(). If L1 asked to intercept the condition (its
 * VMCB12 intercept vectors, IOPM or MSRPM), the L2 save area is written
 * back to VMCB12 together with the exit information, the parked L1
 * state is restored into the hardware VMCB and L1 resumes after VMRUN
 * with GIF clear, exactly as hardware would deliver a #VMEXIT to it.
 * Otherwise L0 handles the exit itself on behalf of L2 (CPUID, I/O to
 * L0-emulated devices, nested page faults under the flat-NPT model).
 *
 * Original BSD code; AMD APM Vol 2 §15.6 and §15.7 are referenced for
 * the #VMEXIT semantics and the exit-code / intercept-bit mapping.
 */

#include <sys/cdefs.h>

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/vmm.h>
#include <dev/vmm/vmm_mem.h>
#include <dev/vmm/vmm_ktr.h>

#include "svm_softc.h"
#include "svm_nested.h"
#include "svm_nested_exit.h"
#include "svm_nested_stubs.h"
#include "vmm_nested.h"
#include "vmcb.h"

struct svm_nested *
svm_nested_lookup(struct svm_vcpu *vcpu)
{

	if (vcpu == NULL)
		return (NULL);
	return (&vcpu->nested);
}

bool
svm_nested_in_l2(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;

	ns = svm_nested_lookup(vcpu);
	return (ns != NULL && ns->nested_in_l2);
}

void
svm_nested_release_vmcb12(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;

	ns = svm_nested_lookup(vcpu);
	if (ns == NULL)
		return;
	if (ns->vmcb12_cookie != NULL) {
		vm_gpa_release(ns->vmcb12_cookie);
		ns->vmcb12_cookie = NULL;
	}
	ns->vmcb12 = NULL;
	ns->vmcb12_gpa = 0;
}

/*
 * Does L1's IOPM intercept 'port'? One bit per port (APM §15.10.1); the
 * pages were held at VMRUN so this is safe in the exit handler. A page
 * that could not be held reads as "intercept" (fail closed).
 */
static bool
svm_nested_l1_iopm_intercepts(struct svm_vcpu *vcpu, uint64_t exitinfo1)
{
	struct svm_nested *ns;
	unsigned port, byte;

	ns = svm_nested_lookup(vcpu);
	port = (exitinfo1 >> 16) & 0xffff;
	byte = port / 8;
	if (ns->l1_iopm[byte / PAGE_SIZE] == NULL)
		return (true);
	return ((ns->l1_iopm[byte / PAGE_SIZE][byte % PAGE_SIZE] &
	    (1 << (port % 8))) != 0);
}

/*
 * Does L1's MSRPM intercept the MSR in RCX? svm_msr_bitmap_locate()
 * gives the read bit, the write bit follows it; EXITINFO1 bit 0 is set
 * for WRMSR. MSRs outside the mapped ranges always exit.
 */
static bool
svm_nested_l1_msrpm_intercepts(struct svm_vcpu *vcpu, uint64_t exitinfo1)
{
	struct svm_nested *ns;
	struct svm_regctx *ctx;
	size_t byte;
	unsigned bit;

	ns = svm_nested_lookup(vcpu);
	ctx = svm_get_guest_regctx(vcpu);
	if (svm_msr_bitmap_locate((uint32_t)ctx->sctx_rcx, &byte, &bit) != 0)
		return (true);
	if ((exitinfo1 & 1) != 0)
		bit++;
	if (ns->l1_msrpm[byte / PAGE_SIZE] == NULL)
		return (true);
	return ((ns->l1_msrpm[byte / PAGE_SIZE][byte % PAGE_SIZE] &
	    (1u << bit)) != 0);
}

/*
 * Would L1 have taken this exit? Exit codes below 0xA0 map directly
 * onto the five 32-bit intercept vectors (APM §15.7 / Appendix C).
 */
static bool
svm_nested_l1_intercepts(struct svm_vcpu *vcpu, uint64_t exitcode,
    uint64_t exitinfo1);

bool
svm_nested_l2_exit_needed(struct svm_vcpu *vcpu, uint64_t exitcode,
    uint64_t exitinfo1)
{
	struct svm_nested *ns;

	ns = svm_nested_lookup(vcpu);
	if (ns == NULL || !ns->nested_in_l2 || ns->vmcb12 == NULL)
		return (false);
	if (exitcode == VMCB_EXIT_NPF)
		return (ns->vmcb12->ctrl.np_enable != 0);
	return (svm_nested_l1_intercepts(vcpu, exitcode, exitinfo1));
}

static bool
svm_nested_l1_intercepts(struct svm_vcpu *vcpu, uint64_t exitcode,
    uint64_t exitinfo1)
{
	struct svm_nested *ns;
	const struct vmcb_ctrl *c12;
	unsigned word, bit;

	ns = svm_nested_lookup(vcpu);
	c12 = &ns->vmcb12->ctrl;

	switch (exitcode) {
	case VMCB_EXIT_INVALID:
		/* The hardware rejected the composed VMCB: L1's problem. */
		return (true);
	case VMCB_EXIT_IO:
		if ((c12->intercept[VMCB_CTRL1_INTCPT] & VMCB_INTCPT_IO) == 0)
			return (false);
		return (svm_nested_l1_iopm_intercepts(vcpu, exitinfo1));
	case VMCB_EXIT_MSR:
		if ((c12->intercept[VMCB_CTRL1_INTCPT] & VMCB_INTCPT_MSR) == 0)
			return (false);
		return (svm_nested_l1_msrpm_intercepts(vcpu, exitinfo1));
	default:
		break;
	}
	if (exitcode >= 0xa0)
		return (false);
	word = exitcode / 32;
	bit = exitcode % 32;
	return ((c12->intercept[word] & (1u << bit)) != 0);
}

int
svm_nested_l2_exit(struct svm_vcpu *vcpu, uint64_t exitcode,
    uint64_t exitinfo1, uint64_t exitinfo2)
{
	struct svm_nested *ns;
	int error;

	ns = svm_nested_lookup(vcpu);
	if (ns == NULL || !ns->nested_in_l2 || ns->vmcb12 == NULL)
		return (0);

	if (exitcode == VMCB_EXIT_NPF) {
		/*
		 * Nested page fault under the shadow NPT: install the
		 * translation and resume L2, or reflect to L1 if its
		 * table does not map the address. With L1 nested paging
		 * off, L2 GPAs are L1 GPAs and L0 handles the fault.
		 */
		error = svm_nested_npt_fault(vcpu, exitinfo2, exitinfo1);
		if (error < 0)
			return (0);
		return (error == 0 ? 2 : 1);
	}

	if (!svm_nested_l1_intercepts(vcpu, exitcode, exitinfo1)) {
		svm_nested_trace(vcpu, "l2-exit-l0", exitcode,
		    svm_get_vmcb_state(vcpu)->rip);
		SVM_CTR1(vcpu, "L2 exit %#lx handled by L0",
		    (unsigned long)exitcode);
		return (0);
	}
	svm_nested_reflect_l2_exit(vcpu, exitcode, exitinfo1, exitinfo2);
	return (1);
}

/*
 * #VMEXIT restores only part of the host (L1) state from the host save
 * area: the segment registers ES/CS/SS/DS, GDTR/IDTR, EFER, CR0/CR3/CR4,
 * RFLAGS, RIP, RSP and RAX (APM Vol 2 §15.5.2 / §15.6). FS, GS, TR,
 * LDTR, KernelGsBase, STAR/LSTAR/CSTAR/SFMASK and the SYSENTER MSRs are
 * deliberately left as L2 loaded them, so that L1's VMSAVE after the
 * exit captures L2's values and L1 reloads its own with its usual
 * wrmsr/ltr/lldt sequence.
 */
static void
svm_nested_restore_l1_host_state(struct vmcb_state *hw,
    const struct vmcb_state *l1)
{

	hw->es = l1->es;
	hw->cs = l1->cs;
	hw->ss = l1->ss;
	hw->ds = l1->ds;
	hw->gdt = l1->gdt;
	hw->idt = l1->idt;
	hw->cpl = l1->cpl;
	hw->efer = l1->efer;
	hw->cr4 = l1->cr4;
	hw->cr3 = l1->cr3;
	hw->cr0 = l1->cr0;
	hw->dr7 = l1->dr7;
	hw->dr6 = l1->dr6;
	hw->rflags = l1->rflags;
	hw->rip = l1->rip;
	hw->rsp = l1->rsp;
	hw->rax = l1->rax;
	hw->cr2 = l1->cr2;
	hw->g_pat = l1->g_pat;
	hw->dbgctl = l1->dbgctl;
}

/*
 * Deliver #VMEXIT(exitcode) to L1 for the L2 that is running.
 */
void
svm_nested_reflect_l2_exit(struct svm_vcpu *vcpu, uint64_t exitcode,
    uint64_t exitinfo1, uint64_t exitinfo2)
{
	struct svm_nested *ns;
	struct vmcb *vmcb, *vmcb12;
	struct vmcb_ctrl *ctrl;
	int i;

	ns = svm_nested_lookup(vcpu);
	KASSERT(ns->nested_in_l2 && ns->vmcb12 != NULL,
	    ("svm_nested_reflect_l2_exit: not in L2"));
	if (exitcode != VMCB_EXIT_INTR && exitcode != VMCB_EXIT_NPF) {
		svm_nested_trace(vcpu, "reflect", exitcode,
		    svm_get_vmcb_state(vcpu)->rip);
		svm_nested_trace(vcpu, "reflect-info", exitinfo1, exitinfo2);
	}

	vmcb = svm_get_vmcb(vcpu);
	ctrl = &vmcb->ctrl;
	vmcb12 = ns->vmcb12;

	/*
	 * #VMEXIT to L1: write the L2 save area and the exit information
	 * into VMCB12. The event that was being delivered when the exit
	 * happened (EXITINTINFO) belongs to L1 now; clear it in the
	 * hardware VMCB so L0 does not re-inject it into L1.
	 */
	vmcb12->state = vmcb->state;
	vmcb12->ctrl.exitcode = exitcode;
	vmcb12->ctrl.exitinfo1 = exitinfo1;
	vmcb12->ctrl.exitinfo2 = exitinfo2;
	vmcb12->ctrl.exitintinfo = ctrl->exitintinfo;
	vmcb12->ctrl.nrip = ctrl->nrip;
	vmcb12->ctrl.inst_len = ctrl->inst_len;
	memcpy(vmcb12->ctrl.inst_bytes, ctrl->inst_bytes,
	    sizeof(vmcb12->ctrl.inst_bytes));
	memcpy(&vmcb12->ctrl.v_tpr, &ctrl->v_tpr, sizeof(ns->l0_vintr));
	/*
	 * L1 keeps V_IRQ and the VINTR intercept in lockstep (its
	 * enable/disable_intr_window_exiting set and clear both together and
	 * assert on a mismatch). Hardware may have cleared V_IRQ while L2 ran;
	 * mirror that into L1's VINTR intercept in VMCB12 so the invariant L1
	 * re-checks on the reflected exit still holds.
	 */
	if (vmcb12->ctrl.v_irq)
		vmcb12->ctrl.intercept[VMCB_CTRL1_INTCPT] |= VMCB_INTCPT_VINTR;
	else
		vmcb12->ctrl.intercept[VMCB_CTRL1_INTCPT] &= ~VMCB_INTCPT_VINTR;
	vmcb12->ctrl.intr_shadow = ctrl->intr_shadow;
	vmcb12->ctrl.eventinj = 0;
	ctrl->exitintinfo = 0;

	/* Restore L1 (the #VMEXIT-restored subset) and L0's control fields. */
	svm_nested_restore_l1_host_state(&vmcb->state, &ns->l1_state);
	for (i = 0; i < 5; i++)
		ctrl->intercept[i] = ns->l0_intercept[i];
	memcpy(&ctrl->v_tpr, &ns->l0_vintr, sizeof(ns->l0_vintr));
	ctrl->intr_shadow = ns->l1_intr_shadow;
	ctrl->tsc_offset = ns->l0_tsc_offset;
	ctrl->n_cr3 = ns->l0_ncr3;
	ctrl->eventinj = 0;

	ns->nested_in_l2 = false;
	ns->gif = false;		/* #VMEXIT clears GIF */
	svm_nested_release_l1_maps(vcpu);
	svm_set_dirty(vcpu, 0xffffffff);
	svm_nested_tlb_flush(vcpu);

	SVM_CTR3(vcpu, "L2 exit %#lx info1=%#lx reflected to L1 rip=%#lx",
	    (unsigned long)exitcode, (unsigned long)exitinfo1,
	    (unsigned long)vmcb->state.rip);
}
