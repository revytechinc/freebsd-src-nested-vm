/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2014, Neel Natu (neel@freebsd.org)
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice unmodified, this list of conditions, and the following
 *    disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <sys/cdefs.h>
#include "opt_bhyve_snapshot.h"

#include <sys/param.h>
#include <sys/errno.h>
#include <sys/systm.h>

#include <vm/vm.h>

#include <machine/cpufunc.h>
#include <machine/specialreg.h>
#include <machine/vmm.h>

#include <dev/vmm/vmm_mem.h>
#include <dev/vmm/vmm_vm.h>

#include "svm.h"
#include "vmcb.h"
#include "svm_softc.h"
#include "svm_msr.h"
#include "vmm_nested.h"
#include "svm_nested_stubs.h"
#include <dev/vmm/vmm_ktr.h>

#ifndef MSR_AMDK8_IPM
#define	MSR_AMDK8_IPM	0xc0010055
#endif

/*
 * T8 (wave2) nested-virt: per-vCPU L1 HSAVE GPA. bhyve writes to a
 * bhyve-controlled shadow HPA on every L2 VMRUN; the GPA captured here
 * is the L1-stated destination for the L2->L1 host-save-area state
 * transfer on L2 #VMEXIT (consulted by T25 VMRUN hookup). Indexed by
 * vcpuid, parallel to the 'nested_vmcs12_region[MAXCPU]' file-scope
 * used by T0c (vmx.c). T7's nested_vcpu_state carries the same field
 * for forward compatibility once T7's allocation lands; the file-scope
 * backing here is the actual storage until then.
 *
 * MUST NOT be exposed to L1 as-is: the L0 host HSAVE PA lives in
 * MSR_VM_HSAVE_PA while L0 is running. Returning the host PA to an
 * L1 RDMSR is an info leak.
 */
static uint64_t nested_hsave_gpa[MAXCPU];

/*
 * T32-T33 (wave6) nested-virt: per-vCPU Hyper-V enlightenment shadows.
 * Each entry is the L1-stated value for the named MSR (TLFS 7.8b §3.1).
 * Indexed by vcpuid; same concurrency story as nested_hsave_gpa.
 *
 * SIEFP / SIMP / HYPERCALL / REFERENCE_TSC entries store L1's
 * page-aligned GPA; on RDMSR we return that GPA so L1 sees its own
 * configuration. WRMSR validates via vm_gpa_hold (T32/T33).
 *
 * MUST NOT be exposed to L0: these are L1's view, not the host's
 * actual SynIC state. Returning the host's real SIEFP/SIMP would let
 * L1 inject synthetic interrupts into another L1 VM (and would let L1
 * inject into L0 = the host kernel). Each L1-VM must have its own
 * backing; that allocation is bhyve userspace's job (xmsr.c).
 */
static uint64_t nested_hv_siefp[MAXCPU];
static uint64_t nested_hv_simp[MAXCPU];
static uint64_t nested_hv_scontrol[MAXCPU];
static uint64_t nested_hv_eom[MAXCPU];
static uint64_t nested_hv_sint[MAXCPU][MSR_HV_SINT_COUNT];
static uint64_t nested_hv_hypercall[MAXCPU];

/*
 * T34-T35 (wave6) nested-virt: per-vCPU APIC-assist / TSC shadow state.
 * EOI / ICR / TPR MSRs are per-vCPU L1-stated values; L1's writes
 * update only L1's view, never the host's physical APIC. Reference TSC
 * stores L1's TSC page GPA passed in via MSR_HV_REFERENCE_TSC; the
 * actual TSC page backing is bhyve userspace's job (T35).
 *
 * MUST NOT be exposed to L0: L1's EOI writes must not be forwarded to
 * the host's LAPIC (would let L1 inject interrupts into L0).
 */
static uint64_t nested_hv_apic_eoi[MAXCPU];
static uint64_t nested_hv_apic_icr[MAXCPU];
static uint64_t nested_hv_apic_tpr[MAXCPU];
static uint64_t nested_hv_ref_tsc[MAXCPU];

