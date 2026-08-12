/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * T20 (VMLAUNCH): entry into L2 by way of the L1-stated VMCS12.
 * Per Intel SDM Vol 3 §30.5:
 *  - The current VMCS12 must be in CLEAR state (not LAUNCHED).
 *  - Failure to enter L2 raises VMFailValid with a VM-instruction
 *    error code; VMFailInvalid is reserved for "no current VMCS12".
 *  - The actual L2 entry is performed by the existing
 *    vmx_enter_guest() path on the next nested-VM-exit return;
 *    here we only materialise the VMCS12 -> active VMCS state
 *    transition and flip the per-vCPU L2 marker.
 *
 * Original BSD code; Intel SDM Vol 3 §30.5 is referenced for the
 * VMLAUNCH semantics only.
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/cpufunc.h>
#include <machine/psl.h>
#include <machine/vmm.h>

#include <dev/vmm/vmm_ktr.h>
#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmx_cpufunc.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_nested.h"
#include "vmx_nested_layout.h"

extern int vmm_nested_enable;

/*
 * VMCS12 EPT-pointer field encoding.  Lives in the shared layout
 * table (vmcs12_lookup); we read it explicitly here so the helper
 * does not need to expose the constant.
 */
#define	VMCS12_EPT_POINTER_ENC	VMCS_EPTP

/*
 * VM-instruction error codes for VMLAUNCH (Intel SDM Vol 3
 * §30.4).  vmx_nested_vmlaunch_handle() installs the matching
 * value into the L1-facing VMCS_INSTRUCTION_ERROR on a
 * VMFailValid so the L1 VMLAUNCH handler can distinguish the
 * failure modes.
 */
#define	VMX_INSERR_VMLAUNCH_NOT_CLEAR	4
#define	VMX_INSERR_VMLAUNCH_SHADOW_FAIL	9

/*
 * Translate L1's VMCS12 fields into the active L0 VMCS, flip the
 * per-vCPU L2 marker, and advance the L0 guest RIP to the L1-
 * stated L2 entry RIP.  Refuses to launch when the current
 * VMCS12 is already LAUNCHED (architectural VMFailValid).
 *
 * Returns 0 to indicate the VMLAUNCH exit has been consumed
 * (caller advances L1 RIP).  Returns -1 if the shadow apply step
 * failed; the caller is responsible for the VMFailValid path
 * (write the VM-instruction error, set RFLAGS.CF, advance RIP).
 */
int
vmx_nested_vmlaunch_handle(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	struct vmcs12 *vmcs12;
	uint64_t entry_rip;
	uint64_t entry_rsp;
	int rc;

	if (vcpu == NULL)
		return (-1);
	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);

	/*
	 * Architectural precondition: VMLAUNCH on a non-CLEAR
	 * VMCS12 is VMFailValid with VM-instruction error 4.
	 * vmx_nested_exit_vmlaunch() wires the error code; we
	 * return -1 to let it write CF in RFLAGS.
	 */
	if (ns->state != VMCS12_STATE_CLEAR) {
		VMX_CTR2(vcpu, "nested VMLAUNCH refused: state=%d "
		    "(expected CLEAR=%d)", ns->state, VMCS12_STATE_CLEAR);
		vmcs_write(VMCS_INSTRUCTION_ERROR,
		    VMX_INSERR_VMLAUNCH_NOT_CLEAR);
		vmcs_write(VMCS_EXIT_QUALIFICATION, 0);
		return (-1);
	}

	rc = vmx_nested_shadow_apply(vcpu);
	if (rc != 0) {
		VMX_CTR0(vcpu, "nested VMLAUNCH: shadow apply failed");
		vmcs_write(VMCS_INSTRUCTION_ERROR,
		    VMX_INSERR_VMLAUNCH_SHADOW_FAIL);
		return (-1);
	}

	vmcs12 = vcpu->nvmcs12;
	KASSERT(vmcs12 != NULL, ("nested VMLAUNCH: NULL nvmcs12"));

	/*
	 * The L1-stated entry RIP controls where L2 starts
	 * executing.  Intel SDM §30.5 says VMLAUNCH does not
	 * re-load guest state from the VMCS12 into the host
	 * CPU, so the L0 VMCS12 already has the right value
	 * (we copied it via shadow_apply).  However the active
	 * L0 VMCS — which is the one L0 will use to enter L2
	 * via the next vmx_enter_guest() call — must reflect
	 * the L1-stated entry RIP and RSP explicitly.
	 */
	if (vmcs12_read_field(vmcs12, VMCS_GUEST_RIP, &entry_rip) != 0)
		entry_rip = 0;
	if (vmcs12_read_field(vmcs12, VMCS_GUEST_RSP, &entry_rsp) != 0)
		entry_rsp = 0;
	vmcs_write(VMCS_GUEST_RIP, entry_rip);
	vmcs_write(VMCS_GUEST_RSP, entry_rsp);

	ns->state = VMCS12_STATE_LAUNCHED;
	ns->in_l2 = true;

	VMX_CTR3(vcpu, "nested VMLAUNCH: entry RIP=%#lx RSP=%#lx state=%d",
	    (unsigned long)entry_rip, (unsigned long)entry_rsp, ns->state);
	return (0);
}

/*
 * Top-level dispatch for EXIT_REASON_VMLAUNCH.  Call the handle
 * helper; if it succeeded mark the exit as HANDLED, otherwise
 * reflect VMFailValid back to L1 via RFLAGS.CF.
 *
 * The L1-stated VMCS12 is the one vmx_nested_load_vmcs12()
 * installed, so we do not need to read an explicit operand here.
 *
 * Returns 0 (VMM should mark exit HANDLED and advance L1 RIP) on
 * success and on a VMFailValid that we have already reflected —
 * either way the in-kernel path is responsible for advancing RIP.
 * The architecture never reports -1 from this dispatch because the
 * dispatch in vmx_exit_process() relies on return 0 = "exit
 * consumed"; we communicate the failure to L1 by setting CF in
 * RFLAGS instead.
 */
int
vmx_nested_exit_vmlaunch(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	uint64_t rflags;
	int rc;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);

	rc = vmx_nested_vmlaunch_handle(vcpu);
	if (rc == 0)
		return (0);

	/*
	 * VMFailValid: set CF, clear ZF (Intel SDM §30.5).
	 * vmcs_write(VMCS_INSTRUCTION_ERROR, ...) already happened
	 * inside vmx_nested_vmlaunch_handle().
	 */
	rflags = vmcs_read(VMCS_GUEST_RFLAGS);
	rflags &= ~(PSL_C | PSL_Z);
	rflags |= PSL_C;
	vmcs_write(VMCS_GUEST_RFLAGS, rflags);

	VMX_CTR0(vcpu, "nested VMLAUNCH reported VMFailValid to L1");
	return (0);
}
