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
 * This whole path is gated behind hw.vmm.nested.vmx_l2 (default on; a kill-switch);
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
#include <sys/sbuf.h>

#include <vm/vm.h>
#include <vm/vm_param.h>
#include <vm/pmap.h>
#include <vm/vm_page.h>

#include <machine/pmap.h>
#include <machine/specialreg.h>
#include <x86/clock.h>
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
int vmx_nested_l2_enable = 1;
SYSCTL_INT(_hw_vmm_nested, OID_AUTO, vmx_l2, CTLFLAG_RWTUN,
    &vmx_nested_l2_enable, 1,
    "Run nested VMX L2 guests for real on Intel (default on; set 0 to fall back "
    "to the synthetic entry-failure path). Still gated by hw.vmm.nested.enable "
    "and per-VM -N.");

/* --- diagnostic counters for the L2 interrupt-delivery investigation --- */
uint64_t vmx_l2_exit_hist[128];
uint64_t vmx_l2_entries;	/* build_vmcs02 calls (L2 (re-)entries) */
uint64_t vmx_l2_injects;	/* entries that carried a valid ENTRY_INTR_INFO */
uint64_t vmx_l2_injvec[256];	/* histogram of injected vectors */
uint64_t vmx_l2_swallow;	/* undelivered injections requeued via IDT-vectoring */
uint64_t vmx_l2_swallow_vec[256]; /* histogram of requeued (swallowed) vectors */
uint64_t vmx_l2_idtv_reinject;	/* in-flight L2 events recovered on L2 resume */
static int
vmx_l2_stats_sysctl(SYSCTL_HANDLER_ARGS)
{
	struct sbuf sb;
	int i, error;

	sbuf_new_for_sysctl(&sb, NULL, 512, req);
	sbuf_printf(&sb, "entries=%lu injects=%lu swallow=%lu idtv_reinject=%lu\n",
	    (unsigned long)vmx_l2_entries, (unsigned long)vmx_l2_injects,
	    (unsigned long)vmx_l2_swallow, (unsigned long)vmx_l2_idtv_reinject);
	for (i = 0; i < 128; i++)
		if (vmx_l2_exit_hist[i] != 0)
			sbuf_printf(&sb, "reason %d = %lu\n", i,
			    (unsigned long)vmx_l2_exit_hist[i]);
	for (i = 0; i < 256; i++)
		if (vmx_l2_injvec[i] != 0)
			sbuf_printf(&sb, "vec 0x%02x = %lu\n", i,
			    (unsigned long)vmx_l2_injvec[i]);
	for (i = 0; i < 256; i++)
		if (vmx_l2_swallow_vec[i] != 0)
			sbuf_printf(&sb, "swallow vec 0x%02x = %lu\n", i,
			    (unsigned long)vmx_l2_swallow_vec[i]);
	error = sbuf_finish(&sb);
	sbuf_delete(&sb);
	return (error);
}
SYSCTL_PROC(_hw_vmm_nested, OID_AUTO, l2stats,
    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_MPSAFE, NULL, 0,
    vmx_l2_stats_sysctl, "A", "L2 exit-reason histogram and inject counters");


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
	/*
	 * Local INVEPT only: this runs from build_vmcs02() right before L2 is
	 * (re-)entered on THIS CPU, and ept02 is a per-vcpu shadow. The all-CPU
	 * smp_rendezvous() of ept_invalidate_mappings() once per INVEPT was the
	 * flush storm that livelocked the host.
	 */
	{
		struct invept_desc desc = { .eptp = ns->ept02_eptp, ._res = 0 };
		invept(INVEPT_TYPE_SINGLE_CONTEXT, desc);
	}
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
if (ns->msr_bitmap02 != NULL)
		free(ns->msr_bitmap02, M_VMX_NESTED);
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
	int prot, error;

	ns = vmx_nested_state(vcpu);

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

	/*
	 * L1 GPA -> host page via L0's normal guest memory. Hold for READ|WRITE
	 * regardless of the faulting access type: ept02 maps the page RWX and L2
	 * may write it, so we must not be handed a shared copy-on-write zero page
	 * (which L2's writes would corrupt, and which several zero-filled L2 GPAs
	 * would alias). Requesting write makes L0 back the L1 GPA with a private,
	 * writable frame.
	 */
	mapping = vm_gpa_hold(vcpu->vcpu, l1_gpa & ~PAGE_MASK, PAGE_SIZE,
	    VM_PROT_READ | VM_PROT_WRITE, &cookie);
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
	uint64_t val, cr0, cr4, tsc01, v12ctls;
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
	if (ns->msr_bitmap02 == NULL) {
		ns->msr_bitmap02 = malloc_aligned(PAGE_SIZE, PAGE_SIZE,
		    M_VMX_NESTED, M_WAITOK | M_ZERO);
		ns->msr_bitmap02_pa = vtophys(ns->msr_bitmap02);
	}

	/*
	 * Snapshot vmcs01 host + control fields. This runs from vm_run()'s
	 * deferred nested-op path, where no VMCS is current (vmx_run()
	 * VMCLEARed vmcs01 on the way out), so make vmcs01 current before
	 * reading it -- otherwise vmcs_read() returns garbage and vmcs02 gets
	 * bogus control fields (VM entry fails with "invalid control field").
	 */
	VMPTRLD(vcpu->vmcs);
	{
		/*
		 * vmcs02 runs L2 with APICv OFF, but the MSR bitmap inherited
		 * from vmcs01 was built for L1 WITH APICv and therefore lets
		 * x2APIC MSR accesses pass through. Uncaught, L2's writes to its
		 * local-APIC timer (LVT/initial-count, MSRs 0x800-0x8ff) would
		 * hit L0's PHYSICAL LAPIC and destroy the host's timekeeping.
		 * Build a private vmcs02 bitmap: copy vmcs01's, then force the
		 * whole x2APIC range to intercept so those accesses exit and are
		 * reflected to L1 (which emulates L2's vlapic).
		 */
		uint64_t l1_bm = vmcs_read(VMCS_MSR_BITMAP);
		if (l1_bm != 0)
			memcpy(ns->msr_bitmap02,
			    (void *)PHYS_TO_DMAP(l1_bm), PAGE_SIZE);
		/* read-low bitmap base 0x000; write-low base 0x800; MSRs
		 * 0x800..0x8ff occupy bytes 0x100..0x11f of each. */
		memset(ns->msr_bitmap02 + 0x100, 0xff, 0x20);
		memset(ns->msr_bitmap02 + 0x900, 0xff, 0x20);
		/*
		 * IA32_TSC_DEADLINE (0x6e0): FreeBSD programs the local-APIC
		 * timer in TSC-deadline mode via this MSR, which is outside the
		 * x2APIC range. Intercept it too so L2 cannot arm L0's physical
		 * deadline timer. byte = 0x6e0>>3 = 0xdc, bit 0.
		 */
		ns->msr_bitmap02[0x0dc] |= 0x01;	/* read-low  */
		ns->msr_bitmap02[0x8dc] |= 0x01;	/* write-low */
	}
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
		ns->ept12_gen_flushed = ns->ept12_gen;
	} else if (ns->ept12_gen != ns->ept12_gen_flushed) {
		/*
		 * L1 executed INVEPT (changed EPT12) since our last flush. Drop
		 * the ept02 shadow so any remapped entry re-faults and
		 * re-composes against the current EPT12; a stale entry would
		 * make L2 read another page's contents. Coalesced to at most
		 * once per L2 (re-)entry by the generation counter.
		 */
		vmx_nested_ept02_flush(vcpu);
		ns->ept12_gen_flushed = ns->ept12_gen;
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
	val &= ~(uint64_t)PINBASED_POSTED_INTERRUPT;
	val |= PINBASED_PREMPTION_TIMER;	/* periodic yield to L1 */
	vmwrite(VMCS_PIN_BASED_CTLS, val);
	/*
	 * Force L2 to VM-exit periodically so L1's vcpu thread gets to run and
	 * advance L2's software-emulated devices (its vlapic timer) and inject
	 * L2's pending interrupts. Without this, once L2's memory is mapped it
	 * spins in a wait loop that never exits, L1 never runs, and the timer
	 * tick is never delivered (a nested device-emulation livelock).
	 * "save VMX-preemption timer value" is cleared so the field re-arms to
	 * the same value on every entry. Aim for roughly 1 ms.
	 */
	vmwrite(VMCS_EXIT_CTLS,
	    vmcs_read(VMCS_EXIT_CTLS) & ~(uint64_t)VM_EXIT_SAVE_PREEMPTION_TIMER);
	{
		uint64_t misc = rdmsr(0x485);	/* IA32_VMX_MISC */
		uint32_t shift = (uint32_t)(misc & 0x1f);
		uint64_t f = tsc_freq ? tsc_freq : 2600000000UL;
		uint32_t pt = (uint32_t)((f / 1000) >> shift);
		if (pt == 0)
			pt = 1;
		vmwrite(VMCS_PREEMPTION_TIMER_VALUE, pt);
	}

	val = vmcs_read(VMCS_PRI_PROC_BASED_CTLS);
	val &= ~(uint64_t)PROCBASED_USE_TPR_SHADOW;
	val |= PROCBASED_SECONDARY_CONTROLS;
	/*
	 * Propagate L1's interrupt/NMI-window-exiting request from VMCS12.
	 * L1 sets these when it has an event pending for L2 but L2 is not
	 * currently interruptible; without the bit the window exit never
	 * fires, l2_exit never reflects it to L1, and L1 never gets the
	 * chance to inject -- so L2 spins forever (on PAUSE) waiting for a
	 * timer/device interrupt that is never delivered.
	 */
	if (vmcs12_read_field(v12, VMCS_PRI_PROC_BASED_CTLS, &v12ctls) == 0)
		val |= v12ctls & (PROCBASED_INT_WINDOW_EXITING |
		    PROCBASED_NMI_WINDOW_EXITING);
	/*
	 * Do NOT make L2 exit on PAUSE. vmcs01 enables PAUSE-exiting for L1,
	 * but reflecting every L2 PAUSE to L1 turned a normal guest spin-wait
	 * into ~15k userspace round-trips/sec in L1. L2's spin loops belong
	 * in L2; they end when the interrupt they await is injected.
	 */
	val &= ~(uint64_t)PROCBASED_PAUSE_EXITING;
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
	vmwrite(VMCS_MSR_BITMAP, ns->msr_bitmap02_pa);
	vmwrite(VMCS_EPTP, ns->ept02_eptp);
	vmwrite(VMCS_LINK_POINTER, ~0UL);
	if (vmcs12_read_field(v12, VMCS_TSC_OFFSET, &val) == 0)
		vmwrite(VMCS_TSC_OFFSET, tsc01 + val);

	/* Event L1 queued for injection into L2, if any. */
	if (vmcs12_read_field(v12, VMCS_ENTRY_INTR_INFO, &val) == 0 &&
	    (val & VMCS_INTR_VALID) != 0) {
		vmx_l2_injects++;
		vmx_l2_injvec[val & 0xff]++;
		vmwrite(VMCS_ENTRY_INTR_INFO, val);
		if (vmcs12_read_field(v12, VMCS_ENTRY_EXCEPTION_ERROR,
		    &val) == 0)
			vmwrite(VMCS_ENTRY_EXCEPTION_ERROR, val);
		if (vmcs12_read_field(v12, VMCS_ENTRY_INST_LENGTH, &val) == 0)
			vmwrite(VMCS_ENTRY_INST_LENGTH, val);
	} else {
		vmwrite(VMCS_ENTRY_INTR_INFO, 0);
	}

	vmx_l2_entries++;
	ns->in_l2 = true;
	/*
	 * Mark this (L1) vcpu a nested host so vm_handle_hlt() bounds its idle
	 * sleep to hz/100 instead of hz. Without it, when L2 HLTs the L1 vcpu
	 * could sleep up to a full second before re-checking L2's pending
	 * interrupts, stalling an idle L2 under load (e.g. it freezes on a large
	 * cold disk read). Mirrors the AMD path (svm_nested_vmrun).
	 */
	vcpu_set_nested_host(vcpu->vcpu);
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
	/*
	 * vmcs01's HOST_GS_BASE/TR/GDTR are per-CPU and were last set for
	 * whichever CPU L1 previously ran on (vmx_set_pcpu_defaults is skipped
	 * on the in_l2 entry, so vcpu->state.lastcpu is stale). We are about to
	 * VMRESUME L1 on THIS CPU; if the vcpu migrated since L1 last ran, an
	 * L1 VM-exit would reload a stale GS base (another CPU's PCPU pointer)
	 * and corrupt the host scheduler. Refresh them for the running CPU --
	 * vmcs01 is current so raw vmcs_write() is correct here.
	 */
	vmcs_write(VMCS_HOST_TR_BASE, vmm_get_host_trbase());
	vmcs_write(VMCS_HOST_GDTR_BASE, vmm_get_host_gdtrbase());
	vmcs_write(VMCS_HOST_GS_BASE, vmm_get_host_gsbase());
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
	/*
	 * Save L2's EFFECTIVE CR0/CR4: host-owned (masked) bits come from the
	 * read shadow, guest-owned (unmasked) bits from the real guest register.
	 * Saving only the shadow dropped guest-owned bits L2 set itself (e.g.
	 * CR4.OSXSAVE); after a reflect+rebuild the real guest CR4 lost OSXSAVE
	 * and L2's XSETBV in fpuinit() then faulted with #UD.
	 */
	{
		uint64_t m0 = vmcs_read(VMCS_CR0_MASK);
		uint64_t m4 = vmcs_read(VMCS_CR4_MASK);
		vmcs12_write_field(v12, VMCS_GUEST_CR0,
		    (vmcs_read(VMCS_GUEST_CR0) & ~m0) |
		    (vmcs_read(VMCS_CR0_SHADOW) & m0));
		vmcs12_write_field(v12, VMCS_GUEST_CR4,
		    (vmcs_read(VMCS_GUEST_CR4) & ~m4) |
		    (vmcs_read(VMCS_CR4_SHADOW) & m4));
	}

	/*
	 * Reflect the VM-entry interruption-information back to L1. When L1
	 * queued an event for L2, build_vmcs02() copied it into vmcs02 and the
	 * CPU delivered it and cleared the valid bit on VM entry. L1 must see
	 * that its injection was consumed; otherwise it keeps the field set and
	 * re-injects on the next VMRESUME -- and if L2 has since disabled
	 * interrupts (RFLAGS.IF=0), re-injecting an external interrupt makes the
	 * next VM entry fail with "invalid guest state".
	 */
	/*
 	 * Reflect any in-flight event through vmcs12's IDT-vectoring-information
 	 * field -- the field stock L1 (vmx_exit_process) reads to requeue an
 	 * event that was mid-delivery at the exit, via vm_exit_intinfo(), which
 	 * re-injects WITHOUT re-running its vlapic IRR->ISR arbitration.
 	 *
 	 * Case 1 (genuine): a real vmcs02 exit occurred during delivery and
 	 * hardware set VMCS_IDT_VECTORING_INFO; propagate it verbatim.
 	 *
 	 * Case 2 (swallowed injection -- the Intel analog of the AMD eventinj
 	 * drop): L1 queued an event into vmcs12 ENTRY_INTR_INFO, build_vmcs02()
 	 * composed it into vmcs02 ENTRY_INTR_INFO, but this exit was synthesized
 	 * by L0 (HLT/preempt/interrupt-window reflect) so the CPU never ran a
 	 * VMRESUME to deliver it: the entry-info VALID bit is STILL set and the
 	 * hardware IDT-vectoring info is NOT valid. Hardware clears entry-info on
 	 * delivery, so a still-valid field at reflect time means the vector was
 	 * dropped -- and L1's vlapic already moved it IRR->ISR at queue time, so
 	 * silently losing it wedges the vector in-service forever (PPR raised,
 	 * every later same/lower-priority interrupt blocked: the guest hangs at
 	 * mount-root). The entry-interruption and IDT-vectoring formats share a
 	 * bit layout, so copy the undelivered entry-info into vmcs12
 	 * IDT_VECTORING_INFO and mark vmcs12 ENTRY_INTR_INFO consumed (0). L1
 	 * then requeues the vector through its stock exit-during-delivery path
 	 * (single injection, no second IRR->ISR). Leaving BOTH fields valid
 	 * would trip L1's "cannot inject while another is being delivered"
 	 * assertion.
 	 */
	{
		uint32_t idtv = (uint32_t)vmcs_read(VMCS_IDT_VECTORING_INFO);
		uint32_t einfo = (uint32_t)vmcs_read(VMCS_ENTRY_INTR_INFO);

		if ((idtv & VMCS_IDT_VEC_VALID) == 0 &&
		    (einfo & VMCS_INTR_VALID) != 0) {
			vmx_l2_swallow++;
			vmx_l2_swallow_vec[einfo & 0xff]++;
			vmcs12_write_field(v12, VMCS_IDT_VECTORING_INFO, einfo);
			vmcs12_write_field(v12, VMCS_IDT_VECTORING_ERROR,
			    vmcs_read(VMCS_ENTRY_EXCEPTION_ERROR));
			vmcs12_write_field(v12, VMCS_ENTRY_INTR_INFO, 0);
		} else {
			vmcs12_write_field(v12, VMCS_IDT_VECTORING_INFO, idtv);
			vmcs12_write_field(v12, VMCS_IDT_VECTORING_ERROR,
			    vmcs_read(VMCS_IDT_VECTORING_ERROR));
			vmcs12_write_field(v12, VMCS_ENTRY_INTR_INFO, einfo);
		}
	}

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
 * An L2 VM-exit that L0 handles and then RESUMES (rather than reflecting to L1)
 * may have interrupted an in-progress event delivery. In that case hardware
 * records the event in VMCS_IDT_VECTORING_INFO and has already cleared
 * VMCS_ENTRY_INTR_INFO. If we resume L2 without action the event is silently
 * dropped -- and for a maskable interrupt that is fatal: L1's vlapic moved the
 * vector IRR->ISR when it queued it (raising PPR), but L2 never ran the handler
 * and so never issues the EOI. The vector stays in-service forever, PPR stays
 * raised, and every later same-or-lower-priority interrupt (notably the LAPIC
 * timer, vector 0xef) is blocked: L2 wedges in a HLT idle-wait that never wakes.
 *
 * Re-inject the interrupted event through VMCS_ENTRY_INTR_INFO so delivery
 * completes on the next VM entry -- exactly what vmx_exit_process() does for a
 * non-nested guest via vm_exit_intinfo()/vm_entry_intinfo(). vmcs02 must be the
 * current VMCS. Intel nested-only; no effect on the non-nested or AMD paths.
 */
static void
vmx_nested_carry_idtv(struct vmx_vcpu *vcpu)
{
	uint32_t idtv, entry;

	idtv = (uint32_t)vmcs_read(VMCS_IDT_VECTORING_INFO);
	if ((idtv & VMCS_IDT_VEC_VALID) == 0)
		return;
	entry = (uint32_t)vmcs_read(VMCS_ENTRY_INTR_INFO);
	if ((entry & VMCS_INTR_VALID) != 0)
		return;			/* an event is already queued for entry */
	idtv &= ~(1U << 12);		/* clear the reserved/undefined bit */
	vmwrite(VMCS_ENTRY_INTR_INFO, idtv);
	if (idtv & VMCS_IDT_VEC_ERRCODE_VALID)
		vmwrite(VMCS_ENTRY_EXCEPTION_ERROR,
		    vmcs_read(VMCS_IDT_VECTORING_ERROR));
	if ((idtv & VMCS_INTR_T_MASK) == VMCS_INTR_T_SWINTR)
		vmwrite(VMCS_ENTRY_INST_LENGTH, vmexit_instruction_length());
	vmx_l2_idtv_reinject++;
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
	vmx_l2_exit_hist[reason & 0x7f]++;

	switch (reason) {
	case EXIT_REASON_HLT:
		/*
		 * L2 halted with interrupts enabled, waiting for its next
		 * interrupt (timer tick or virtio completion). Reflect a REAL
		 * HLT to L1 so L1's stock vm_handle_hlt() sleeps its vcpu
		 * thread. That releases L1's physical CPU to the inner bhyve's
		 * device-backend / mevent threads, which is what actually
		 * completes the awaited I/O and posts the completion to L2's
		 * vlapic; that post calls vcpu_notify_event(), waking L1's vcpu
		 * to VMRESUME L2 with the injection.
		 *
		 * The earlier spurious-EXT_INTR reflect kept L1's vcpu thread
		 * spinning in vm_run() (~20k reflects/s), starving those I/O
		 * threads on a 1-CPU L1 so device completions never posted and
		 * L2 wedged waiting (mount-root / shell input). reflect_copy
		 * carries GUEST_RIP (the HLT) and inst_length so L1 advances
		 * past HLT normally.
		 */
		vmx_nested_reflect_l2_exit(vcpu, EXIT_REASON_HLT, qual, 0);
		return (0);
	case EXIT_REASON_VMX_PREEMPT:
		/*
		 * L0's periodic yield fired. Give L1 a turn: reflect a spurious
		 * external interrupt (invalid VMCS_EXIT_INTR_INFO), which L1
		 * handles by injecting any pending L2 interrupts (its vlapic
		 * timer tick) and resuming L2.
		 */
		vmx_nested_reflect_l2_exit(vcpu, EXIT_REASON_EXT_INTR, 0, 0);
		return (0);
	case EXIT_REASON_EPT_FAULT:
		/*
		 * Walking EPT12 (vm_gpa_hold) and filling ept02 (pmap_enter)
		 * both take the pmap sleep lock, so neither may run in
		 * vmx_run()'s critical section. Defer the whole decision --
		 * translate, fill, or reflect -- to vm_run() via
		 * VM_EXITCODE_NESTED (see vmx_nested_op_l2_ept()).
		 */
		vmexit->exitcode = VM_EXITCODE_NESTED;
		/*
		 * An EPT violation is re-executed after the fault is fixed, not
		 * skipped, so the faulting instruction must not be advanced.
		 * vmx_run()'s exit-collection already stamped inst_length with
		 * the faulting instruction's length; clear it, because
		 * vm_handle_nested() KASSERTs inst_length == 0 -- otherwise any
		 * L2 taking an EPT fault panics L0 (an L2->L0 DoS).
		 */
		vmexit->inst_length = 0;
		vmexit->u.nested.op = VM_NESTED_OP_L2_EPT;
		vmexit->u.nested.info1 = vmcs_read(VMCS_GUEST_PHYSICAL_ADDRESS);
		vmexit->u.nested.info2 = qual;
		return (2);			/* leave vmx_run to defer */
	case EXIT_REASON_EXT_INTR: {
		uint32_t intr_info;

		/*
		 * A host interrupt fired while L2 was running. vmcs02 inherits
		 * bhyve's "acknowledge interrupt on exit", so the CPU has
		 * already ACKed the vector into VMCS_EXIT_INTR_INFO -- it is NOT
		 * left pending, so enable_intr() alone will NOT run the host
		 * ISR. Dispatch it to the host handler exactly as
		 * vmx_exit_process() does for L1; otherwise the vector is never
		 * EOIed, the CPU's local APIC wedges, and the next all-CPU
		 * smp_rendezvous()/TLB shootdown deadlocks the whole host.
		 * Then resume L2.
		 */
		intr_info = vmcs_read(VMCS_EXIT_INTR_INFO);
		if ((intr_info & VMCS_INTR_VALID) != 0 &&
		    (intr_info & VMCS_INTR_T_MASK) == VMCS_INTR_T_HWINTR)
			vmx_trigger_hostintr(intr_info & 0xff);
		vmx_nested_carry_idtv(vcpu);	/* preserve in-flight L2 event */
		return (1);
	}
	case EXIT_REASON_NMI_WINDOW:
	case EXIT_REASON_INTR_WINDOW:
		/*
		 * L2 became interruptible and vmcs02 carried the window-exiting
		 * control L1 requested (propagated from VMCS12 in
		 * build_vmcs02). Reflect the window exit to L1 so its
		 * hypervisor clears the control and injects the pending event
		 * through VMCS12 ENTRY_INTR_INFO on the next entry. Handling it
		 * at L0 (return 1) would swallow the one signal L1 uses to
		 * inject, which is why L2 never received interrupts.
		 */
		vmx_nested_reflect_l2_exit(vcpu, reason, qual, 0);
		return (0);
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
		} else {
			/*
			 * Fault fixed: resume L2. If the faulting access happened
			 * while L2 was delivering an event, hardware left it in
			 * VMCS_IDT_VECTORING_INFO and cleared ENTRY_INTR_INFO;
			 * re-inject it so delivery completes (see
			 * vmx_nested_carry_idtv), else the vector's in-service bit
			 * in L1's vlapic never clears and L2 wedges.
			 */
			VMPTRLD(ns->vmcs02);
			vmx_nested_carry_idtv(vcpu);
			VMCLEAR(ns->vmcs02);
		}
	}
	return (0);
}
