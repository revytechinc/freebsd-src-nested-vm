/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * Nested VMX L2 execution: build a VMCS02, run L2 under a shadow EPT
 * (EPT02), and reflect L2 exits back to L1.
 *
 * Model:
 *   - VMCS02 host state is a verbatim copy of the L0 VMCS (vmcs01)'s
 *     host area, so an L2 #VMEXIT returns to exactly the same L0 host
 *     context (vmx_exit_guest) as an L1 exit.
 *   - VMCS02 control fields start from vmcs01's known-good L0 config
 *     (EPT on, MSR/IO bitmaps, pin/proc/exit/entry controls) and only
 *     the fields that must differ for L2 are overridden: EPTP points at
 *     the per-vCPU shadow EPT02, the guest CR0/CR4 read shadows and TSC
 *     offset come from VMCS12, and any event L1 queued in
 *     VMCS12.VM_ENTRY_INTR_INFO is injected. L2 therefore runs under
 *     L0's intercepts; exits L1 additionally wants are a later refinement.
 *   - VMCS02 guest state is loaded from VMCS12 (the L2 state L1 set up),
 *     with L0's fixed CR0/CR4 bits applied so VM entry is legal.
 *   - EPT02 maps L2 GPA -> host, filled lazily on L2 EPT violations by
 *     composing L1's EPT12 (L2 GPA -> L1 GPA) with L0's EPT (L1 GPA ->
 *     host). A fault L1's EPT cannot resolve is reflected to L1 as an
 *     EPT violation of its guest.
 *
 * This whole path is gated behind hw.vmm.nested.vmx_l2 (default off);
 * with the gate off VMLAUNCH/VMRESUME report an architectural VM-entry
 * failure to L1 (see vmx_nested_vmlaunch.c) and none of this runs.
 *
 * Original BSD code; Intel SDM Vol 3 Ch. 24-28 referenced for the VMCS
 * layout and entry/exit semantics.
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/malloc.h>
#include <sys/sysctl.h>
#include <sys/lock.h>
#include <sys/mutex.h>

#include <vm/vm.h>
#include <vm/vm_param.h>
#include <vm/pmap.h>
#include <vm/vm_page.h>

#include <machine/pmap.h>
#include <machine/specialreg.h>
#include <machine/vmm.h>

#include <dev/vmm/vmm_mem.h>
#include <dev/vmm/vmm_ktr.h>

#include "vmm_host.h"
#include "vmx_cpufunc.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_msr.h"
#include "vmx_controls.h"
#include "vmx_nested.h"
#include "vmx_nested_layout.h"
#include "ept.h"

static MALLOC_DEFINE(M_VMX_NESTED, "vmx_nested", "nested VMX L2 state");

SYSCTL_DECL(_hw_vmm_nested);
int vmx_nested_l2_enable;
SYSCTL_INT(_hw_vmm_nested, OID_AUTO, vmx_l2, CTLFLAG_RWTUN,
    &vmx_nested_l2_enable, 0,
    "Enable experimental nested VMX L2 execution (Intel; development only)");


/* Host-state fields copied verbatim vmcs01 -> vmcs02. */
static const uint32_t vmcs02_host_fields[] = {
	VMCS_HOST_CR0, VMCS_HOST_CR3, VMCS_HOST_CR4,
	VMCS_HOST_ES_SELECTOR, VMCS_HOST_CS_SELECTOR, VMCS_HOST_SS_SELECTOR,
	VMCS_HOST_DS_SELECTOR, VMCS_HOST_FS_SELECTOR, VMCS_HOST_GS_SELECTOR,
	VMCS_HOST_TR_SELECTOR,
	VMCS_HOST_FS_BASE, VMCS_HOST_GS_BASE, VMCS_HOST_TR_BASE,
	VMCS_HOST_GDTR_BASE, VMCS_HOST_IDTR_BASE,
	VMCS_HOST_IA32_SYSENTER_CS, VMCS_HOST_IA32_SYSENTER_ESP,
	VMCS_HOST_IA32_SYSENTER_EIP,
	VMCS_HOST_IA32_PAT, VMCS_HOST_IA32_EFER,
	VMCS_HOST_RSP, VMCS_HOST_RIP,
};

