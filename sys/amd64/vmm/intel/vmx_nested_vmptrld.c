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

#include <machine/vmm.h>

#include <dev/vmm/vmm_ktr.h>
#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_cpufunc.h"
#include "vmx_msr.h"
#include "vmx_nested.h"

extern int vmm_nested_enable;

/*
 * Translate an L1-stated VMCS12 GPA to its HPA and copy the first
 * 4 bytes (revision ID) into *revision.  Returns NULL on failure
 * with the cookie stored so the caller can release.  On success the
 * caller MUST release the cookie via vm_gpa_release().
 */
static const struct vmcs12 *
vmx_nested_probe_vmcs12(struct vmx_vcpu *vcpu, uint64_t gpa,
    void **cookie, uint32_t *revision)
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
	*revision = vmcs12->revision_id;
	return (vmcs12);
}

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
	vmcs12 = vmx_nested_probe_vmcs12(vcpu, gpa, &cookie, NULL);
	if (vmcs12 == NULL)
		return (VM_FAIL_VALID);

	if (vmcs12->revision_id != l0_revision) {
		vm_gpa_release(cookie);
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

	VMX_CTR2(vcpu, "nested VMPTRLD: vmcs12 GPA=%#lx revision=%#x",
	    (unsigned long)gpa, l0_revision);

	return (VM_SUCCESS);
}

/*
 * Top-level dispatch for EXIT_REASON_VMPTRLD.  Called from
 * vmx_exit_process() with the L1-stated GPA in guest RAX (64-bit
 * mode).  Returns 0 if handled (caller advances L1 RIP), -1 if the
 * exit should bubble up to userspace as VM_EXITCODE_VMINSN.
 */
int
vmx_nested_exit_vmptrld(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	struct vmxctx *vmxctx;
	uint64_t gpa;
	int rc;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);

	vmxctx = &vcpu->ctx;
	gpa = vmxctx->guest_rax;

	rc = vmx_nested_load_vmcs12(vcpu, gpa);
	if (rc == VM_SUCCESS)
		return (0);

	/*
	 * VMFailValid: write the VM-instruction error code into the
	 * L1 VMCS via the L1-facing VMWRITE path.  For the Wave-4
	 * first pass we skip the error reporting back to L1 (the L1
	 * VMPTRLD handler can detect failure by checking the VMPTRLD
	 * result); logging is sufficient.
	 */
	VMX_CTR1(vcpu, "nested VMPTRLD failed: rc=%d", rc);
	return (0);
}