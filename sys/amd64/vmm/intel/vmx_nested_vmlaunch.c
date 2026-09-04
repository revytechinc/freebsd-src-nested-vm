/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 *
 * VMLAUNCH / VMRESUME emulation for nested VMX.
 *
 * Status: L0 does not yet build a VMCS02, so no L2 guest is entered.
 * Rather than corrupt L1's own VMCS (which is what writing VMCS12
 * fields into the active VMCS would do), a VM entry that passes the
 * instruction-level checks is completed the way hardware completes an
 * entry it cannot perform: with a "VM-entry failure due to invalid
 * guest state" exit delivered to L1 through the VMCS12 host-state
 * area (SDM Vol 3 §26.8). L1 hypervisors handle that exit as a fatal
 * error for the L2 guest and shut it down cleanly.
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/vmm.h>

#include <dev/vmm/vmm_ktr.h>
#include <dev/vmm/vmm_mem.h>
#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmx_cpufunc.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_nested.h"
#include "vmx_nested_layout.h"

#define	HWINTR_BLOCKING	(VMCS_INTERRUPTIBILITY_STI_BLOCKING | \
	    VMCS_INTERRUPTIBILITY_MOVSS_BLOCKING)
#define	EXIT_REASON_ENTRY_FAILURE	0x80000000u
#define	EXIT_REASON_INVALID_GUEST_STATE	33

/*
 * Common VMLAUNCH/VMRESUME path. Returns 0 when RFLAGS carries the
 * result and L1 continues after the instruction, or 1 when a VM exit
 * has been delivered to L1 and RIP must not be advanced.
 */
static int
vmx_nested_vmentry(struct vmx_vcpu *vcpu, bool launch)
{
	struct vmx_nested_state *ns;
	uint64_t intr;

	if (vmx_nested_insn_check(vcpu, true) != 0)
		return (0);
	ns = vmx_nested_state(vcpu);
	if (!ns->vmcs12_active) {
		vmx_nested_vmfail_invalid(vcpu);
		return (0);
	}
	/* Entry with MOV SS / STI blocking is VMfailValid (SDM §26.1). */
	intr = vmx_nested_vmcs_read(vcpu, VMCS_GUEST_INTERRUPTIBILITY);
	if ((intr & HWINTR_BLOCKING) != 0) {
		vmx_nested_vmfail_valid(vcpu, VMX_INSERR_ENTRY_BLOCKED_MOVSS);
		return (0);
	}
	if (launch && ns->state != VMCS12_STATE_CLEAR) {
		vmx_nested_vmfail_valid(vcpu, VMX_INSERR_VMLAUNCH_NOT_CLEAR);
		return (0);
	}
	if (!launch && ns->state != VMCS12_STATE_LAUNCHED) {
		vmx_nested_vmfail_valid(vcpu, VMX_INSERR_VMRESUME_NOT_LAUNCHED);
		return (0);
	}

	/*
	 * Enter L2. With the experimental L2 path enabled, build VMCS02 and
	 * flip in_l2 so the next vmx_run() runs L2. Otherwise report an
	 * architectural VM-entry failure (no L2 execution).
	 */
	if (vmx_nested_l2_enable) {
		if (launch)
			ns->state = VMCS12_STATE_LAUNCHED;
		if (vmx_nested_build_vmcs02(vcpu) == 0) {
			VMX_CTR1(vcpu, "nested %s: entering L2",
			    launch ? "VMLAUNCH" : "VMRESUME");
			return (1);	/* in_l2 set; next vmx_run runs L2 */
		}
		VMX_CTR0(vcpu, "nested entry: vmcs02 build failed");
	}
	VMX_CTR1(vcpu, "nested %s: no L2 support, reporting entry failure",
	    launch ? "VMLAUNCH" : "VMRESUME");
	/*
	 * This is a synthetic VM-entry-failure exit, not a reflected L2 exit,
	 * so there is no vmcs02 exit information to copy. Present clean
	 * instruction/event/address fields (vmx_nested_vmexit_to_l1() no longer
	 * zeroes these -- it leaves them to reflect_copy for real L2 exits).
	 */
	vmcs12_write_field(vcpu->nvmcs12, VMCS_EXIT_INTR_INFO, 0);
	vmcs12_write_field(vcpu->nvmcs12, VMCS_EXIT_INTR_ERRCODE, 0);
	vmcs12_write_field(vcpu->nvmcs12, VMCS_EXIT_INSTRUCTION_LENGTH, 0);
	vmcs12_write_field(vcpu->nvmcs12, VMCS_EXIT_INSTRUCTION_INFO, 0);
	vmcs12_write_field(vcpu->nvmcs12, VMCS_GUEST_LINEAR_ADDRESS, 0);
	vmcs12_write_field(vcpu->nvmcs12, VMCS_GUEST_PHYSICAL_ADDRESS, 0);
	vmx_nested_vmexit_to_l1(vcpu,
	    EXIT_REASON_ENTRY_FAILURE | EXIT_REASON_INVALID_GUEST_STATE, 0);
	return (1);
}

int
vmx_nested_vmlaunch_handle(struct vmx_vcpu *vcpu)
{

	return (vmx_nested_vmentry(vcpu, true));
}

int
vmx_nested_vmresume_handle(struct vmx_vcpu *vcpu)
{

	return (vmx_nested_vmentry(vcpu, false));
}

int
vmx_nested_exit_vmlaunch(struct vmx_vcpu *vcpu)
{

	return (vmx_nested_vmlaunch_handle(vcpu));
}

int
vmx_nested_exit_vmresume(struct vmx_vcpu *vcpu)
{

	return (vmx_nested_vmresume_handle(vcpu));
}