/* Control fields copied vmcs01 -> vmcs02 as the L0 base config. */
static const uint32_t vmcs02_ctrl_fields[] = {
	VMCS_PIN_BASED_CTLS, VMCS_PRI_PROC_BASED_CTLS, VMCS_SEC_PROC_BASED_CTLS,
	VMCS_EXIT_CTLS, VMCS_ENTRY_CTLS,
	VMCS_MSR_BITMAP, VMCS_IO_BITMAP_A, VMCS_IO_BITMAP_B,
	VMCS_EXCEPTION_BITMAP, VMCS_PF_ERROR_MASK, VMCS_PF_ERROR_MATCH,
	VMCS_CR0_MASK, VMCS_CR4_MASK,
	VMCS_ENTRY_MSR_LOAD_COUNT, VMCS_EXIT_MSR_LOAD_COUNT,
	VMCS_EXIT_MSR_STORE_COUNT,
};

/* Guest-state fields loaded from VMCS12 into vmcs02. */
static const uint32_t vmcs02_guest_fields[] = {
	VMCS_GUEST_ES_SELECTOR, VMCS_GUEST_CS_SELECTOR, VMCS_GUEST_SS_SELECTOR,
	VMCS_GUEST_DS_SELECTOR, VMCS_GUEST_FS_SELECTOR, VMCS_GUEST_GS_SELECTOR,
	VMCS_GUEST_LDTR_SELECTOR, VMCS_GUEST_TR_SELECTOR,
	VMCS_GUEST_ES_LIMIT, VMCS_GUEST_CS_LIMIT, VMCS_GUEST_SS_LIMIT,
	VMCS_GUEST_DS_LIMIT, VMCS_GUEST_FS_LIMIT, VMCS_GUEST_GS_LIMIT,
	VMCS_GUEST_LDTR_LIMIT, VMCS_GUEST_TR_LIMIT,
	VMCS_GUEST_GDTR_LIMIT, VMCS_GUEST_IDTR_LIMIT,
	VMCS_GUEST_ES_ACCESS_RIGHTS, VMCS_GUEST_CS_ACCESS_RIGHTS,
	VMCS_GUEST_SS_ACCESS_RIGHTS, VMCS_GUEST_DS_ACCESS_RIGHTS,
	VMCS_GUEST_FS_ACCESS_RIGHTS, VMCS_GUEST_GS_ACCESS_RIGHTS,
	VMCS_GUEST_LDTR_ACCESS_RIGHTS, VMCS_GUEST_TR_ACCESS_RIGHTS,
	VMCS_GUEST_ES_BASE, VMCS_GUEST_CS_BASE, VMCS_GUEST_SS_BASE,
	VMCS_GUEST_DS_BASE, VMCS_GUEST_FS_BASE, VMCS_GUEST_GS_BASE,
	VMCS_GUEST_LDTR_BASE, VMCS_GUEST_TR_BASE,
	VMCS_GUEST_GDTR_BASE, VMCS_GUEST_IDTR_BASE,
	VMCS_GUEST_CR3, VMCS_GUEST_DR7,
	VMCS_GUEST_RSP, VMCS_GUEST_RIP, VMCS_GUEST_RFLAGS,
	VMCS_GUEST_IA32_SYSENTER_CS, VMCS_GUEST_IA32_SYSENTER_ESP,
	VMCS_GUEST_IA32_SYSENTER_EIP,
	VMCS_GUEST_IA32_PAT, VMCS_GUEST_IA32_EFER, VMCS_GUEST_IA32_DEBUGCTL,
	VMCS_GUEST_INTERRUPTIBILITY, VMCS_GUEST_ACTIVITY,
	VMCS_GUEST_PENDING_DBG_EXCEPTIONS,
};

