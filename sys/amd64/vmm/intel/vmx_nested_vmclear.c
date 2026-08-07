/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * T18 (VMCLEAR): clear the L1-stated VMCS12 region pointed to by
 * the guest operand.  Per Intel SDM Vol 3 §30.2 VMCLEAR:
 *  - GPA must be page-aligned (otherwise VMFailInvalid)
 *  - The VMCS12 launch state is reset to CLEAR
 *  - VMCLEAR never raises VMFailValid; the only failure mode is
 *    VMFailInvalid for the alignment check.
 *
 * The wholesale VMCS-data-state clear: launch state back to CLEAR,
 * and the per-page VMCLEAR mentioned in the SDM is implemented by
 * the L1 OS rewritting the VMCS12 region on the next VMPTRLD; we
 * do not need to scrub the L1 page contents in-kernel.
 *
 * Original BSD code; Intel SDM Vol 3 §30.2 is referenced for the
 * VMCLEAR semantics only.
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

extern int vmm_nested_enable;

/*
 * Reset the VMCS12 launch state for the L1-stated VMCS12 GPA and
 * clear the L1's "current VMCS12" pointer if it matches.  Per
 * Intel SDM Vol 3 §30.2 VMCLEAR cannot fail with VMFailValid, so
 * the function returns 0 unconditionally after validating the
 * alignment.  The L1 page is not scrubbed; the L1 OS is expected
 * to refill the VMCS12 region on the next VMPTRLD.
 */
int
vmx_nested_vmclear_handle(struct vmx_vcpu *vcpu, uint64_t gpa)
{
	struct vmx_nested_state *ns;

	if (vcpu == NULL)
		return (-1);
	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);

	if ((gpa & PAGE_MASK) != 0)
		return (-1);

	/*
	 * The L1-stated VMCS12 GPA is canonicalised by the L1 OS;
	 * we just have to compare it against the currently installed
	 * pointer.  If the L1 cleared the active VMCS12 drop the
	 * "current" pointer so VMPTRST writes the sentinel
	 * 0xFFFFFFFFFFFFFFFF until the next VMPTRLD (matches the
	 * architecturally-defined "VMCS not currently in use" state).
	 */
	if (ns->vmcs12_active && ns->vmcs12_gpa == gpa) {
		ns->vmcs12_active = false;
		ns->vmcs12_gpa = 0;
		ns->state = VMCS12_STATE_CLEAR;
		ns->in_l2 = false;
	}

	VMX_CTR2(vcpu, "nested VMCLEAR: vmcs12 GPA=%#lx state=%d",
	    (unsigned long)gpa, ns->state);
	return (0);
}

/*
 * Top-level dispatch for EXIT_REASON_VMCLEAR.  The L1-stated GPA
 * operand is carried in the VM-exit qualification field (Intel
 * SDM §27.2.1 — VMCLEAR is m64, page-aligned by the architecture).
 * Returns 0 when the instruction has been emulated (caller
 * advances L1 RIP), -1 if the exit should fall through to
 * VM_EXITCODE_VMINSN userland (e.g. active-VMCS fatal).
 *
 * We deliberately do NOT handle the "current VMCS12" check here
 * (Intel SDM §30.2 says VMCLEAR on the current VMCS12 must NOT
 * fail), and we do NOT terminate the guest: spec says VMCLEAR
 * always succeeds, so the "set ZF" path is reserved for the
 * per-field bitmap violation (a much later wave).
 */
int
vmx_nested_exit_vmclear(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	uint64_t gpa;
	int rc;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);

	gpa = vmcs_exit_qualification();

	rc = vmx_nested_vmclear_handle(vcpu, gpa);
	if (rc != 0) {
		/*
		 * Reflect VMFailInvalid back to L1 via RFLAGS.ZF
		 * (Intel SDM §30.2).  We do not write a
		 * VM-instruction error code for VMFailInvalid.
		 */
		uint64_t rflags;

		rflags = vmcs_read(VMCS_GUEST_RFLAGS);
		rflags &= ~(PSL_C | PSL_Z);
		rflags |= PSL_Z;
		vmcs_write(VMCS_GUEST_RFLAGS, rflags);

		VMX_CTR1(vcpu, "nested VMCLEAR VMFailInvalid: gpa=%#lx",
		    (unsigned long)gpa);
		return (0);
	}

	VMX_CTR1(vcpu, "nested VMCLEAR: gpa=%#lx handled",
	    (unsigned long)gpa);
	return (0);
}
