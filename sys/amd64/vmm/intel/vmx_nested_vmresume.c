/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * T20c: VMRESUME emulation for nested VMX.
 *
 * Original BSD code; Intel SDM Vol 3 §30.6 is referenced for the
 * VMRESUME semantics only.
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <machine/vmm.h>

#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_nested.h"

int
vmx_nested_vmresume_handle(struct vmx_vcpu *vcpu)
{

	return (-1);
}

int
vmx_nested_exit_vmresume(struct vmx_vcpu *vcpu)
{

	return (-1);
}