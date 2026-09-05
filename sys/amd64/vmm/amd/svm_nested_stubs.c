/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Nested SVM instruction emulation (VMRUN/VMLOAD/VMSAVE/CLGI/STGI).
 *
 * Original BSD code.
 *
 * Model (v1):
 *
 *   - The hardware VMCB owned by L0 doubles as VMCB02. On VMRUN the L1
 *     save area and the L0-owned control fields are parked in
 *     'struct svm_nested', the L2 save area from VMCB12 is loaded, and
 *     the L1 intercept vectors are OR-ed into L0's.
 *   - When L1 enables nested paging for L2, L2 runs under a per-vCPU
 *     shadow NPT built from VMCB12.N_CR3 (svm_nested_npt.c). When L1
 *     runs L2 without nested paging, L2 guest-physical addresses are L1
 *     guest-physical addresses by definition and L0's own NPT applies.
 *   - On an intercepted L2 exit (see svm_nested_exit.c) the L2 save
 *     area is written back to VMCB12, the L1 state is restored, and L1
 *     resumes at the instruction after VMRUN with GIF clear.
 */

#include <sys/cdefs.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/sysctl.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/vmm.h>
#include <machine/specialreg.h>
#include <x86/psl.h>

#include <dev/vmm/vmm_mem.h>
#include <dev/vmm/vmm_ktr.h>

#include "svm_softc.h"
#include "svm_nested.h"
#include "svm_nested_exit.h"
#include "svm_nested_stubs.h"
#include "vmcb.h"

SYSCTL_DECL(_hw_vmm_nested);
int svm_nested_debug;
SYSCTL_INT(_hw_vmm_nested, OID_AUTO, svm_debug, CTLFLAG_RWTUN,
    &svm_nested_debug, 0,
    "Log the first nested-SVM events per vCPU to the console");

/*
 * Rate-limited console trace of the nested state machine, for bring-up
 * on machines without a serial console: only the first
 * SVM_NESTED_DEBUG_MAX events per vCPU are printed, counted from the
 * first VMRUN. Console output is slow enough to starve L2 of its
 * time slice, so the budget is deliberately small.
 */
#define	SVM_NESTED_DEBUG_MAX	700
void
svm_nested_trace(struct svm_vcpu *vcpu, const char *what, uint64_t a,
    uint64_t b)
{
	struct svm_nested *ns;

	if (svm_nested_debug == 0)
		return;
	ns = svm_nested_lookup(vcpu);
	if (ns == NULL || ns->debug_count >= SVM_NESTED_DEBUG_MAX)
		return;
	ns->debug_count++;
	printf("svm_nested[%d]: %s %#lx %#lx\n", vcpu->vcpuid, what,
	    (unsigned long)a, (unsigned long)b);
}

/*
 * VMLOAD/VMSAVE transfer FS, GS, TR, LDTR (including hidden state),
 * KernelGsBase, STAR, LSTAR, CSTAR, SFMASK and SYSENTER_{CS,ESP,EIP}.
 */
static void
svm_nested_copy_vmload_state(struct vmcb_state *dst,
    const struct vmcb_state *src)
{

	dst->fs = src->fs;
	dst->gs = src->gs;
	dst->tr = src->tr;
	dst->ldt = src->ldt;
	dst->kernelgsbase = src->kernelgsbase;
	dst->star = src->star;
	dst->lstar = src->lstar;
	dst->cstar = src->cstar;
	dst->sfmask = src->sfmask;
	dst->sysenter_cs = src->sysenter_cs;
	dst->sysenter_esp = src->sysenter_esp;
	dst->sysenter_eip = src->sysenter_eip;
}

struct vmcb *
svm_nested_hold_vmcb(struct svm_vcpu *vcpu, uint64_t gpa, int prot,
    void **cookie)
{
	void *mapping;

	if (vcpu == NULL || vcpu->vcpu == NULL)
		return (NULL);
	if ((gpa & PAGE_MASK) != 0)
		return (NULL);
	mapping = vm_gpa_hold(vcpu->vcpu, gpa, PAGE_SIZE, prot, cookie);
	return (mapping);
}

