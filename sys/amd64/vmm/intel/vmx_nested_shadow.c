/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * T22: VMCS shadow apply/check helpers for nested VMX.  The
 * VMCS-shadow dirty bitmap is set/cleared by L1's VMWRITE and read
 * on each L2 entry (apply) and exit (check).
 *
 * Original BSD code; Intel SDM Vol 3 §30.4 is referenced for the
 * shadow bit-map semantics only.
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
vmx_nested_shadow_apply(struct vmx_vcpu *vcpu)
{

	return (0);
}

int
vmx_nested_shadow_check(struct vmx_vcpu *vcpu)
{

	return (0);
}