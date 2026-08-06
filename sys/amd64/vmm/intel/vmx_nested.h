/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * Nested-VMX (nVMX) helper API.  Wave 4 (T18-T23b) of the
 * nested-virtualization plan.  Original BSD code; Intel SDM Vol 3
 * §30 is referenced for VMCS-field semantics only.
 */

#ifndef	_VMX_NESTED_H_
#define	_VMX_NESTED_H_

#ifdef _KERNEL

#include <sys/types.h>

struct vmx;
struct vmx_vcpu;
struct vmcs;
struct vm_exit;
struct vcpu;

/*
 * VMCS12 is the L1-facing in-memory VMCS data structure.  Intel SDM
 * Vol 3 §30 describes the field encodings; L1 VMPTRLD points the CPU
 * at an L1-owned 4KB page whose layout matches the on-hardware VMCS
 * encoding map.  Because L1 may manipulate fields that L0 needs to
 * re-load on every L2 entry/exit, we mirror the L1 page into a
 * per-vCPU scratch buffer (vcpu->nvmcs12, allocated by Wave 3 T15)
 * and use a 4KB field bitmap to mark which fields have been touched.
 *
 * For Wave 4 we expose only the L1-stated VMCS12 pointer and the
 * launch state.  Field interpretation is split between
 * vmx_nested_vmread/vmwrite (T19), the VMCS-shadow layer (T22), and
 * the L2 launch path (T20/T23).
 */
struct vmcs12 {
	uint32_t	revision_id;
	uint32_t	abort_code;		/* only valid if launch failed */
	uint8_t		data[PAGE_SIZE - 2 * sizeof(uint32_t)];
};

CTASSERT(sizeof(struct vmcs12) == PAGE_SIZE);

/*
 * Per-vCPU Wave-4 state attached to struct vmx_vcpu.  Owns:
 *   - the L1-stated VMCS12 pointer (set on VMPTRLD, cleared on
 *     VMXOFF/VMCLEAR)
 *   - the launch state (clear -> launched transition)
 *   - the L1-stated EPT pointer (T23)
 *   - the VMCS-shadow dirty bitmap (T22)
 *   - the field-read/write bitmap used to enforce shadow-only writes
 *
 * vmx_nested.c owns the allocation; the actual VMCS12 shadow buffer
 * remains in vcpu->nvmcs12 (allocated by Wave 3 T15).
 */
enum vmcs12_state {
	VMCS12_STATE_NONE = 0,	/* no VMCS12 installed */
	VMCS12_STATE_CLEAR,	/* installed but never launched */
	VMCS12_STATE_LAUNCHED,	/* L2 is currently running under this VMCS12 */
};

struct vmx_nested_state {
	enum vmcs12_state	state;
	uint64_t		vmcs12_gpa;	/* L1's VMPTRLD GPA */
	uint64_t		ept12_pte;	/* T23: L1's EPT12 root pointer */
	bool			vmcs12_active;	/* matches nested_vmcs12_region */
	bool			in_l2;		/* L1 has executed VMLAUNCH */

	/*
	 * T22: VMCS-shadow field bitmap.  bit[i] = 1 means L1 has
	 * written field encoding 'i' since the last L2 launch.
	 * Sized at 4KB so every VMCS field encoding has a slot.
	 * Allocated lazily when the L1 first loads a VMCS12.
	 */
	uint8_t			*vmcs_field_dirty;
	uint8_t			*vmcs_field_ro;	/* L0-owned, read-only fields */
};

#define	VMCS_FIELD_BITMAP_SIZE	4096

/*
 * Per-vCPU-state accessor (vmx.c allocates the vmx_nested_state
 * alongside the existing vmx_vcpu struct).  Returns NULL if the
 * owning VM does not have nested_enabled set.
 */
struct vmx_nested_state *vmx_nested_state(struct vmx_vcpu *vcpu);