/* Guest-state fields written back vmcs02 -> VMCS12 on an L2 exit. */
/* (Same set as guest_fields plus the L2 RIP/RSP/RFLAGS already there.) */

int
vmx_nested_ept02_init(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	struct pmap *pmap;

	ns = vmx_nested_state(vcpu);
	if (ns->ept02 != NULL)
		return (0);
	pmap = malloc(sizeof(*pmap), M_VMX_NESTED, M_WAITOK | M_ZERO);
	PMAP_LOCK_INIT(pmap);
	if (ept_pinit_nested(pmap) == 0) {
		PMAP_LOCK_DESTROY(pmap);
		free(pmap, M_VMX_NESTED);
		return (ENOMEM);
	}
	ns->ept02 = pmap;
	ns->ept02_eptp = eptp(vtophys((vm_offset_t)pmap->pm_pmltop));
	return (0);
}

void
vmx_nested_ept02_flush(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;

	ns = vmx_nested_state(vcpu);
	if (ns->ept02 == NULL)
		return;
	pmap_remove(ns->ept02, 0, VM_MAXUSER_ADDRESS);
	ept_invalidate_mappings(ns->ept02_eptp);
}

void
vmx_nested_ept02_cleanup(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL || ns->ept02 == NULL)
		return;
	pmap_remove(ns->ept02, 0, VM_MAXUSER_ADDRESS);
	pmap_release(ns->ept02);
	PMAP_LOCK_DESTROY(ns->ept02);
	free(ns->ept02, M_VMX_NESTED);
	ns->ept02 = NULL;
	ns->ept02_eptp = 0;
	if (ns->vmcs02 != NULL) {
		free(ns->vmcs02, M_VMX_NESTED);
		ns->vmcs02 = NULL;
	}
}

/*
 * Resolve an L2 EPT violation. Returns 0 if the mapping was installed
 * and L2 can resume, 1 if it was reflected to L1, -1 on internal error.
 * 'l2_gpa' is the faulting L2 guest-physical address (VMCS_GUEST_
 * PHYSICAL_ADDRESS); 'qual' is the exit qualification (access type).
 */
int
vmx_nested_ept02_fault(struct vmx_vcpu *vcpu, uint64_t l2_gpa, uint64_t qual)
{
	struct vmx_nested_state *ns;
	vm_page_t m;
	void *cookie, *mapping;
	uint64_t l1_gpa;
	int access, prot, error;

	ns = vmx_nested_state(vcpu);
	if (qual & EPT_VIOLATION_DATA_WRITE)
		access = VM_PROT_WRITE;
	else if (qual & EPT_VIOLATION_INST_FETCH)
		access = VM_PROT_EXECUTE;
	else
		access = VM_PROT_READ;

	/*
	 * Runs from vm_run()'s deferred path: no VMCS is current and reflect
	 * (which does VMCLEAR/VMPTRLD, i.e. a critical_exit) must NOT be called
	 * here. The reflect-vs-fill decision was already made in vmx_run()
	 * (vmx_nested_l2_exit), so EPT12 maps this GPA; a failure below is a
	 * rare L0 backing error -- log and return, and L2 will re-fault.
	 */
	/*
	 * Translate with READ to decide fill-vs-reflect: we only need to know
	 * whether L1 maps this L2 GPA at all. Reflecting merely because the
	 * fault was a write (e.g. a guest page-table A/D-bit update) when L1
	 * maps the page read/write-through-intermediate-levels would force an
	 * unnecessary nested VM-exit into L1. Permissions for L2 are granted
	 * below in ept02 (RWX); a genuinely unmapped GPA still fails here and
	 * is reflected so L1 can populate EPT12.
	 */
	if (vmx_nested_ept12_translate(vcpu, l2_gpa, VM_PROT_READ,
	    &l1_gpa) != 0) {
		VMX_CTR1(vcpu, "L2 EPT: gpa %#lx unexpectedly unmapped",
		    (unsigned long)l2_gpa);
		return (1);
	}

	/* L1 GPA -> host page via L0's normal guest memory. */
	mapping = vm_gpa_hold(vcpu->vcpu, l1_gpa & ~PAGE_MASK, PAGE_SIZE,
	    access, &cookie);
	if (mapping == NULL) {
		VMX_CTR1(vcpu, "L2 EPT: l1_gpa %#lx not backed",
		    (unsigned long)l1_gpa);
		return (1);
	}
	m = cookie;
	prot = VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE;

	vm_page_busy_acquire(m, 0);
	error = pmap_enter(ns->ept02, l2_gpa & ~PAGE_MASK, m, prot, prot, 0);
	vm_page_xunbusy(m);
	vm_gpa_release(cookie);
	if (error != KERN_SUCCESS) {
		VMX_CTR2(vcpu, "L2 EPT02 pmap_enter(%#lx) failed %d",
		    (unsigned long)l2_gpa, error);
		return (1);
	}
	return (0);
}

