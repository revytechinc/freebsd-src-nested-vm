/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * VMCLEAR emulation for nested VMX (SDM Vol 3 §30.3).
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/vmm.h>
#include <x86/x86_var.h>

#include <dev/vmm/vmm_ktr.h>
#include <dev/vmm/vmm_mem.h>
#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmx_cpufunc.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_nested.h"
#include "vmx_nested_layout.h"

/*
 * VMCLEAR: set the launch state of the VMCS at 'gpa' to clear and, if
 * it is the current VMCS, make the current-VMCS pointer invalid after
 * writing the (private) contents back to L1 memory. Returns
 * VM_SUCCESS or VM_FAIL_VALID with *error set.
 */
int
vmx_nested_vmclear_handle(struct vmx_vcpu *vcpu, uint64_t gpa,
    uint32_t *error)
{
	struct vmx_nested_state *ns;
	uint32_t launch_state;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (VM_FAIL_INVALID);
	if ((gpa & PAGE_MASK) != 0 || gpa >= (1ul << cpu_maxphyaddr)) {
		*error = VMX_INSERR_VMCLEAR_INVALID_ADDR;
		return (VM_FAIL_VALID);
	}
	if (gpa == ns->vmxon_gpa) {
		*error = VMX_INSERR_VMCLEAR_VMXON_PTR;
		return (VM_FAIL_VALID);
	}

	if (ns->vmcs12_active && ns->vmcs12_gpa == gpa) {
		vcpu->nvmcs12->launch_state = VMCS12_CLEAR;
		vmx_nested_flush_vmcs12(vcpu);
		ns->vmcs12_active = false;
		ns->vmcs12_gpa = 0;
		ns->state = VMCS12_STATE_NONE;
		ns->in_l2 = false;
	} else {
		/* Not current: just mark the launch state in memory. */
		launch_state = VMCS12_CLEAR;
		if (vmx_nested_write_guest(vcpu,
		    gpa + offsetof(struct vmcs12, launch_state),
		    &launch_state, sizeof(launch_state)) != 0) {
			*error = VMX_INSERR_VMCLEAR_INVALID_ADDR;
			return (VM_FAIL_VALID);
		}
	}

	VMX_CTR1(vcpu, "nested VMCLEAR: vmcs12=%#lx", (unsigned long)gpa);
	return (VM_SUCCESS);
}

int
vmx_nested_exit_vmclear(struct vmx_vcpu *vcpu)
{
	uint64_t gpa;
	uint32_t error;
	int rc;

	if (vmx_nested_insn_check(vcpu, true) != 0)
		return (0);
	if (vmx_nested_read_m64_operand(vcpu, &gpa) != 0)
		return (0);

	error = 0;
	rc = vmx_nested_vmclear_handle(vcpu, gpa, &error);
	if (rc == VM_SUCCESS)
		vmx_nested_vmsucceed(vcpu);
	else if (rc == VM_FAIL_VALID)
		vmx_nested_vmfail_valid(vcpu, error);
	else
		vmx_nested_vmfail_invalid(vcpu);
	return (0);
}