/*
 * Fail a VMRUN the way hardware does for an inconsistent VMCB: the
 * guest sees #VMEXIT(INVALID) in its VMCB and continues after VMRUN.
 */
static void
svm_nested_vmrun_invalid(struct vmcb *vmcb12)
{

	vmcb12->ctrl.exitcode = VMCB_EXIT_INVALID;
	vmcb12->ctrl.exitinfo1 = 0;
	vmcb12->ctrl.exitinfo2 = 0;
	vmcb12->ctrl.exitintinfo = 0;
}

/*
 * Minimal subset of the VMRUN consistency checks. Anything
 * L0 does not model is left to hardware, which reports an INVALID exit
 * that svm_nested_l2_exit() reflects to L1.
 */
static bool
svm_nested_vmcb12_consistent(const struct vmcb *vmcb12)
{
	const struct vmcb_state *st = &vmcb12->state;
	const struct vmcb_ctrl *ctrl = &vmcb12->ctrl;

	if ((ctrl->intercept[VMCB_CTRL2_INTCPT] & VMCB_INTCPT_VMRUN) == 0)
		return (false);
	if (ctrl->asid == 0)
		return (false);
	if ((st->efer & EFER_SVM) == 0)
		return (false);
	if ((st->cr0 & CR0_CD) == 0 && (st->cr0 & CR0_NW) != 0)
		return (false);
	if ((st->cr0 >> 32) != 0)
		return (false);
	if ((st->efer & EFER_LME) != 0 && (st->cr0 & CR0_PG) != 0 &&
	    (st->cr4 & CR4_PAE) == 0)
		return (false);
	return (true);
}

/*
 * VMRUN from L1. 'l1_next_rip' is where L1 resumes after the L2 guest
 * exits back to it.
 *
 * Returns:
 *   0  L2 state is loaded in the hardware VMCB; caller must not advance
 *      RIP (it is L2's now).
 *   2  VMRUN failed with #VMEXIT(INVALID) reflected into VMCB12; L1
 *      continues at l1_next_rip.
 *   1  not emulated; caller injects #UD.
 */