/*
 * Build VMCS02 for entry into L2. vmcs01 must be the current VMCS on
 * entry; on return vmcs02 is the current VMCS, ready for vmx_enter_guest.
 */
int
vmx_nested_build_vmcs02(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	struct vmcs12 *v12;
	uint64_t hostv[nitems(vmcs02_host_fields)];
	uint64_t ctrlv[nitems(vmcs02_ctrl_fields)];
	uint64_t val, cr0, cr4, tsc01;
	unsigned i;

	ns = vmx_nested_state(vcpu);
	v12 = vcpu->nvmcs12;
	if (ns->ept02 == NULL && vmx_nested_ept02_init(vcpu) != 0)
		return (-1);
	if (ns->vmcs02 == NULL) {
		ns->vmcs02 = malloc_aligned(sizeof(struct vmcs), PAGE_SIZE,
		    M_VMX_NESTED, M_WAITOK | M_ZERO);
		ns->vmcs02->identifier = vmx_revision();
		ns->vmcs02_launched = false;
	}

	/*
	 * Snapshot vmcs01 host + control fields. This runs from vm_run()'s
	 * deferred nested-op path, where no VMCS is current (vmx_run()
	 * VMCLEARed vmcs01 on the way out), so make vmcs01 current before
	 * reading it -- otherwise vmcs_read() returns garbage and vmcs02 gets
	 * bogus control fields (VM entry fails with "invalid control field").
	 */
	VMPTRLD(vcpu->vmcs);
	for (i = 0; i < nitems(vmcs02_host_fields); i++)
		hostv[i] = vmcs_read(vmcs02_host_fields[i]);
	for (i = 0; i < nitems(vmcs02_ctrl_fields); i++)
		ctrlv[i] = vmcs_read(vmcs02_ctrl_fields[i]);
	tsc01 = vmcs_read(VMCS_TSC_OFFSET);
	VMCLEAR(vcpu->vmcs);		/* done reading vmcs01; balances VMPTRLD */

	/*
	 * Load L1's EPT root for the EPT12 walker. Flush the ept02 shadow ONLY
	 * when L1 switches to a different EPT root: build_vmcs02() runs on every
	 * VMRESUME (after each reflected L2 exit), and unconditionally flushing
	 * ept02 there would discard the whole shadow on every re-entry and make
	 * L2 re-fault every page it touches (a fault storm that stalls L2 boot).
	 * Staleness from L1 unmapping within the same EPT is handled by flushing
	 * ept02 on the L1 INVEPT path instead.
	 */
	if (vmcs12_read_field(v12, VMCS_EPTP, &val) == 0 &&
	    val != ns->ept12_pte) {
		vmx_nested_ept12_install(vcpu, val);
		vmx_nested_ept02_flush(vcpu);
	}

	/* Switch to vmcs02 and populate it. */
	vmclear(ns->vmcs02);
	VMPTRLD(ns->vmcs02);

	for (i = 0; i < nitems(vmcs02_host_fields); i++)
		vmwrite(vmcs02_host_fields[i], hostv[i]);
	for (i = 0; i < nitems(vmcs02_ctrl_fields); i++)
		vmwrite(vmcs02_ctrl_fields[i], ctrlv[i]);

	/* Guest state from VMCS12. */
	for (i = 0; i < nitems(vmcs02_guest_fields); i++) {
		if (vmcs12_read_field(v12, vmcs02_guest_fields[i], &val) == 0)
			vmwrite(vmcs02_guest_fields[i], val);
	}

	/* CR0/CR4: apply L0 fixed bits; read shadows = L1's stated values. */
	vmcs12_read_field(v12, VMCS_GUEST_CR0, &cr0);
	vmcs12_read_field(v12, VMCS_GUEST_CR4, &cr4);
	vmwrite(VMCS_GUEST_CR0, (cr0 | vmx_cr0_ones_mask) & ~vmx_cr0_zeros_mask);
	vmwrite(VMCS_GUEST_CR4, (cr4 | vmx_cr4_ones_mask) & ~vmx_cr4_zeros_mask);
	vmwrite(VMCS_CR0_SHADOW, cr0);
	vmwrite(VMCS_CR4_SHADOW, cr4);

	/*
	 * L0-owned overrides. Disable VPID for vmcs02 (a 0 VPID with the
	 * enable bit set is an illegal entry; EPT + INVEPT provides L2 TLB
	 * isolation). Set the IA-32e-mode-guest entry control to match L2's
	 * EFER.LMA, and force EPT on.
	 */
	/*
	 * Reduce vmcs02 to a minimal, self-consistent control set. vmcs01
	 * enables host features (TPR shadow, APICv/x2APIC virtualization,
	 * posted interrupts, VPID, MSR autoload) whose companion address
	 * fields we do not replicate into vmcs02; leaving the enable bits
	 * set with unpopulated address/count fields makes VM entry fail with
	 * "invalid control field" (error 7). Keep only EPT (with the ept02
	 * root) plus the plumbing L2 needs, and clear the rest. L2 exits on
	 * APIC/TPR accesses and is reflected to L1, which is correct for a
	 * first-cut L2 that does not yet virtualize APICv.
	 */
	val = vmcs_read(VMCS_PIN_BASED_CTLS);
	vmwrite(VMCS_PIN_BASED_CTLS,
	    val & ~(uint64_t)PINBASED_POSTED_INTERRUPT);

	val = vmcs_read(VMCS_PRI_PROC_BASED_CTLS);
	val &= ~(uint64_t)PROCBASED_USE_TPR_SHADOW;
	val |= PROCBASED_SECONDARY_CONTROLS;
	vmwrite(VMCS_PRI_PROC_BASED_CTLS, val);

	val = vmcs_read(VMCS_SEC_PROC_BASED_CTLS);
	val &= ~(uint64_t)(PROCBASED2_VIRTUALIZE_APIC_ACCESSES |
	    PROCBASED2_VIRTUALIZE_X2APIC_MODE |
	    PROCBASED2_APIC_REGISTER_VIRTUALIZATION |
	    PROCBASED2_VIRTUAL_INTERRUPT_DELIVERY |
	    PROCBASED2_ENABLE_VPID);
	val |= PROCBASED2_ENABLE_EPT;
	vmwrite(VMCS_SEC_PROC_BASED_CTLS, val);
	vmwrite(VMCS_VPID, 0);

	/*
	 * No MSR autoload/store for vmcs02: the count fields were copied from
	 * vmcs01 but the area-address fields were not, which is illegal. L2
	 * MSR state comes from the vmcs12 guest fields instead.
	 */
	vmwrite(VMCS_ENTRY_MSR_LOAD_COUNT, 0);
	vmwrite(VMCS_EXIT_MSR_LOAD_COUNT, 0);
	vmwrite(VMCS_EXIT_MSR_STORE_COUNT, 0);
	/*
	 * Do NOT acknowledge external interrupts on VM exit from L2: leave the
	 * host interrupt pending so vmx_run()'s enable_intr() delivers it
	 * through the normal host path (which EOIs it). If it were ACKed here,
	 * the vector would be consumed with nobody to EOI it and the local
	 * APIC would wedge.
	 */
	vmwrite(VMCS_EXIT_CTLS,
	    vmcs_read(VMCS_EXIT_CTLS) & ~(uint64_t)VM_EXIT_ACKNOWLEDGE_INTERRUPT);

	{
		uint64_t efer = 0, entry;
		vmcs12_read_field(v12, VMCS_GUEST_IA32_EFER, &efer);
		entry = vmcs_read(VMCS_ENTRY_CTLS);
		if (efer & EFER_LMA)
			entry |= VM_ENTRY_GUEST_LMA;
		else
			entry &= ~(uint64_t)VM_ENTRY_GUEST_LMA;
		vmwrite(VMCS_ENTRY_CTLS, entry);
	}
	vmwrite(VMCS_EPTP, ns->ept02_eptp);
	vmwrite(VMCS_LINK_POINTER, ~0UL);
	if (vmcs12_read_field(v12, VMCS_TSC_OFFSET, &val) == 0)
		vmwrite(VMCS_TSC_OFFSET, tsc01 + val);

	/* Event L1 queued for injection into L2, if any. */
	if (vmcs12_read_field(v12, VMCS_ENTRY_INTR_INFO, &val) == 0 &&
	    (val & VMCS_INTR_VALID) != 0) {
		vmwrite(VMCS_ENTRY_INTR_INFO, val);
		if (vmcs12_read_field(v12, VMCS_ENTRY_EXCEPTION_ERROR,
		    &val) == 0)
			vmwrite(VMCS_ENTRY_EXCEPTION_ERROR, val);
		if (vmcs12_read_field(v12, VMCS_ENTRY_INST_LENGTH, &val) == 0)
			vmwrite(VMCS_ENTRY_INST_LENGTH, val);
	} else {
		vmwrite(VMCS_ENTRY_INTR_INFO, 0);
	}

	ns->in_l2 = true;
	VMCLEAR(ns->vmcs02);		/* flush to memory; vmx_run() reloads it */
	ns->vmcs02_launched = false;
	return (0);
}

