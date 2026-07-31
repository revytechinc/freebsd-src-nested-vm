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

#ifndef MSR_AMDK8_IPM
#define	MSR_AMDK8_IPM	0xc0010055
#endif

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
	void *cookie;
	void *mapping;

	if (vcpu->vcpu == NULL)
		return (0);
	if ((gpa & ~(uint64_t)MSR_HV_HYPERCALL_PAGE_MASK) != 0)
		return (0);
	mapping = vm_gpa_hold(vcpu->vcpu, gpa, 1, VM_PROT_READ, &cookie);
	if (mapping == NULL)
		return (0);
	vm_gpa_release(cookie);
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
#ifdef BHYVE_SNAPSHOT
	case MSR_TSC:
		svm_set_tsc_offset(vcpu, val - rdtsc());
		break;
#endif
	case MSR_EXTFEATURES:
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
	default:
		error = EINVAL;
		break;
	}

	return (error);
}
