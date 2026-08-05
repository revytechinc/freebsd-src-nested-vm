/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * T23b: nested INVEPT / INVVPID emulation.  When L1 executes
 * INVEPT/INVVPID we translate the L1 EPTP/VPID through to the L0
 * INVEPT/INVVPID so the L0 MMU caches are invalidated.
 *
 * Original BSD code; Intel SDM Vol 3 §30.7 is referenced for the
 * INVEPT/INVVPID exit semantics only.
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <machine/vmm.h>

#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmx_cpufunc.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_nested.h"

int
vmx_nested_invept_handle(struct vmx_vcpu *vcpu, uint64_t type, uint64_t eptp)
{
	struct invept_desc desc;

	if ((type != INVEPT_TYPE_SINGLE_CONTEXT) &&
	    (type != INVEPT_TYPE_ALL_CONTEXTS))
		return (-1);

	desc.eptp = eptp;
	desc._res = 0;
	invept(type, desc);
	return (VM_SUCCESS);
}

int
vmx_nested_invvpid_handle(struct vmx_vcpu *vcpu, uint64_t type, uint16_t vpid,
    uint64_t gla)
{
	struct invvpid_desc desc;

	if (type > INVVPID_TYPE_ALL_CONTEXTS)
		return (-1);

	desc.vpid = vpid;
	desc._res1 = 0;
	desc._res2 = 0;
	desc.linear_addr = gla;
	invvpid(type, desc);
	return (VM_SUCCESS);
}

int
vmx_nested_exit_invept(struct vmx_vcpu *vcpu)
{

	return (-1);
}

int
vmx_nested_exit_invvpid(struct vmx_vcpu *vcpu)
{

	return (-1);
}