/*
 * Reflect an L2 exit to L1: copy L2 state into VMCS12, record the exit
 * information, and restore vmcs01 so L1 resumes and inspects the exit.
 * On return vmcs01 is the current VMCS.
 */
void
vmx_nested_reflect_l2_exit(struct vmx_vcpu *vcpu, uint32_t reason,
    uint64_t qual, uint64_t gpa)
{
	struct vmx_nested_state *ns;

	ns = vmx_nested_state(vcpu);

	/*
	 * vmcs02 is current: save L2 guest state into vmcs12. Then make vmcs01
	 * current with a single VMPTRLD -- this flushes vmcs02 to memory but
	 * leaves it LAUNCHED, and vmcs01 keeps its own launched state -- and
	 * write vmcs12's host-state area into the now-current vmcs01 with plain
	 * vmwrites (l1_vmcs_current makes the nested vmcs helpers skip their
	 * VMPTRLD/VMCLEAR, which would otherwise clear vmcs01's launch state
	 * and make vmx_run()'s next VMRESUME of L1 fail). Leave vmcs01 current
	 * and launched: vmx_run()'s loop reads GUEST_RIP (== HOST_RIP) from it
	 * and VMRESUMEs L1 at its VM-exit handler.
	 */
	vmx_nested_reflect_copy(vcpu, reason, qual, gpa);
	VMCLEAR(ns->vmcs02);		/* critical_exit balances the prologue's
					 * VMPTRLD(vmcs02); vmcs02's launch state
					 * is rebuilt by build_vmcs02 later. */
	VMPTRLD(vcpu->vmcs);		/* vmcs01 current, keeps its launched
					 * state; balanced by vmx_run's tail
					 * VMCLEAR(vmcs) (in_l2 is now false). */
	ns->l1_vmcs_current = true;	/* host-state writes go raw to the
					 * current vmcs01 (no VMCLEAR that would
					 * drop its launch state). */
	vmx_nested_vmexit_to_l1(vcpu, reason, qual);
	ns->l1_vmcs_current = false;
	VMX_CTR2(vcpu, "L2 exit reason %u reflected to L1 rip %#lx",
	    reason, (unsigned long)vmcs_read(VMCS_GUEST_RIP));
}

