/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 *
 * VMCALL from L1 (VMX root operation). Outside SMM there is no
 * SMM-transfer monitor, so the instruction fails: VMfailValid(1) with a
 * current VMCS, VMfailInvalid without one (SDM Vol 3 §30.3). VMCALL
 * from an L2 guest is an unconditional VM exit that will be reflected
 * to L1 once L2 entry exists.
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/vmm.h>

#include <dev/vmm/vmm_ktr.h>
#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmx_cpufunc.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_nested.h"

int
vmx_nested_vmcall_handle(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;

	if (vmx_nested_insn_check(vcpu, true) != 0)
		return (0);
	ns = vmx_nested_state(vcpu);
	if (ns->vmcs12_active)
		vmx_nested_vmfail_valid(vcpu, VMX_INSERR_VMCALL_IN_ROOT);
	else
		vmx_nested_vmfail_invalid(vcpu);
	return (0);
}

int
vmx_nested_exit_vmcall(struct vmx_vcpu *vcpu)
{

	return (vmx_nested_vmcall_handle(vcpu));
}
