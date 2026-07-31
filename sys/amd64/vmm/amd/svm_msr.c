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
 * Host-wide nested-virt gate (T2). File-scope extern mirrors the
 * pattern in sys/amd64/vmm/intel/vmx.c::nested_vmcs12_region.
 */
extern int vmm_nested_enable;

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
	case MSR_VM_HSAVE_PA:
		/*
		 * T8: nested-virt L1 HSAVE GPA write.
		 *
		 * Validate the GPA before storing: must be page-aligned
		 * (AMD APM Vol 2 §15.11) and must resolve to a real
		 * mapping in L1 physical memory (vm_gpa_hold succeeds).
		 * Any failure injects #GP; we do NOT update
		 * nested_hsave_gpa on failure (caller re-executes and
		 * faults via vm_inject_gp's hardware re-entry path).
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
		if ((val & PAGE_MASK) != 0) {
			vm_inject_gp(vcpu->vcpu);
			break;
		}
		{
			void *cookie;
			void *mapping;

			mapping = vm_gpa_hold(vcpu->vcpu, val, 1,
			    VM_PROT_READ, &cookie);
			if (mapping == NULL) {
				vm_inject_gp(vcpu->vcpu);
				break;
			}
			vm_gpa_release(cookie);
		}
		nested_hsave_gpa[vcpu->vcpuid] = val;
		SVM_CTR1(vcpu, "nested HSAVE GPA set to %#lx",
		    (unsigned long)val);
		break;
	default:
		error = EINVAL;
		break;
	}

	return (error);
}
