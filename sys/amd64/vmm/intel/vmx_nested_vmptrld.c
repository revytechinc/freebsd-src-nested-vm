/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 *
 * VMPTRLD / VMPTRST emulation for nested VMX (SDM Vol 3 §30.3).
 *
 * The VMCS L1 names is copied into the private per-vCPU buffer
 * vcpu->nvmcs12; VMREAD/VMWRITE operate on that copy and it is flushed
 * back to L1 memory whenever the current VMCS changes. The hardware
 * VMCS used to run L1 is never touched here.
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
#include "vmx_controls.h"
#include "vmx_cpufunc.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_msr.h"
#include "vmx_nested.h"
#include "vmx_nested_layout.h"

extern int vmm_nested_enable;

/*
 * Make 'gpa' the current VMCS12. Returns VM_SUCCESS, or VM_FAIL_VALID
 * with *error set, or VM_FAIL_INVALID.
 */
int
vmx_nested_load_vmcs12(struct vmx_vcpu *vcpu, uint64_t gpa, uint32_t *error)
{
	struct vmx_nested_state *ns;
	uint32_t revision;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (VM_FAIL_INVALID);

	if ((gpa & PAGE_MASK) != 0 || gpa >= (1ul << cpu_maxphyaddr)) {
		*error = VMX_INSERR_VMPTRLD_INVALID_ADDR;
		return (VM_FAIL_VALID);
	}
	if (gpa == ns->vmxon_gpa) {
		*error = VMX_INSERR_VMPTRLD_VMXON_PTR;
		return (VM_FAIL_VALID);
	}
	if (ns->vmcs12_active && ns->vmcs12_gpa == gpa)
		return (VM_SUCCESS);	/* already current */

	if (vmx_nested_read_guest(vcpu, gpa, &revision, sizeof(revision))
	    != 0) {
		*error = VMX_INSERR_VMPTRLD_INVALID_ADDR;
		return (VM_FAIL_VALID);
	}
	if ((revision & 0x7fffffff) != vmx_revision() ||
	    (revision & 0x80000000) != 0) {
		*error = VMX_INSERR_VMPTRLD_REVISION;
		return (VM_FAIL_VALID);
	}

	/* Switch: park the old VMCS12 in L1 memory, pull in the new one. */
	vmx_nested_flush_vmcs12(vcpu);
	if (vmx_nested_read_guest(vcpu, gpa, vcpu->nvmcs12,
	    sizeof(struct vmcs12)) != 0) {
		ns->vmcs12_active = false;
		ns->vmcs12_gpa = 0;
		*error = VMX_INSERR_VMPTRLD_INVALID_ADDR;
		return (VM_FAIL_VALID);
	}
	ns->vmcs12_gpa = gpa;
	ns->vmcs12_active = true;
	ns->state = vcpu->nvmcs12->launch_state == VMCS12_LAUNCHED ?
	    VMCS12_STATE_LAUNCHED : VMCS12_STATE_CLEAR;
	ns->in_l2 = false;

	VMX_CTR2(vcpu, "nested VMPTRLD: vmcs12=%#lx state=%d",
	    (unsigned long)gpa, ns->state);
	return (VM_SUCCESS);
}

int
vmx_nested_exit_vmptrld(struct vmx_vcpu *vcpu)
{
	uint64_t gpa;
	uint32_t error;
	int rc;

	if (vmx_nested_insn_check(vcpu, true) != 0)
		return (0);
	if (vmx_nested_read_m64_operand(vcpu, &gpa) != 0)
		return (0);	/* fault injected */

	error = 0;
	rc = vmx_nested_load_vmcs12(vcpu, gpa, &error);
	if (rc == VM_SUCCESS)
		vmx_nested_vmsucceed(vcpu);
	else if (rc == VM_FAIL_VALID)
		vmx_nested_vmfail_valid(vcpu, error);
	else
		vmx_nested_vmfail_invalid(vcpu);
	return (0);
}

/*
 * VMPTRST m64: store the current-VMCS pointer, or ~0 when there is
 * none (SDM: "VMCS pointer is invalid").
 */
int
vmx_nested_exit_vmptrst(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	uint64_t gpa, cur;

	if (vmx_nested_insn_check(vcpu, true) != 0)
		return (0);
	ns = vmx_nested_state(vcpu);
	if (vmx_nested_decode_mem_operand(vcpu, sizeof(cur), VM_PROT_WRITE,
	    &gpa) != 0)
		return (0);
	cur = ns->vmcs12_active ? ns->vmcs12_gpa : ~0ul;
	if (vmx_nested_write_guest(vcpu, gpa, &cur, sizeof(cur)) != 0) {
		vm_inject_gp(vcpu->vcpu);
		return (0);
	}
	vmx_nested_vmsucceed(vcpu);
	return (0);
}