/*
 * Copy L2 guest state + exit information from the (current) vmcs02 into VMCS12.
 * Caller must have vmcs02 loaded; this touches no VMCS pointer or critical
 * section, so it is usable both from vmx_run() and from the deferred path.
 */
void
vmx_nested_reflect_copy(struct vmx_vcpu *vcpu, uint32_t reason, uint64_t qual,
    uint64_t gpa)
{
	struct vmcs12 *v12 = vcpu->nvmcs12;
	uint64_t val;
	unsigned i;

	for (i = 0; i < nitems(vmcs02_guest_fields); i++) {
		val = vmcs_read(vmcs02_guest_fields[i]);
		vmcs12_write_field(v12, vmcs02_guest_fields[i], val);
	}
	vmcs12_write_field(v12, VMCS_GUEST_CR0, vmcs_read(VMCS_CR0_SHADOW));
	vmcs12_write_field(v12, VMCS_GUEST_CR4, vmcs_read(VMCS_CR4_SHADOW));

	vmcs12_write_field(v12, VMCS_EXIT_REASON, reason);
	vmcs12_write_field(v12, VMCS_EXIT_QUALIFICATION, qual);
	vmcs12_write_field(v12, VMCS_GUEST_PHYSICAL_ADDRESS, gpa);
	vmcs12_write_field(v12, VMCS_EXIT_INTR_INFO,
	    vmcs_read(VMCS_EXIT_INTR_INFO));
	vmcs12_write_field(v12, VMCS_EXIT_INTR_ERRCODE,
	    vmcs_read(VMCS_EXIT_INTR_ERRCODE));
	vmcs12_write_field(v12, VMCS_EXIT_INSTRUCTION_LENGTH,
	    vmcs_read(VMCS_EXIT_INSTRUCTION_LENGTH));
	vmcs12_write_field(v12, VMCS_EXIT_INSTRUCTION_INFO,
	    vmcs_read(VMCS_EXIT_INSTRUCTION_INFO));
	vmcs12_write_field(v12, VMCS_GUEST_LINEAR_ADDRESS,
	    vmcs_read(VMCS_GUEST_LINEAR_ADDRESS));
}