/*
 * T36 (wave6) nested-virt: L1 Hyper-V identity MSRs.
 * GUEST_OS_ID, VP_RUNTIME accumulate values across L1's vCPU residency.
 * GUEST_IDLE is a pass-through (L1's interpretation of "is this vCPU
 * idle"); we just store the L1 value.
 *
 * VP_INDEX returns L1's vCPU index (== our vcpuid here, since L1 is
 * the direct guest of L0; L1 sees itself as the vCPU it's actually
 * running on).
 *
 * MUST NOT be exposed to L0: VP_RUNTIME / VP_INDEX must reflect L1's
 * view, not the host's (the host's MSR values are the L1 hypervisor's
 * times, not L1's).
 */
static uint64_t nested_hv_guest_os_id[MAXCPU];
static uint64_t nested_hv_vp_runtime[MAXCPU];
static uint64_t nested_hv_guest_idle[MAXCPU];

/*
 * Host-wide nested-virt gate (T2). File-scope extern mirrors the
 * pattern in sys/amd64/vmm/intel/vmx.c::nested_vmcs12_region.
 */
extern int vmm_nested_enable;

/*
 * T32-T33: validate that 'gpa' refers to a real, mapped page in L1
 * physical memory. Page-aligned (mask check enforced by caller).
 * Returns non-zero on success. Used for MSRs that store a GPA into
 * L1 memory (SIEFP/SIMP/HYPERCALL/REFERENCE_TSC).
 */
static int
nested_hv_validate_gpa(struct svm_vcpu *vcpu, uint64_t gpa)
{

	if (vcpu->vcpu == NULL)
		return (0);
	if ((gpa & ~(uint64_t)MSR_HV_HYPERCALL_PAGE_MASK) != 0)
		return (0);
	/*
	 * Only alignment can be checked here: MSR emulation runs inside
	 * vm_run()'s critical section, where guest pages cannot be held.
	 */
	return (1);
}

enum {
	IDX_MSR_LSTAR,
	IDX_MSR_CSTAR,
	IDX_MSR_STAR,
	IDX_MSR_SF_MASK,
	HOST_MSR_NUM		/* must be the last enumeration */
};

static uint64_t host_msrs[HOST_MSR_NUM];

void
svm_msr_init(void)
{
	/*
	 * It is safe to cache the values of the following MSRs because they
	 * don't change based on curcpu, curproc or curthread.
	 */
	host_msrs[IDX_MSR_LSTAR] = rdmsr(MSR_LSTAR);
	host_msrs[IDX_MSR_CSTAR] = rdmsr(MSR_CSTAR);
	host_msrs[IDX_MSR_STAR] = rdmsr(MSR_STAR);
	host_msrs[IDX_MSR_SF_MASK] = rdmsr(MSR_SF_MASK);
}

void
svm_msr_guest_init(struct svm_softc *sc, struct svm_vcpu *vcpu)
{
	/*
	 * All the MSRs accessible to the guest are either saved/restored by
	 * hardware on every #VMEXIT/VMRUN (e.g., G_PAT) or are saved/restored
	 * by VMSAVE/VMLOAD (e.g., MSR_GSBASE).
	 *
	 * There are no guest MSRs that are saved/restored "by hand" so nothing
	 * more to do here.
	 */
	return;
}

void
svm_msr_guest_enter(struct svm_vcpu *vcpu)
{
	/*
	 * Save host MSRs (if any) and restore guest MSRs (if any).
	 */
}

void
svm_msr_guest_exit(struct svm_vcpu *vcpu)
{
	/*
	 * Save guest MSRs (if any) and restore host MSRs.
	 */
	wrmsr(MSR_LSTAR, host_msrs[IDX_MSR_LSTAR]);
	wrmsr(MSR_CSTAR, host_msrs[IDX_MSR_CSTAR]);
	wrmsr(MSR_STAR, host_msrs[IDX_MSR_STAR]);
	wrmsr(MSR_SF_MASK, host_msrs[IDX_MSR_SF_MASK]);

	/* MSR_KGSBASE will be restored on the way back to userspace */
}