int
svm_nested_vmrun(struct svm_vcpu *vcpu, uint64_t l1_next_rip)
{
	struct svm_nested *ns;
	struct vmcb *vmcb, *vmcb12;
	struct vmcb_ctrl *ctrl;
	uint64_t gpa;
	void *cookie;
	uint64_t iopm_pa, msrpm_pa;
	uint32_t intcpt1;
	int i;

	if (vcpu == NULL)
		return (1);
	ns = svm_nested_lookup(vcpu);
	if (ns == NULL || ns->nested_in_l2)
		return (1);
	vmcb = svm_get_vmcb(vcpu);
	ctrl = &vmcb->ctrl;

	gpa = vmcb->state.rax;
	vmcb12 = svm_nested_hold_vmcb(vcpu, gpa, VM_PROT_READ | VM_PROT_WRITE,
	    &cookie);
	if (vmcb12 == NULL) {
		SVM_CTR1(vcpu, "nested VMRUN: unmappable VMCB12 %#lx",
		    (unsigned long)gpa);
		return (1);
	}

	if (vmcb12->ctrl.np_enable != 0 && svm_nested_npt_init(vcpu) != 0) {
		svm_nested_vmrun_invalid(vmcb12);
		vm_gpa_release(cookie);
		return (2);
	}

	/*
	 * Snapshot the L1-controlled IOPM/MSRPM bases and the intercept word
	 * ONCE. VMCB12 stays mapped writable for the whole L2 run, so a second
	 * L1 vCPU can mutate these between the checks below and the holds that
	 * follow. Validating one fetch and then holding another let L1 slip a
	 * misaligned base past the alignment check into vm_gpa_hold(), whose
	 * page-crossing guard panic()s -- a race-reachable whole-host DoS from
	 * any multi-vCPU nested L1. Use only these locals hereafter.
	 */
	intcpt1 = vmcb12->ctrl.intercept[VMCB_CTRL1_INTCPT];
	iopm_pa = vmcb12->ctrl.iopm_base_pa;
	msrpm_pa = vmcb12->ctrl.msrpm_base_pa;

	if (!svm_nested_vmcb12_consistent(vmcb12) ||
	    ((intcpt1 & VMCB_INTCPT_IO) != 0 && (iopm_pa & PAGE_MASK) != 0) ||
	    ((intcpt1 & VMCB_INTCPT_MSR) != 0 && (msrpm_pa & PAGE_MASK) != 0)) {
		SVM_CTR1(vcpu, "nested VMRUN: inconsistent VMCB12 %#lx",
		    (unsigned long)gpa);
		svm_nested_vmrun_invalid(vmcb12);
		vm_gpa_release(cookie);
		return (2);
	}

	/*
	 * Park L1. The saved RIP is the instruction after VMRUN so the
	 * eventual #VMEXIT resumes L1 there, not at VMRUN again.
	 */
	svm_nested_release_l1_maps(vcpu);

	/*
	 * Hold L1's IOPM and MSRPM for the exit handler, which runs in a
	 * critical section and cannot take them then. Only the maps for
	 * the intercepts L1 enabled are required.
	 */
	if ((intcpt1 & VMCB_INTCPT_IO) != 0) {
		for (i = 0; i < 3; i++)
			ns->l1_iopm[i] = vm_gpa_hold(vcpu->vcpu,
			    iopm_pa + i * PAGE_SIZE, PAGE_SIZE,
			    VM_PROT_READ, &ns->l1_iopm_cookie[i]);
	}
	if ((intcpt1 & VMCB_INTCPT_MSR) != 0) {
		for (i = 0; i < 2; i++)
			ns->l1_msrpm[i] = vm_gpa_hold(vcpu->vcpu,
			    msrpm_pa + i * PAGE_SIZE, PAGE_SIZE,
			    VM_PROT_READ, &ns->l1_msrpm_cookie[i]);
	}

	ns->l1_state = vmcb->state;
	ns->l1_state.rip = l1_next_rip;
	ns->l1_intr_shadow = ctrl->intr_shadow;
	for (i = 0; i < 5; i++)
		ns->l0_intercept[i] = ctrl->intercept[i];
	ns->l0_tsc_offset = ctrl->tsc_offset;
	ns->l0_ncr3 = ctrl->n_cr3;
	memcpy(&ns->l0_vintr, &ctrl->v_tpr, sizeof(ns->l0_vintr));

	ns->vmcb12_gpa = gpa;
	ns->vmcb12 = vmcb12;
	ns->vmcb12_cookie = cookie;

	/*
	 * Compose VMCB02 in place.
	 *
	 * Save area: L2's, verbatim. Its EFER already has SVME set (checked
	 * above) so the hardware requirement that EFER.SVME be set while
	 * the guest runs holds.
	 *
	 * Control area: L0's intercepts are mandatory; L1's are added on
	 * top so any exit L1 asked for is taken and can be reflected. The
	 * virtual-interrupt block (V_TPR..V_INTR_VECTOR), the interrupt
	 * shadow and the pending event injection come from VMCB12. The
	 * TSC offset is the sum of L0's and L1's. IOPM/MSRPM/ASID/NPT stay
	 * L0's: L1's IOPM and MSRPM are consulted at exit time, and L2
	 * shares L0's ASID with a forced TLB flush on every L1<->L2 switch.
	 */
	vmcb->state = vmcb12->state;
	for (i = 0; i < 5; i++)
		ctrl->intercept[i] = ns->l0_intercept[i] |
		    vmcb12->ctrl.intercept[i];
	ctrl->intercept[VMCB_CTRL2_INTCPT] |= VMCB_INTCPT_VMRUN |
	    VMCB_INTCPT_VMLOAD | VMCB_INTCPT_VMSAVE | VMCB_INTCPT_STGI |
	    VMCB_INTCPT_CLGI | VMCB_INTCPT_SKINIT;
	/*
	 * Do not reflect L2's PAUSE spins up to L1. Both VMCB01 and L1's
	 * VMCB12 enable PAUSE-exiting, but reflecting every PAUSE an L2 idle
	 * loop (sched_ule_idletd) executes -- observed ~740k during a single
	 * mount-root wait -- storms L1 and starves the window in which L1
	 * would inject L2's LAPIC timer, wedging the boot. Mirror the Intel
	 * PROCBASED_PAUSE_EXITING clear in vmx_nested_entry.c.
	 */
	ctrl->intercept[VMCB_CTRL1_INTCPT] &= ~VMCB_INTCPT_PAUSE;
	/* Bring-up aid: see L2's page faults (re-injected by L0). */
	if (svm_nested_debug)
		ctrl->intercept[VMCB_EXC_INTCPT] |= 1u << IDT_PF;
	memcpy(&ctrl->v_tpr, &vmcb12->ctrl.v_tpr, sizeof(ns->l0_vintr));
	ctrl->intr_shadow = vmcb12->ctrl.intr_shadow;
	ctrl->tsc_offset = ns->l0_tsc_offset + vmcb12->ctrl.tsc_offset;
	ctrl->eventinj = vmcb12->ctrl.eventinj;
	if ((vmcb12->ctrl.eventinj & VMCB_EVENTINJ_VALID) != 0) {
		extern uint64_t svm_l2_inj_total, svm_l2_inj_vec[256];
		svm_l2_inj_total++;
		svm_l2_inj_vec[vmcb12->ctrl.eventinj & 0xff]++;
	}
	{
		extern uint64_t svm_l2_vmruns, svm_l2_vintr_want, svm_l2_notintr;
		svm_l2_vmruns++;
		if ((vmcb12->ctrl.intercept[VMCB_CTRL1_INTCPT] & VMCB_INTCPT_VINTR) != 0)
			svm_l2_vintr_want++;
		if ((vmcb12->state.rflags & PSL_I) == 0)
			svm_l2_notintr++;
	}

	/*
	 * Nested paging: L0's NPT is always on. With L1 nested paging on,
	 * point the hardware at the shadow of L1's table, discarding the
	 * shadow when L1 asked for a TLB flush or changed N_CR3 (the
	 * cached nested translations hardware would drop). Otherwise L2
	 * GPAs are L1 GPAs and L0's own table is the right one.
	 */
	if (vmcb12->ctrl.np_enable != 0) {
		if (vmcb12->ctrl.tlb_ctrl != VMCB_TLB_FLUSH_NOTHING ||
		    vmcb12->ctrl.n_cr3 != ns->l1_ncr3) {
			svm_nested_npt_flush(vcpu);
			ns->l1_ncr3 = vmcb12->ctrl.n_cr3;
		}
		ctrl->n_cr3 = ns->npt02_pa;
	}

	ns->nested_in_l2 = true;
	vcpu_set_nested_host(vcpu->vcpu);
	ns->gif = true;			/* VMRUN sets GIF */

	svm_set_dirty(vcpu, 0xffffffff);
	svm_nested_tlb_flush(vcpu);
	if (ns->l1_ncr3 == 0 && ns->debug_count > 0)
		ns->debug_count = 0;	/* budget starts at the first VMRUN */
	if (ns->l1_ncr3 == 0)
		svm_nested_trace(vcpu, "vmrun", gpa, vmcb->state.rip);
	SVM_CTR2(vcpu, "nested VMRUN vmcb12=%#lx l2_rip=%#lx",
	    (unsigned long)gpa, (unsigned long)vmcb->state.rip);
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
	svm_nested_copy_vmload_state(&dst->state, &vmcb->state);
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
	svm_nested_copy_vmload_state(&vmcb->state, &src->state);
	vm_gpa_release(cookie);
	/* FS/GS/TR/LDTR and the MSRs are not covered by VMCB clean bits. */
	svm_set_dirty(vcpu, VMCB_CACHE_SEG | VMCB_CACHE_DT);
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

bool
svm_nested_gif(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;

	ns = svm_nested_lookup(vcpu);
	return (ns == NULL || ns->gif);
}

/*
 * Force a TLB flush on the next VMRUN. L1 and L2 share L0's ASID, so
 * every switch between them must discard the other's translations.
 * Zeroing the ASID generation makes check_asid() allocate a fresh ASID
 * (with a flush) before the next entry; ctrl->tlb_ctrl cannot be set
 * directly because check_asid() resets it.
 */
void
svm_nested_tlb_flush(struct svm_vcpu *vcpu)
{

	if (vcpu == NULL)
		return;
	vcpu->asid.gen = 0;
}

/*
 * Drop every L1 page held for the current L2 run.
 */
void
svm_nested_release_l1_maps(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;
	int i;

	ns = svm_nested_lookup(vcpu);
	if (ns == NULL)
		return;
	for (i = 0; i < 3; i++) {
		if (ns->l1_iopm[i] != NULL) {
			vm_gpa_release(ns->l1_iopm_cookie[i]);
			ns->l1_iopm[i] = NULL;
			ns->l1_iopm_cookie[i] = NULL;
		}
	}
	for (i = 0; i < 2; i++) {
		if (ns->l1_msrpm[i] != NULL) {
			vm_gpa_release(ns->l1_msrpm_cookie[i]);
			ns->l1_msrpm[i] = NULL;
			ns->l1_msrpm_cookie[i] = NULL;
		}
	}
	svm_nested_release_vmcb12(vcpu);
}

/*
 * vmm_ops.nested for SVM: complete the work the exit handler deferred.
 * Runs from vm_run() outside the critical section. Sets vme->rip to
 * the resume address and returns 0, or returns an error to hand the
 * exit to userland.
 */
int
svm_nested_op(void *vcpui, struct vm_exit *vme)
{
	struct svm_vcpu *vcpu = vcpui;
	struct vmcb_state *state;
	int error;

	state = svm_get_vmcb_state(vcpu);
	switch (vme->u.nested.op) {
	case VM_NESTED_OP_VMRUN:
		error = svm_nested_vmrun(vcpu, vme->u.nested.info1);
		if (error == 0)
			vme->rip = state->rip;		/* now L2's */
		else if (error == 2)
			vme->rip = vme->u.nested.info1;	/* VMEXIT_INVALID */
		else {
			vm_inject_ud(vcpu->vcpu);
			vme->rip = state->rip;
		}
		return (0);
	case VM_NESTED_OP_VMLOAD:
	case VM_NESTED_OP_VMSAVE:
		if (vme->u.nested.op == VM_NESTED_OP_VMLOAD)
			error = svm_nested_vmload(vcpu);
		else
			error = svm_nested_vmsave(vcpu);
		if (error == 0) {
			vme->rip = vme->u.nested.info1;
		} else {
			vm_inject_ud(vcpu->vcpu);
			vme->rip = state->rip;
		}
		return (0);
	case VM_NESTED_OP_L2EXIT:
		error = svm_nested_l2_exit(vcpu, vme->u.nested.code,
		    vme->u.nested.info1, vme->u.nested.info2);
		if (error == 0)
			return (EINVAL);
		vme->rip = state->rip;	/* L2's (resolved) or L1's (reflected) */
		return (0);
	default:
		return (EINVAL);
	}
}
