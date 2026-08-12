/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * T20 (VMRESUME): re-entry into L2 after an L2 -> L1 VM-exit.
 * Per Intel SDM Vol 3 §30.6:
 *  - The current VMCS12 must be LAUNCHED (CLEAR means L1 has
 *    not yet issued VMLAUNCH).
 *  - VMRESUME never re-validates the VMCS12 contents; the
 *    assumption is that L1 has not modified the VMCS12 since
 *    the last L2 entry.  We do, however, re-run the shadow
 *    apply step so that any L1 VMWRITE the in_l1_0L1 path
 *    did between the previous L2 exit and now is honoured.
 *  - Failure to resume L2 raises VMFailValid with VM-instruction
 *    error code 5 (VMRESUME with non-launched VMCS12).
 *
 * Original BSD code; Intel SDM Vol 3 §30.6 is referenced for the
 * VMRESUME semantics only.
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
 * VM-instruction error code for VMRESUME on a non-launched
 * VMCS12 (Intel SDM Vol 3 §30.4 / §30.6).
 */
#define	VMX_INSERR_VMRESUME_NOT_LAUNCHED	5
#define	VMX_INSERR_VMRESUME_SHADOW_FAIL	9

/*
 * Re-apply the VMCS12 dirty fields to the active L0 VMCS, flip
 * the per-vCPU L2 marker, and prepare the L2 entry RIP.  Refuses
 * to resume when the current VMCS12 is not LAUNCHED (architectural
 * VMFailValid).
 *
 * Returns 0 on success, -1 on a VMFailValid pre-condition that
 * the caller (vmx_nested_exit_vmresume) reflects to L1 via CF.
 */
int
vmx_nested_vmresume_handle(struct vmx_vcpu *vcpu)
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

	if (ns->state != VMCS12_STATE_LAUNCHED) {
		VMX_CTR2(vcpu, "nested VMRESUME refused: state=%d "
		    "(expected LAUNCHED=%d)", ns->state,
		    VMCS12_STATE_LAUNCHED);
		vmcs_write(VMCS_INSTRUCTION_ERROR,
		    VMX_INSERR_VMRESUME_NOT_LAUNCHED);
		return (-1);
	}

	rc = vmx_nested_shadow_apply(vcpu);
	if (rc != 0) {
		VMX_CTR0(vcpu, "nested VMRESUME: shadow apply failed");
		vmcs_write(VMCS_INSTRUCTION_ERROR,
		    VMX_INSERR_VMRESUME_SHADOW_FAIL);
		return (-1);
	}

	vmcs12 = vcpu->nvmcs12;
	KASSERT(vmcs12 != NULL, ("nested VMRESUME: NULL nvmcs12"));

	if (vmcs12_read_field(vmcs12, VMCS_GUEST_RIP, &entry_rip) != 0)
		entry_rip = 0;
	if (vmcs12_read_field(vmcs12, VMCS_GUEST_RSP, &entry_rsp) != 0)
		entry_rsp = 0;
	vmcs_write(VMCS_GUEST_RIP, entry_rip);
	vmcs_write(VMCS_GUEST_RSP, entry_rsp);

	ns->in_l2 = true;

	VMX_CTR3(vcpu, "nested VMRESUME: entry RIP=%#lx RSP=%#lx state=%d",
	    (unsigned long)entry_rip, (unsigned long)entry_rsp, ns->state);
	return (0);
}

/*
 * Top-level dispatch for EXIT_REASON_VMRESUME.  Reflects
 * VMFailValid back to L1 via RFLAGS.CF when the resume cannot
 * proceed.  Returns 0 to indicate the exit has been consumed in
 * either branch (VMM marks the exit HANDLED and advances L1 RIP).
 */
int
vmx_nested_exit_vmresume(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	uint64_t rflags;
	int rc;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);

	rc = vmx_nested_vmresume_handle(vcpu);
	if (rc == 0)
		return (0);

	rflags = vmcs_read(VMCS_GUEST_RFLAGS);
	rflags &= ~(PSL_C | PSL_Z);
	rflags |= PSL_C;
	vmcs_write(VMCS_GUEST_RFLAGS, rflags);

	VMX_CTR0(vcpu, "nested VMRESUME reported VMFailValid to L1");
	return (0);
}