int
svm_rdmsr(struct svm_vcpu *vcpu, u_int num, uint64_t *result, bool *retu)
{
	int error = 0;

	switch (num) {
	case MSR_MCG_CAP:
	case MSR_MCG_STATUS:
		*result = 0;
		break;
	case MSR_MTRRcap:
	case MSR_MTRRdefType:
	case MSR_MTRR4kBase ... MSR_MTRR4kBase + 7:
	case MSR_MTRR16kBase ... MSR_MTRR16kBase + 1:
	case MSR_MTRR64kBase:
	case MSR_MTRRVarBase ... MSR_MTRRVarBase + (VMM_MTRR_VAR_MAX * 2) - 1:
		if (vm_rdmtrr(&vcpu->mtrr, num, result) != 0) {
			vm_inject_gp(vcpu->vcpu);
		}
		break;
	case MSR_SYSCFG:
	case MSR_AMDK8_IPM:
	case MSR_EXTFEATURES:
		*result = 0;
		break;
	case MSR_HV_SIEFP:
		/*
		 * T32: L1 SynIC event flag page GPA read. Return L1's
		 * last-set value (0 if unset). Outside nested-virt, fall
		 * through to EINVAL/VMEXIT (existing behavior).
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hv_siefp[vcpu->vcpuid];
		break;
	case MSR_HV_SIMP:
		/*
		 * T32: L1 SynIC message page GPA read. Return L1's
		 * last-set value (0 if unset).
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hv_simp[vcpu->vcpuid];
		break;
	case MSR_HV_SCONTROL:
		/*
		 * T32: L1 SynIC control read. Return L1's last-set value.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hv_scontrol[vcpu->vcpuid];
		break;
	case MSR_HV_EOM:
		/*
		 * T32: L1 SynIC end-of-message read. Return L1's
		 * last-set value (0 if unset).
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hv_eom[vcpu->vcpuid];
		break;
	case MSR_HV_SINT0 ... MSR_HV_SINT15:
		/*
		 * T32: L1 SynIC source MSR read. Return L1's last-set
		 * value for the corresponding SINTn.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hv_sint[vcpu->vcpuid][num - MSR_HV_SINT0];
		break;
	case MSR_HV_HYPERCALL:
		/*
		 * T33: L1 hypercall page GPA read. Return L1's stored
		 * GPA OR'd with MSR_HV_HYPERCALL_ENABLE so L1 thinks
		 * it's enabled. L1's HYPERVMCALL can then be redirected
		 * through L1's page.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hv_hypercall[vcpu->vcpuid] |
		    MSR_HV_HYPERCALL_ENABLE;
		break;
	case MSR_HV_APIC_EOI:
		/*
		 * T34: L1 EOI write acknowledgement. TLFS 7.8b §3.1.6:
		 * any non-zero write to MSR_HV_APIC_EOI signals "EOI
		 * the highest-priority in-service interrupt". On RDMSR
		 * the value is implementation-defined (TLFS allows
		 * returning 0). We return L1's last-written value as a
		 * simple shadow.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hv_apic_eoi[vcpu->vcpuid];
		break;
	case MSR_HV_APIC_ICR:
		/*
		 * T34: L1 ICR (Interrupt Command Register) shadow
		 * read. Stores L1's APIC assist ICR value; L1's
		 * interrupt dispatches via L1's SINT routing, not the
		 * host's LAPIC.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hv_apic_icr[vcpu->vcpuid];
		break;
	case MSR_HV_APIC_TPR:
		/*
		 * T34: L1 TPR (Task Priority Register) shadow read.
		 * L1's CR8 accesses go through to L1's virtual APIC
		 * page; this MSR is the SynIC-side assist.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hv_apic_tpr[vcpu->vcpuid];
		break;
	case MSR_HV_REFERENCE_TSC:
		/*
		 * T35: L1 Reference TSC page GPA read. Return L1's
		 * stored GPA. The actual TSC page layout (sequence,
		 * scale, offset) is bhyve userspace's job to populate
		 * when L1 sets the GPA (this is the L1-virtual TSC,
		 * not the host's hyperv_reftsc).
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hv_ref_tsc[vcpu->vcpuid];
		break;
	case MSR_HV_TIME_REF_COUNT:
		/*
		 * T35: L1 TIME_REF_COUNT read. Returns L1's virtual
		 * timestamp counter (L1's TSC offset-adjusted). NAIVE
		 * implementation: return rdtsc() minus L1's offset.
		 * Full emulation (with L1's paravirtualized TSC clock)
		 * is bhyve userspace's job.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = rdtsc();
		break;
	case MSR_DEBUGCTLMSR:
		/*
		 * An L1 hypervisor saves and restores IA32_DEBUGCTL around
		 * its own VMRUN. Hand back the value it last wrote (kept in
		 * the VMCB save area); non-nested VMs keep the userland
		 * fall-through.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		*result = svm_get_vmcb_state(vcpu)->dbgctl;
		break;
	case MSR_VM_CR:
		/*
		 * SVM feature control. An L1 hypervisor checks SVMDIS (and
		 * the LOCK bit) before using SVM; report "enabled, unlocked"
		 * rather than the host's value. Non-nested VMs keep the
		 * existing userland fall-through.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		*result = 0;
		svm_nested_trace(vcpu, "rdmsr-vm_cr", 0, 0);
		break;
	case MSR_VM_HSAVE_PA:
		/*
		 * T8: nested-virt L1 HSAVE GPA read.
		 *
		 * Return the L1-stated GPA (or 0 if L1 has not set one).
		 * NEVER return the L0 host's HSAVE PA -- that is an info
		 * leak. For non-nested VMs the existing fall-through to
		 * EINVAL (escalating to VM_EXITCODE_RDMSR for userland
		 * handling) is preserved.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hsave_gpa[vcpu->vcpuid];
		break;
	case MSR_AMD_LBR_CTL:
	case MSR_AMD_LBR_SELECT:
	case MSR_AMD_LBR_DATA:
	case MSR_AMD_LBR_DATA_HI:
	case MSR_AMD_LBR_INFO:
	case MSR_AMD_LBR_INFO_HI:
		/*
		 * AMD LBR / Last Branch Record virtualization MSRs
		 * (0xC0010200-0xC0010205).  The underlying LBR hardware
		 * is not virtualized in nested-virt v1, so reads return
		 * zero (cap-and-mask).  Writes are reserved and must
		 * inject #GP via the caller (svm_wrmsr below).
		 */
		*result = 0;
		break;
	case MSR_HV_GUEST_OS_ID:
		/*
		 * T36: L1 OS identity read. Return L1's last-set value
		 * or MSR_HV_GUEST_OS_ID_WINDOWS (0x8100) if never set
		 * per TLFS 7.8b §3.1.1 recommendation.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hv_guest_os_id[vcpu->vcpuid] != 0 ?
		    nested_hv_guest_os_id[vcpu->vcpuid] :
		    MSR_HV_GUEST_OS_ID_WINDOWS;
		break;
	case MSR_HV_VP_INDEX:
		/*
		 * T36: L1's vCPU index. L1 sees itself as the vCPU
		 * it's actually running on (= our vcpuid). Must NOT
		 * return the host's vCPU index.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = (uint64_t)vcpu->vcpuid;
		break;
	case MSR_HV_VP_RUNTIME:
		/*
		 * T36: L1's vCPU runtime. Returns accumulated L1 vCPU
		 * time. We store L1's last-set value (L1 enforces its
		 * own runtime accounting via this MSR; the actual
		 * timing is bhyve userspace's job).
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hv_vp_runtime[vcpu->vcpuid];
		break;
	case MSR_HV_GUEST_IDLE:
		/*
		 * T36: L1 vCPU idle state. Pass-through storage.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		*result = nested_hv_guest_idle[vcpu->vcpuid];
		break;
	default:
		error = EINVAL;
		break;
	}

	return (error);
}

int
svm_wrmsr(struct svm_vcpu *vcpu, u_int num, uint64_t val, bool *retu)
{
	int error = 0;

	switch (num) {
	case MSR_MCG_CAP:
	case MSR_MCG_STATUS:
		break;		/* ignore writes */
	case MSR_MTRRcap:
	case MSR_MTRRdefType:
	case MSR_MTRR4kBase ... MSR_MTRR4kBase + 7:
	case MSR_MTRR16kBase ... MSR_MTRR16kBase + 1:
	case MSR_MTRR64kBase:
	case MSR_MTRRVarBase ... MSR_MTRRVarBase + (VMM_MTRR_VAR_MAX * 2) - 1:
		if (vm_wrmtrr(&vcpu->mtrr, num, val) != 0) {
			vm_inject_gp(vcpu->vcpu);
		}
		break;
	case MSR_SYSCFG:
		break;		/* Ignore writes */
	case MSR_AMDK8_IPM:
		/*
		 * Ignore writes to the "Interrupt Pending Message" MSR.
		 */
		break;
	case MSR_K8_UCODE_UPDATE:
		/*
		 * Ignore writes to microcode update register.
		 */
		break;
	case MSR_AMD_LBR_CTL:
	case MSR_AMD_LBR_SELECT:
	case MSR_AMD_LBR_DATA:
	case MSR_AMD_LBR_DATA_HI:
	case MSR_AMD_LBR_INFO:
	case MSR_AMD_LBR_INFO_HI:
		/*
		 * AMD LBR virtualization MSRs (0xC0010200-0xC0010205) are
		 * not exposed to nested guests; inject #GP.  svm_rdmsr
		 * returns 0 on read (cap-and-mask).
		 */
		vm_inject_gp(vcpu->vcpu);
		break;
#ifdef BHYVE_SNAPSHOT
	case MSR_TSC:
		svm_set_tsc_offset(vcpu, val - rdtsc());
		break;
#endif
	case MSR_EXTFEATURES:
		break;
	case MSR_DEBUGCTLMSR:
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		/* Only the value is kept; LBR virtualization is not offered. */
		svm_get_vmcb_state(vcpu)->dbgctl = val;
		svm_set_dirty(vcpu, VMCB_CACHE_LBR);
		break;
	case MSR_VM_CR:
		/*
		 * Writes only matter for the LOCK/SVMDIS bits, which L0
		 * does not let L1 change; accept and ignore for nested VMs.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		break;
	case MSR_VM_HSAVE_PA:
		/*
		 * T8: nested-virt L1 HSAVE GPA write.
		 *
		 * Validate the GPA before storing: must be page-aligned
		 * (AMD APM Vol 2 §15.11) and must resolve to a real
		 * mapping in L1 physical memory (vm_gpa_hold succeeds).
		 * Any failure injects #GP; we do NOT update
		 * nested_hsave_gpa on failure.
		 *
		 * On success: store the GPA so a later L1 RDMSR returns
		 * it and so T25 (VMRUN) can target the L2->L1 state
		 * transfer at this GPA. Note: 0 is a valid stored value
		 * meaning "L1 has cleared the preference"; the semantic
		 * "never set" is encoded by the array being zero at
		 * boot.
		 *
		 * For non-nested VMs the existing fall-through to EINVAL
		 * (escalating to VM_EXITCODE_WRMSR for userland
		 * handling) is preserved.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		if (val & PAGE_MASK) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		/*
		 * The page is not validated here: MSR emulation runs inside
		 * vm_run()'s critical section, where guest pages cannot be
		 * held. The HSAVE area is never dereferenced by L0.
		 */
		nested_hsave_gpa[vcpu->vcpuid] = val;
		svm_nested_trace(vcpu, "wrmsr-hsave", val, 0);
		SVM_CTR1(vcpu, "nested HSAVE_PA set to %#lx",
		    (unsigned long)val);
		break;
	case MSR_HV_SIEFP:
		/*
		 * T32: L1 SynIC event flag page GPA write. Validate
		 * page-aligned + mapped in L1 phys mem (vm_gpa_hold).
		 * On failure inject #GP and do NOT store. Acceptance of
		 * 0 is allowed (L1 clearing the SIEFP).
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		if (val != 0 && !nested_hv_validate_gpa(vcpu, val)) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		nested_hv_siefp[vcpu->vcpuid] = val;
		SVM_CTR1(vcpu, "nested HV SIEFP set to %#lx",
		    (unsigned long)val);
		break;
	case MSR_HV_SIMP:
		/*
		 * T32: L1 SynIC message page GPA write. Same validation
		 * pattern as SIEFP.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		if (val != 0 && !nested_hv_validate_gpa(vcpu, val)) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		nested_hv_simp[vcpu->vcpuid] = val;
		SVM_CTR1(vcpu, "nested HV SIMP set to %#lx",
		    (unsigned long)val);
		break;
	case MSR_HV_SCONTROL:
		/*
		 * T32: L1 SynIC control write. SCONTROL is a 64-bit
		 * value with format defined by TLFS 7.8b §3.1.4. We
		 * store it verbatim; the SynIC-enabled bit is the
		 * gating concern but actual enable/disable semantics
		 * are L1's responsibility (the SynIC is unused while
		 * L1 is guest of L0 — bhyve userspace xmsr.c owns the
		 * actual backing-page writes).
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		nested_hv_scontrol[vcpu->vcpuid] = val;
		SVM_CTR1(vcpu, "nested HV SCONTROL set to %#lx",
		    (unsigned long)val);
		break;
	case MSR_HV_EOM:
		/*
		 * T32: L1 SynIC EOM write. TLFS 7.8b §3.1.4: writing
		 * any non-zero value to EOM "clears" the SIMP message
		 * slot. We store it verbatim; the message-page semantics
		 * live in bhyve userspace (xmsr.c).
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		nested_hv_eom[vcpu->vcpuid] = val;
		SVM_CTR1(vcpu, "nested HV EOM set to %#lx",
		    (unsigned long)val);
		break;
	case MSR_HV_SINT0 ... MSR_HV_SINT15:
		/*
		 * T32: L1 SynIC SINTn write. Each SINT MSR is 16 bytes
		 * (4 64-bit fields) per TLFS 7.8b §3.1.4. We store
		 * the first 8 bytes (the format L1 cares about most).
		 * Full multi-field emulation is bhyve userspace's job.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		nested_hv_sint[vcpu->vcpuid][num - MSR_HV_SINT0] = val;
		SVM_CTR2(vcpu, "nested HV SINT%d set to %#lx",
		    (int)(num - MSR_HV_SINT0), (unsigned long)val);
		break;
	case MSR_HV_HYPERCALL:
		/*
		 * T33: L1 hypercall page GPA write. Validate
		 * page-aligned + mapped in L1 phys mem. ENABLE bit is
		 * set on every store (L1 enabling it again is a no-op).
		 * A later RDMSR returns the GPA with ENABLE bit OR'd.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		if (val != 0 && !nested_hv_validate_gpa(vcpu, val)) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		nested_hv_hypercall[vcpu->vcpuid] = val;
		SVM_CTR1(vcpu, "nested HV HYPERCALL GPA set to %#lx",
		    (unsigned long)val);
		break;
	case MSR_HV_APIC_EOI:
		/*
		 * T34: L1 EOI write. TLFS 7.8b §3.1.6: any non-zero
		 * write signals EOI. We must NOT forward to the host
		 * LAPIC — L1's EOI only completes L1's in-service
		 * interrupt. Indirect EOI delivery via the L1's virtual
		 * APIC page is bhyve userspace's job (xmsr.c).
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		nested_hv_apic_eoi[vcpu->vcpuid] = val;
		SVM_CTR1(vcpu, "nested HV APIC EOI set to %#lx",
		    (unsigned long)val);
		break;
	case MSR_HV_APIC_ICR:
		/*
		 * T34: L1 ICR write. Triggers L1's interrupt delivery
		 * to L1's SINT routing — never host's LAPIC. The
		 * dispatch semantics live in xmsr.c.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		nested_hv_apic_icr[vcpu->vcpuid] = val;
		SVM_CTR1(vcpu, "nested HV APIC ICR set to %#lx",
		    (unsigned long)val);
		break;
	case MSR_HV_APIC_TPR:
		/*
		 * T34: L1 TPR write. Updates L1's APIC priority only.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		nested_hv_apic_tpr[vcpu->vcpuid] = val;
		SVM_CTR1(vcpu, "nested HV APIC TPR set to %#lx",
		    (unsigned long)val);
		break;
	case MSR_HV_REFERENCE_TSC:
		/*
		 * T35: L1 Reference TSC page GPA write. Validate
		 * page-aligned + mapped in L1 phys mem. Returns L1's
		 * TSC page GPA on RDMSR. The actual sequence/scale/
		 * offset fields are populated by bhyve userspace when
		 * L1 first writes the GPA.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		if (val != 0 && !nested_hv_validate_gpa(vcpu, val)) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		nested_hv_ref_tsc[vcpu->vcpuid] = val;
		SVM_CTR1(vcpu, "nested HV REFERENCE TSC GPA set to %#lx",
		    (unsigned long)val);
		break;
	case MSR_HV_TIME_REF_COUNT:
		/*
		 * T35: L1 TIME_REF_COUNT write. TLFS 7.8b §3.1.11 says
		 * this is RO; a write is a NOP (it's a counter, not a
		 * configuration). We silently accept.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		break;
	case MSR_HV_GUEST_OS_ID:
		/*
		 * T36: L1 OS identity write. Stores L1's OS ID.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		nested_hv_guest_os_id[vcpu->vcpuid] = val;
		SVM_CTR1(vcpu, "nested HV GUEST_OS_ID set to %#lx",
		    (unsigned long)val);
		break;
	case MSR_HV_VP_RUNTIME:
		/*
		 * T36: L1 vCPU runtime write. Accumulates L1's vCPU
		 * time. We store verbatim; accounting is bhyve's job.
		 * Note: a real VP_RUNTIME would also accept a "give me
		 * current time" write -- L1's instruction is not a
		 * simple store. Full semantics in xmsr.c.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		nested_hv_vp_runtime[vcpu->vcpuid] = val;
		SVM_CTR1(vcpu, "nested HV VP_RUNTIME set to %#lx",
		    (unsigned long)val);
		break;
	case MSR_HV_GUEST_IDLE:
		/*
		 * T36: L1 vCPU idle state write. Pass-through storage.
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		if (vcpu->vcpuid < 0 || vcpu->vcpuid >= MAXCPU) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		nested_hv_guest_idle[vcpu->vcpuid] = val;
		SVM_CTR1(vcpu, "nested HV GUEST_IDLE set to %#lx",
		    (unsigned long)val);
		break;
	case MSR_HV_RESET:
		/*
		 * T36: L1 reset request. TLFS 7.8b §3.1 requires that
		 * any non-zero write to MSR_HV_RESET triggers an
		 * immediate L1 reset. We accept the write but the
		 * actual reset is bhyve userspace's job (xmsr.c).
		 */
		if (vcpu->vcpu == NULL ||
		    !(vcpu->vcpu->vm->nested_enabled && vmm_nested_enable)) {
			error = EINVAL;
			break;
		}
		SVM_CTR1(vcpu, "nested HV RESET requested, val=%#lx",
		    (unsigned long)val);
		break;
	default:
		error = EINVAL;
		break;
	}

	return (error);
}