/*
 * Decide what to do with an L2 exit taken on vmcs02 (current VMCS).
 * Returns 1 to resume L2, 0 to reflect to L1 (done here) and resume L1.
 */
int
vmx_nested_l2_exit(struct vmx_vcpu *vcpu, uint32_t reason,
    struct vm_exit *vmexit)
{
	uint64_t qual;

	qual = vmcs_read(VMCS_EXIT_QUALIFICATION);

	switch (reason) {
	case EXIT_REASON_EPT_FAULT:
		/*
		 * Walking EPT12 (vm_gpa_hold) and filling ept02 (pmap_enter)
		 * both take the pmap sleep lock, so neither may run in
		 * vmx_run()'s critical section. Defer the whole decision --
		 * translate, fill, or reflect -- to vm_run() via
		 * VM_EXITCODE_NESTED (see vmx_nested_op_l2_ept()).
		 */
		vmexit->exitcode = VM_EXITCODE_NESTED;
		vmexit->u.nested.op = VM_NESTED_OP_L2_EPT;
		vmexit->u.nested.info1 = vmcs_read(VMCS_GUEST_PHYSICAL_ADDRESS);
		vmexit->u.nested.info2 = qual;
		return (2);			/* leave vmx_run to defer */
	case EXIT_REASON_EXT_INTR:
		/*
		 * A host interrupt fired while L2 was running. build_vmcs02()
		 * clears "acknowledge interrupt on exit" from vmcs02, so the
		 * vector is left PENDING (not consumed): vmx_run()'s enable_intr()
		 * (already done before this call) delivers it through the normal
		 * host interrupt path, which EOIs it. Running the ISR by hand
		 * here instead (vmx_trigger_hostintr) corrupts the thread's
		 * critical-section state mid-exit. Nothing to do; resume L2.
		 */
	case EXIT_REASON_NMI_WINDOW:
	case EXIT_REASON_INTR_WINDOW:
		/* Nothing to do at L0; resume L2. */
		return (1);
	default:
		/* Everything else goes up to L1's hypervisor. */
		vmx_nested_reflect_l2_exit(vcpu, reason, qual, 0);
		return (0);
	}
}

