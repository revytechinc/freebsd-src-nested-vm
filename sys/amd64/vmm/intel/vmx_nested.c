/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 *
 * Wave 4 (T18-T23b) shared state accessor and bitmap helpers for
 * nested VMX.  The per-task files (vmx_nested_vmptrld.c,
 * vmx_nested_vmread.c, etc.) own their respective slices of
 * functionality; this file provides the per-vCPU nested-state
 * pointer and the bitmap-allocation hooks that those files share.
 *
 * Original BSD code.
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <vm/vm.h>

#include <machine/vmm.h>

#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmx.h"
#include "vmx_nested.h"

extern int vmm_nested_enable;

/*
 * Per-vCPU nested-state accessor.
 *
 * The Wave-4 state struct is allocated lazily inside vmx.c's
 * vmx_vcpu_init() when the owning VM has nested_enabled.  This
 * accessor returns NULL otherwise, which lets per-task handlers
 * short-circuit cleanly on non-nested VMs (the existing
 * vmx_nested_active() check in vmx.c continues to gate the
 * higher-level dispatch).
 *
 * Handover contract:
 *  - vmx.c allocates the struct with M_WAITOK | M_ZERO so every
 *    field (state, vmcs12_gpa, vmcs12_active, ept12_pte, in_l2,
 *    vmcs_field_dirty, vmcs_field_ro) is initialised to 0/NULL.
 *    Per-task readers therefore never see uninitialised fields.
 *  - The state->vmcs_field_dirty / vmcs_field_ro pointers stay
 *    NULL until a later Wave task allocates them lazily; the
 *    shadow helpers below guard against NULL.
 *  - Whether a VM may nest is fixed when the VM is created: the
 *    host-wide sysctl is captured in vmx->nested_gate by vmx_init()
 *    and read nowhere else, so the answer cannot change under a
 *    caller and a nested-enabled VM always has nested state. The
 *    earlier version re-read the sysctl on every call and claimed
 *    the worst case was an early return; it was not -- callers
 *    dereference this, so flipping the sysctl under a live nested
 *    guest dereferenced NULL in the kernel.
 */
struct vmx_nested_state *
vmx_nested_state(struct vmx_vcpu *vcpu)
{
	struct vmx *vmx;

	if (vcpu == NULL)
		return (NULL);
	vmx = vcpu->vmx;
	if (vmx == NULL || vmx->vm == NULL)
		return (NULL);
	if (!vmx->vm->nested_enabled || !vmx->nested_gate)
		return (NULL);

	/*
	 * The state field is attached by vmx.c (see Wave-3 T15) for
	 * nested-enabled VMs; vcpu->nested_state is initialised to
	 * NULL at malloc-time.  vmx.c owns the lifecycle (alloc /
	 * free); the per-task files are read-only consumers.
	 *
	 * KASSERT the lifecycle invariant: a nested-enabled VM must
	 * have a non-NULL nested_state.  If this fires the vCPU
	 * init path forgot to allocate the struct, which would let
	 * the per-task handlers silently dereference garbage.
	 */
	KASSERT(vcpu->nested_state != NULL,
	    ("vmx_nested_state: nested_enabled but nested_state is NULL"));

	return (vcpu->nested_state);
}

/*
 * Initialise the VMCS12 shadow field bitmaps.  Called from
 * vmx_nested_load_vmcs12() on each fresh VMPTRLD.  The bitmaps are
 * 4KB so every architectural field encoding (16/32/64/natural
 * width) gets its own slot; only the bit positions that fall inside
 * the architecture-supported encoding range carry meaning.
 *
 * For Wave 4 first pass we mark a minimal set of L1-writable
 * fields: guest CR0/CR3/CR4/RSP/RIP/RFLAGS, exception bitmap,
 * pin/proc-based controls, exit/entry controls, I/O bitmap
 * addresses, MSR bitmap address, and EPT12 pointer.  Everything
 * else is L0-owned / read-only.
 */
