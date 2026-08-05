/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * T23: EPT12 nested translation.  L1's EPT12 root pointer is
 * installed by VMWRITE to the EPT_POINTER_FULL field; L0 uses
 * EPT12 as the inner page table for L2 (L2 GPA -> EPT12 -> L1 GPA
 * -> EPT -> HPA).
 *
 * Original BSD code; Intel SDM Vol 3 §30.4 / §29 is referenced
 * for the EPTP encoding only.
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <machine/vmm.h>

#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_cpufunc.h"
#include "vmx_nested.h"

void
vmx_nested_ept12_install(struct vmx_vcpu *vcpu, uint64_t ept12_pte)
{
	struct vmx_nested_state *ns;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return;
	ns->ept12_pte = ept12_pte;
}

int
vmx_nested_ept12_translate(struct vmx_vcpu *vcpu, uint64_t l2_gpa,
    uint64_t *out_l1_gpa)
{

	/* TODO(mvp): real EPT12 walk.  Identity-map fallback for now. */
	*out_l1_gpa = l2_gpa;
	return (VM_SUCCESS);
}