/*
 * T18 builder entry point.  Reads the VMCS12 header from 'gpa',
 * validates the revision ID against the L0 host revision, then
 * copies the L1 VMCS12 image into vcpu->nvmcs12 and installs it as
 * the current VMCS12.  Returns VM_SUCCESS, VM_FAIL_VALID, or
 * VM_FAIL_INVALID.  On VM_FAIL_VALID the VM-instruction error code
 * is written into the active VMCS's VMCS_INSTRUCTION_ERROR field.
 *
 * The caller is responsible for advancing L1 RIP past the VMPTRLD
 * instruction and reflecting VMFAIL back through RFLAGS (CF for
 * valid, ZF for invalid).
 */
int	vmx_nested_load_vmcs12(struct vmx_vcpu *vcpu, uint64_t gpa);

/*
 * T19: read a VMCS12 field encoding from the L1-stated VMCS12.
 * 'encoding' is the SDM §30 field encoding (16/32/64/natural-width).
 * 'val' receives the L1-stated value on success.  Returns 0 on
 * success, -1 if 'encoding' is unsupported (caller should
 * inject #GP).  L0-owned fields are returned from vmx->vm->state
 * (read-only) rather than from VMCS12.
 */
int	vmx_nested_vmread(struct vmx_vcpu *vcpu, uint32_t encoding,
	    uint64_t *val);

/*
 * T19: write a VMCS12 field encoding into the L1-stated VMCS12.
 * L1-owned fields land in vcpu->nvmcs12 (and the dirty bitmap is
 * marked).  L0-owned fields return -1 (caller injects #GP).
 *
 * Validation: if the L1 VMCS field-write bitmap (T22) is enabled,
 * the write is rejected for any encoding not marked writable.
 * For the Wave-4 first pass the writable set is a small allowlist
 * (CR0/CR3/CR4/RSP/RIP/RFLAGS, EPT12, MSR bitmap address, etc.).
 */
int	vmx_nested_vmwrite(struct vmx_vcpu *vcpu, uint32_t encoding,
	    uint64_t val);

/*
 * T20: emulate VMCLEAR.  The VMCS12 region pointed to by the
 * current 'vmcs12_gpa' (or 'verr' for the VMCS12 header GPA passed
 * in RAX) is cleared, the per-page launch-state is reset to
 * VMCS12_STATE_CLEAR, and the L0 launch-state counter is decremented
 * if the VMCS12 is currently launched.
 *
 * Returns 0 on success, -1 if no current VMCS12.
 */
int	vmx_nested_vmclear_handle(struct vmx_vcpu *vcpu, uint64_t gpa);

/*
 * T20: emulate VMLAUNCH.  Validates the current VMCS12, converts
 * the VMCS12 fields into the active VMCS (via the T22 VMCS-shadow
 * dirty bitmap), updates the L2 guest state (CR0/CR3/CR4/RSP/RIP/
 * RFLAGS) from VMCS12, dispatches to vmx_enter_guest() with
 * 'launched = 0'.  On entry, L1 transitions to VMCS12_STATE_LAUNCHED.
 *
 * Returns 0 on success, -1 on validation failure (caller injects
 * VMFailValid with the appropriate VM-instruction error).
 */
int	vmx_nested_vmlaunch_handle(struct vmx_vcpu *vcpu);

/*
 * T20: emulate VMRESUME.  Re-enters L2 from the saved L2 launch
 * state (T19 read-back).  Like VMLAUNCH but does NOT re-validate
 * VMCS12 — assumes it is unchanged since the last entry.
 */
int	vmx_nested_vmresume_handle(struct vmx_vcpu *vcpu);

/*
 * T21: emulate VMCALL.  Logs the hypercall arguments (RCX/RBX/RDX/
 * RDI/RSI/R8..R15), advances L1 RIP past the VMCALL, and re-enters
 * L1.  The T38 hypercall test exercises this stub.  When L1
 * hypercalls are wired up (T38), this becomes a real dispatch.
 */
int	vmx_nested_vmcall_handle(struct vmx_vcpu *vcpu);

/*
 * T22: install the initial VMCS12 field bitmap (read/write
 * permissions and dirty tracking).  Called once per VMCS12 install,
 * before the L1 first writes a field.  See Intel SDM Vol 3 §30.4
 * for the full bitmap layout.
 */
void	vmx_nested_shadow_init(struct vmx_nested_state *ns);

