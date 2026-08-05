/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * T19: VMREAD/VMWRITE field-by-field handlers for nested VMX.
 * The L1 hypervisor reads/writes its VMCS12 fields directly via
 * these instructions; we translate each encoding to a load/store
 * against vcpu->nvmcs12.
 *
 * Original BSD code; Intel SDM Vol 3 §30.3 / §30.4 is referenced
 * for the field encoding map.
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
vmx_nested_vmread(struct vmx_vcpu *vcpu, uint32_t encoding, uint64_t *val)
{

	/* Stub: filled in by T19 implementation commit. */
	return (-1);
}

int
vmx_nested_vmwrite(struct vmx_vcpu *vcpu, uint32_t encoding, uint64_t val)
{

	/* Stub: filled in by T19 implementation commit. */
	return (-1);
}

int
vmx_nested_exit_vmread(struct vmx_vcpu *vcpu)
{

	return (-1);
}

int
vmx_nested_exit_vmwrite(struct vmx_vcpu *vcpu)
{

	return (-1);
}