/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * T21 (VMCALL): the L1 hypercall from L2.  Per Intel SDM Vol 3
 * §30.7 VMCALL unconditionally exits the L2 guest back to L1;
 * we therefore:
 *  - clear the in_l2 marker so the next vmx_enter_guest() returns
 *    to L1,
 *  - advance L1's RIP past the VMCALL so L1 does not re-execute
 *    the hypercall (the dispatcher in vmx_exit_process() does
 *    this for us via vmcs_write(VMCS_GUEST_RIP, vmexit->rip)
 *    once we return HANDLED),
 *  - log the hypercall arguments so the L1 dispatch logic
 *    (Wave 7 / T38) can route them to the right backend.
 *
 * Original BSD code; Intel SDM Vol 3 §30.7 is referenced for the
 * VMCALL semantics only.
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/cpufunc.h>
#include <machine/vmm.h>

#include <dev/vmm/vmm_ktr.h>
#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmx.h"
#include "vmx_nested.h"

extern int vmm_nested_enable;

/*
 * Reset the per-vCPU L2 marker and log the raw hypercall
 * registers.  Wave 7 / T38 will replace the trace with a real
 * dispatch table; the count field lives in the nested state so a
 * later kldstat-style metric can attribute the boot-time
 * hypercall count to a vCPU.
 *
 * Returns 0 to indicate the VMCALL exit has been consumed.
 */
int
vmx_nested_vmcall_handle(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	struct vmxctx *vmxctx;
	uint64_t rcx __diagused, rbx __diagused, rdx __diagused;

	if (vcpu == NULL)
		return (-1);
	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);

	vmxctx = &vcpu->ctx;
	rcx = vmxctx->guest_rcx;
	rbx = vmxctx->guest_rbx;
	rdx = vmxctx->guest_rdx;

	VMX_CTR3(vcpu, "vmlaunch: vmcall rcx=0x%lx rbx=0x%lx rdx=0x%lx",
	    (unsigned long)rcx, (unsigned long)rbx, (unsigned long)rdx);

	ns->in_l2 = false;

	VMX_CTR3(vcpu, "nested VMCALL: rcx=%#lx rbx=%#lx rdx=%#lx",
	    (unsigned long)rcx, (unsigned long)rbx, (unsigned long)rdx);
	return (0);
}

/*
 * Top-level dispatch for EXIT_REASON_VMCALL.  Returns 0 to mark
 * the exit as HANDLED; the dispatcher in vmx_exit_process()
 * advances L1's RIP past the VMCALL via the standard exit-length
 * adjustment.  The hypercall arguments are read out of the L1
 * guest register save area.
 *
 * -1 is returned for the non-nested early-return path so the
 * existing userland VM_EXITCODE_VMINSN handler can still see
 * VMCALLs from non-nested VMs.
 */
int
vmx_nested_exit_vmcall(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);

	return (vmx_nested_vmcall_handle(vcpu));
}