/*
 * Deferred (vm_run context, no critical section): install one EPT02
 * mapping for a faulting L2 GPA, or reflect the fault to L1. Runs with
 * no VMCS current; loads vmcs02 for the reads it needs and leaves the
 * correct VMCS cleared for vmx_run() to reload.
 */
int
vmx_nested_op_l2_ept(struct vmx_vcpu *vcpu, uint64_t gpa, uint64_t qual)
{
	struct vmx_nested_state *ns = vmx_nested_state(vcpu);

	/*
	 * No VMCS is loaded on entry (vmx_run() cleared vmcs02 on the way out).
	 * The translate + fill in vmx_nested_ept02_fault() take the pmap sleep
	 * lock and so must run here, outside any critical section, with no VMCS
	 * loaded. If the L2 GPA is not mapped by L1's EPT (or cannot be
	 * backed), reflect the EPT violation up to L1 -- but reflect needs to
	 * read vmcs02 guest state, so briefly make vmcs02 current (VMPTRLD ..
	 * VMCLEAR balances the critical section) and do not leave any VMCS
	 * loaded; vmx_run()'s prologue reloads vmcs01 since in_l2 is cleared.
	 */
	{
		int r = vmx_nested_ept02_fault(vcpu, gpa, qual);
		if (r != 0) {
			/*
			 * Reflect the EPT violation to L1. Save L2 guest state
			 * into vmcs12 (needs vmcs02 current), then deliver the
			 * exit to L1 by loading vmcs12's host-state area into
			 * vmcs01 so L1 resumes at its VM-exit handler
			 * (HOST_RIP). vmx_nested_vmexit_to_l1() clears the
			 * guest-physical-address field, so re-stamp the faulting
			 * GPA afterwards for L1's EPT handler. It also clears
			 * in_l2.
			 */
			VMPTRLD(ns->vmcs02);
			vmx_nested_reflect_copy(vcpu, EXIT_REASON_EPT_FAULT,
			    qual, gpa);
			VMCLEAR(ns->vmcs02);
			vmx_nested_vmexit_to_l1(vcpu, EXIT_REASON_EPT_FAULT,
			    qual);
			vmcs12_write_field(vcpu->nvmcs12,
			    VMCS_GUEST_PHYSICAL_ADDRESS, gpa);
		}
	}
	return (0);
}
