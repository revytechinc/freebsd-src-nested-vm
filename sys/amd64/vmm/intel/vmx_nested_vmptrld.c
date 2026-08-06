/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * T18: VMPTRLD emulation for nested VMX.  The L1 hypervisor uses
 * VMPTRLD to point the (real) VMCS hardware at a GPA in L1's
 * memory; we intercept the exit and install the L1-stated page as
 * the "current VMCS12" for the vCPU.
 *
 * Original BSD code; Intel SDM Vol 3 §30.1 is referenced for the
 * GPA/alignment/revision-ID rules.
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
#include "vmx_controls.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_cpufunc.h"
#include "vmx_msr.h"
#include "vmx_nested.h"

extern int vmm_nested_enable;

/*
 * Translate an L1-stated VMCS12 GPA to its HPA.  Returns NULL on
 * failure with the cookie stored so the caller can release.  On
 * success the caller MUST release the cookie via vm_gpa_release().
 *
 * The revision ID lives in the first 4 bytes of the returned
 * mapping; the caller reads it directly from vmcs12->revision_id
 * when it needs to validate it against the L0 host.
 */
static const struct vmcs12 *
vmx_nested_probe_vmcs12(struct vmx_vcpu *vcpu, uint64_t gpa, void **cookie)
{
	const struct vmcs12 *vmcs12;
	void *mapping;

	if ((gpa & PAGE_MASK) != 0)
		return (NULL);

	mapping = vm_gpa_hold(vcpu->vcpu, gpa, sizeof(struct vmcs12),
	    VM_PROT_READ, cookie);
	if (mapping == NULL)
		return (NULL);

	vmcs12 = mapping;
	return (vmcs12);
}

/*
 * VM-instruction error codes for VMCS_INSTRUCTION_ERROR (Intel SDM
 * Vol 3 §30.4).  vmx_nested_load_vmcs12() writes the appropriate
 * code back to L1 on a VMFailValid so the L1 VMPTRLD handler can
 * distinguish "couldn't read the GPA" from "revision mismatch".
 */
#define	VMX_INSERR_VMPTRLD_GPA_READ	4
#define	VMX_INSERR_VMPTRLD_REVISION	7

/*
 * Builder entry point for T18: parse the L1 VMCS12 at 'gpa',
 * validate the revision ID against the L0 host, then install the
 * region as the current VMCS12 for 'vcpu'.
 *
 * Per Intel SDM Vol 3 §30.1:
 *   - GPA must be page-aligned (otherwise VMFailInvalid)
 *   - GPA must resolve to a real mapping in L1 physical memory
 *     (otherwise VMFailValid with VM-instruction error 4)
 *   - VMCS12 revision ID must match the L0 host revision ID
 *     (otherwise VMFailValid with VM-instruction error 7)
 *
 * Returns VM_SUCCESS, VM_FAIL_INVALID, or VM_FAIL_VALID.  On
 * VM_FAIL_VALID the VM-instruction error code is written to the
 * L1-facing VMCS_INSTRUCTION_ERROR field (the L0 VMCS is the
 * active VMCS at the time vmx_nested_exit_vmptrld() runs, since
 * the L1 VM-exit has already torn down the shadow context).
 */
int
vmx_nested_load_vmcs12(struct vmx_vcpu *vcpu, uint64_t gpa)
{
	struct vmx_nested_state *ns;
	const struct vmcs12 *vmcs12;
	uint32_t l0_revision;
	void *cookie;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (VM_FAIL_INVALID);

	if (!vcpu->vmx->vm->nested_enabled || vmm_nested_enable == 0)
		return (VM_FAIL_INVALID);

	if (vcpu->vcpuid >= MAXCPU)
		return (VM_FAIL_INVALID);

	if ((gpa & PAGE_MASK) != 0)
		return (VM_FAIL_INVALID);

	l0_revision = vmx_revision();
	vmcs12 = vmx_nested_probe_vmcs12(vcpu, gpa, &cookie);
	if (vmcs12 == NULL) {
		vmcs_write(VMCS_INSTRUCTION_ERROR, VMX_INSERR_VMPTRLD_GPA_READ);
		return (VM_FAIL_VALID);
	}

	if (vmcs12->revision_id != l0_revision) {
		vm_gpa_release(cookie);
		vmcs_write(VMCS_INSTRUCTION_ERROR, VMX_INSERR_VMPTRLD_REVISION);
		return (VM_FAIL_VALID);
	}

	/*
	 * Copy the 4KB VMCS12 image into the per-vCPU scratch buffer
	 * allocated by Wave 3 T15 (vcpu->nvmcs12).  The L1 buffer is
	 * released immediately -- from this point on the L0 owns a
	 * private copy and the L1 page can be remapped/freed without
	 * affecting L0.
	 */
	memcpy(vcpu->nvmcs12, vmcs12, sizeof(struct vmcs12));
	vm_gpa_release(cookie);

	ns->vmcs12_gpa = gpa;
	ns->state = VMCS12_STATE_CLEAR;
	ns->vmcs12_active = true;

	/*
	 * The first time a real VMCS12 is installed for this vCPU,
	 * flip on VMCS shadowing in the per-vCPU L0 VMCS and point
	 * VMCS_LINK_POINTER at the nvmcs12 backing page.  The global
	 * procbased_ctls2 deliberately leaves shadowing off (see the
	 * T15/T18 note in vmx_modinit) because the link pointer
	 * starts out as ~0 from vmcs_init(), which is illegal when
	 * shadowing is on.  Doing this here -- gated on
	 * vmcs12_active flipping true -- means non-nested VMs and
	 * nested VMs before their first VMPTRLD see a shadowing-
	 * free VMCS that VM-enters cleanly.
	 */
	{
		struct vmcs *vmcs;
		uint64_t ctl2;
		uint64_t shadow_hpa;

		vmcs = vcpu->vmcs;
		VMPTRLD(vmcs);
		ctl2 = vmread(VMCS_SEC_PROC_BASED_CTLS);
		ctl2 |= PROCBASED2_VMCS_SHADOWING;
		vmwrite(VMCS_SEC_PROC_BASED_CTLS, ctl2);
		shadow_hpa = vtophys((vm_offset_t)vcpu->nvmcs12);
		vmwrite(VMCS_LINK_POINTER, shadow_hpa);
		VMCLEAR(vmcs);
	}

	VMX_CTR2(vcpu, "nested VMPTRLD: vmcs12 GPA=%#lx revision=%#x",
	    (unsigned long)gpa, l0_revision);

	return (VM_SUCCESS);
}