/*
 * T22: mark 'encoding' as written by L1 in the VMCS12 dirty bitmap.
 * Called from vmx_nested_vmwrite().  The shadow apply step reads
 * this bitmap to copy VMCS12 -> active VMCS at L2 entry time.
 */
void	vmx_nested_shadow_mark_dirty(struct vmx_nested_state *ns,
	    uint32_t encoding);

/*
 * T22: apply the VMCS12 dirty fields to the active L0 VMCS, then
 * clear the bitmap.  Called immediately before each L2 launch
 * (VMLAUNCH) or resume (VMRESUME).
 *
 * Returns 0 on success, -1 on a consistency failure (caller
 * injects VMFailValid).
 */
int	vmx_nested_shadow_apply(struct vmx_vcpu *vcpu);

/*
 * T22: copy the L0-active VMCS dirty fields back into the L1
 * VMCS12, then clear the L0 dirty bitmap.  Called on every L2 exit.
 */
int	vmx_nested_shadow_check(struct vmx_vcpu *vcpu);

/*
 * T23: install L1's EPT12 root pointer.  The translation chain
 * L2 GPA -> EPT12 -> L1 GPA -> EPT (L0) -> HPA is the deepest
 * layer of nested paging.  For the Wave-4 first pass we store the
 * EPT12 PTE but use identity-mapping (L2 GPA == L1 GPA) as the
 * fallback when EPT12 traversal would exceed the budget; the
 * TODO marker notes the missing real traversal.
 */
void	vmx_nested_ept12_install(struct vmx_vcpu *vcpu, uint64_t ept12_pte);

/*
 * T23: translate a L2 GPA through EPT12 to its corresponding L1
 * GPA.  Returns VM_SUCCESS and writes *out_l1_gpa on success.
 * For the Wave-4 first pass this returns the input GPA unchanged
 * (identity map) and notes TODO(mvp) for the real EPT12 walk.
 */
int	vmx_nested_ept12_translate(struct vmx_vcpu *vcpu, uint64_t l2_gpa,
	    uint64_t *out_l1_gpa);

/*
 * T23b: emulate L1 INVEPT.  The EPTP operand is taken from L1's
 * VMCS12 (which L1 just wrote via VMWRITE).  The descriptor's EPTP
 * is then passed through to the L0 INVEPT so the L0 EPT MMU caches
 * for that EPTP are invalidated.  Falls back to single-context
 * INVEPT if the L1 operand matches L0's EPTP, or all-context
 * INVEPT otherwise.
 */
int	vmx_nested_invept_handle(struct vmx_vcpu *vcpu, uint64_t type,
	    uint64_t eptp);

/*
 * T23b: emulate L1 INVVPID.  Same pattern as INVEPT but for VPIDs.
 */
int	vmx_nested_invvpid_handle(struct vmx_vcpu *vcpu, uint64_t type,
	    uint16_t vpid, uint64_t gla);

/*
 * Dispatch glue for the EXIT_REASON_VM* cases in vmx_exit_process
 * (vmx.c).  Each returns 0 if handled in-kernel (caller advances L1
 * RIP), -1 if the exit should bubble up to userspace
 * (VM_EXITCODE_VMINSN).  These are the entry points called from the
 * exit dispatcher.
 */
int	vmx_nested_exit_vmptrld(struct vmx_vcpu *vcpu);
int	vmx_nested_exit_vmclear(struct vmx_vcpu *vcpu);
int	vmx_nested_exit_vmptrst(struct vmx_vcpu *vcpu);
int	vmx_nested_exit_vmread(struct vmx_vcpu *vcpu);
int	vmx_nested_exit_vmwrite(struct vmx_vcpu *vcpu);
int	vmx_nested_exit_vmlaunch(struct vmx_vcpu *vcpu);
int	vmx_nested_exit_vmresume(struct vmx_vcpu *vcpu);
int	vmx_nested_exit_vmcall(struct vmx_vcpu *vcpu);
int	vmx_nested_exit_invept(struct vmx_vcpu *vcpu);
int	vmx_nested_exit_invvpid(struct vmx_vcpu *vcpu);

#endif	/* _KERNEL */

#endif	/* _VMX_NESTED_H_ */