/*
 * Top-level dispatch for EXIT_REASON_VMPTRLD.  Called from
 * vmx_exit_process().  Returns 0 if handled (caller advances L1
 * RIP), -1 if the exit should bubble up to userspace as
 * VM_EXITCODE_VMINSN.
 *
 * The L1-stated GPA operand is read from the VM-exit qualification
 * field (Intel SDM §27.2.1): for VMPTRLD the qualification carries
 * the GPA directly when the instruction used a memory operand
 * (the GPA sits in the low 64 bits, already page-aligned by the
 * architecture).  We deliberately do NOT use guest_rax here: rax is
 * only relevant when the L1 used a register form, and even then the
 * architecture folds the operand through the exit qualification.
 */
int
vmx_nested_exit_vmptrld(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	uint64_t gpa;
	uint64_t rflags;
	int rc;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);

	gpa = vmcs_exit_qualification();

	rc = vmx_nested_load_vmcs12(vcpu, gpa);
	if (rc == VM_SUCCESS)
		return (0);

	/*
	 * Reflect the VMfailValid / VMfailInvalid result back to L1
	 * via RFLAGS (Intel SDM §30.1 / §30.2):
	 *   - VMfailValid: set CF, clear ZF; vmx_nested_load_vmcs12()
	 *     has already written the VM-instruction error code.
	 *   - VMfailInvalid: set ZF, clear CF; no error code applies.
	 */
	rflags = vmcs_read(VMCS_GUEST_RFLAGS);
	rflags &= ~(PSL_C | PSL_Z);
	if (rc == VM_FAIL_VALID) {
		rflags |= PSL_C;
	} else {
		rflags |= PSL_Z;
	}
	vmcs_write(VMCS_GUEST_RFLAGS, rflags);

	VMX_CTR2(vcpu, "nested VMPTRLD failed: rc=%d gpa=%#lx",
	    rc, (unsigned long)gpa);
	return (0);
}

/*
 * Top-level dispatch for EXIT_REASON_VMPTRST.  VMPTRST writes the
 * current VMCS-pointer into a memory operand supplied by L1
 * (Intel SDM Vol 3 §30.3 / §27.2.1).  For nested VMX we write the
 * L1-stated VMCS12 GPA that vmx_nested_load_vmcs12() stored in
 * the per-vCPU nested state; if no VMCS12 is currently installed
 * we write 0xFFFFFFFFFFFFFFFF (the architecturally-defined
 * "VMCS not currently in use" sentinel).
 *
 * The L1 memory operand GPA is taken from the VM-exit
 * qualification field; the write is performed via vm_gpa_hold()
 * with VM_PROT_WRITE so the L1 page is paged in / validated.
 */
int
vmx_nested_exit_vmptrst(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	uint64_t dst_gpa;
	uint64_t current_vmcs12;
	void *mapping;
	void *cookie;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);

	dst_gpa = vmcs_exit_qualification();

	current_vmcs12 = ns->vmcs12_active ? ns->vmcs12_gpa :
	    0xFFFFFFFFFFFFFFFFULL;

	mapping = vm_gpa_hold(vcpu->vcpu, dst_gpa, sizeof(uint64_t),
	    VM_PROT_WRITE, &cookie);
	if (mapping == NULL) {
		VMX_CTR1(vcpu, "nested VMPTRST: vm_gpa_hold failed for "
		    "dst=%#lx", (unsigned long)dst_gpa);
		return (-1);
	}

	memcpy(mapping, &current_vmcs12, sizeof(current_vmcs12));
	vm_gpa_release(cookie);

	VMX_CTR2(vcpu, "nested VMPTRST: wrote %#lx to L1 dst=%#lx",
	    (unsigned long)current_vmcs12, (unsigned long)dst_gpa);
	return (0);
}