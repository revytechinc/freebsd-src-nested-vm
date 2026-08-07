/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * T23b: nested INVEPT / INVVPID emulation.  When L1 executes
 * INVEPT/INVVPID we translate the L1 EPTP/VPID through to the
 * L0 INVEPT/INVVPID so the L0 MMU caches are invalidated.
 *
 * Both instructions follow the same pattern (Intel SDM Vol 3
 * §30.7):
 *  - the L1-stated operand is a memory descriptor pointed to
 *    by the VM-exit instruction info / VM-exit qualification
 *    field (the L1 operand is m64 in both cases);
 *  - the descriptor is a 16-byte struct (4 reserved, 4 EPTP /
 *    4 reserved, 8 reserved for INVEPT; 2 VPID, 2 reserved,
 *    4 reserved, 8 linear address for INVVPID);
 *  - the type is the L1-stated type byte in low 64 bits of the
 *    L1 RAX register (per SDM §30.7 INVEPT and §30.7 INVVPID);
 *  - the L1-stated EPTP / VPID lives in the descriptor.
 *
 * Original BSD code; Intel SDM Vol 3 §30.7 is referenced for
 * the INVEPT/INVVPID exit semantics only.
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
 * L1 INVEPT descriptor layout (Intel SDM Vol 3 §30.7 / §30.4).
 * The descriptor is a 16-byte little-endian struct:
 *
 *   bits  63:0  - EPTP (64-bit physical address of EPT root)
 *   bits 127:64 - reserved (must be zero)
 *
 * Earlier versions of this file declared EPTP as uint32_t,
 * which truncated the L1-stated EPTP to its low 32 bits and
 * caused L0 INVEPT to operate on a wrong EPT root — leaving
 * stale EPT mappings in the L0 MMU cache.
 */
struct invept_desc_l1 {
	uint64_t	eptp;
	uint64_t	reserved;
};
CTASSERT(sizeof(struct invept_desc_l1) == 16);

/*
 * L1 INVVPID descriptor layout (Intel SDM Vol 3 §30.7 / §30.4).
 * The VPID is 16 bits; the linear address is 64 bits; the
 * reserved fields pad to 16 bytes.
 */
struct invvpid_desc_l1 {
	uint16_t	vpid;
	uint16_t	_res1;
	uint32_t	_res2;
	uint64_t	linear_addr;
};
CTASSERT(sizeof(struct invvpid_desc_l1) == 16);

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

	/*
	 * Whitelist exact INVVPID types per Intel SDM Vol 3 §30.7:
	 *   0 - individual-address invalidation
	 *   1 - single-context invalidation
	 *   2 - all-contexts invalidation
	 * (Type 3 is only valid when INVVPID-with-retained-globals
	 * is supported by the silicon; we don't advertise that to
	 * L1 so we reject it here.)
	 *
	 * Additionally, types 0 and 1 with VPID 0 are
	 * architecturally undefined (SDM Vol 3 §30.7) — only
	 * type 2 (all-contexts) is valid with VPID 0.
	 */
	if (type != INVVPID_TYPE_ADDRESS &&
	    type != INVVPID_TYPE_SINGLE_CONTEXT &&
	    type != INVVPID_TYPE_ALL_CONTEXTS)
		return (-1);
	if ((type == INVVPID_TYPE_ADDRESS ||
	    type == INVVPID_TYPE_SINGLE_CONTEXT) && vpid == 0)
		return (-1);

	desc.vpid = vpid;
	desc._res1 = 0;
	desc._res2 = 0;
	desc.linear_addr = gla;
	invvpid(type, desc);
	return (VM_SUCCESS);
}

/*
 * Top-level dispatch for EXIT_REASON_INVEPT.  The L1-stated
 * type is carried in guest_rax; the descriptor GPA is the
 * VM-exit qualification field (Intel SDM §27.2.1 INVEPT is
 * m64).  We:
 *  1. validate the type (SINGLE_CONTEXT or ALL_CONTEXTS);
 *  2. validate the descriptor GPA is 16-byte aligned and
 *     fits inside a single 4KB page (Intel SDM §30.7 — the
 *     descriptor is exactly 16 bytes and the SDM defines
 *     it as naturally aligned to 16; the VM-exit qualification
 *     is also expected to carry an aligned address);
 *  3. hold the L1 descriptor page via vm_gpa_hold;
 *  4. read the EPTP out of the descriptor;
 *  5. call the L0 INVEPT with the L1-stated EPTP and type;
 *  6. release the hold and return 0 (caller advances L1 RIP).
 *
 * If the descriptor GPA is unreadable (vm_gpa_hold fails),
 * unaligned, or straddles a page boundary, we inject #GP into
 * L1 and return 0 (handled) so the L1 OS sees the architectural
 * fault rather than a fatal VMM path.  Returning -1 here would
 * let the exit bubble up to userland as VM_EXITCODE_VMINSN,
 * which L1 cannot recover from with a matching #GP.
 */
int
vmx_nested_exit_invept(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	struct vmxctx *vmxctx;
	struct invept_desc_l1 desc;
	uint64_t desc_gpa;
	uint64_t type;
	void *mapping;
	void *cookie;
	int rc;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);

	vmxctx = &vcpu->ctx;
	desc_gpa = vmcs_exit_qualification();
	type = vmxctx->guest_rax & 0xffffffffUL;

	if ((type != INVEPT_TYPE_SINGLE_CONTEXT) &&
	    (type != INVEPT_TYPE_ALL_CONTEXTS)) {
		VMX_CTR1(vcpu, "nested INVEPT: invalid type %#lx",
		    (unsigned long)type);
		return (-1);
	}

	/*
	 * Descriptor must be 16-byte aligned (SDM §30.7) and must
	 * fit entirely within a single 4KB page (the descriptor is
	 * 16 bytes, so pageoff + 16 <= 4096 means pageoff <= 0xff0).
	 * Otherwise inject #GP into L1.
	 */
	if ((desc_gpa & 0xf) != 0 || (desc_gpa & 0xfff) > 0xff0) {
		VMX_CTR1(vcpu, "nested INVEPT: unaligned/cross-page "
		    "desc=%#lx", (unsigned long)desc_gpa);
		vm_inject_gp(vcpu->vcpu);
		return (0);
	}

	mapping = vm_gpa_hold(vcpu->vcpu, desc_gpa, sizeof(desc), VM_PROT_READ,
	    &cookie);
	if (mapping == NULL) {
		VMX_CTR1(vcpu, "nested INVEPT: vm_gpa_hold failed for "
		    "desc=%#lx", (unsigned long)desc_gpa);
		vm_inject_gp(vcpu->vcpu);
		return (0);
	}
	memcpy(&desc, mapping, sizeof(desc));
	vm_gpa_release(cookie);

	rc = vmx_nested_invept_handle(vcpu, type, desc.eptp);
	if (rc != 0) {
		VMX_CTR1(vcpu, "nested INVEPT: handle failed type=%#lx",
		    (unsigned long)type);
		return (-1);
	}

	VMX_CTR2(vcpu, "nested INVEPT: type=%#lx eptp=%#x",
	    (unsigned long)type, (unsigned)desc.eptp);
	return (0);
}

/*
 * Top-level dispatch for EXIT_REASON_INVVPID.  Mirrors
 * vmx_nested_exit_invept() with the L1 INVVPID descriptor
 * layout.  The L1-stated type is in guest_rax, the descriptor
 * GPA is in the VM-exit qualification.
 *
 * Descriptor GPA alignment, cross-page check, and the failed-
 * hold #GP injection mirror the INVEPT path — see the long
 * comment on vmx_nested_exit_invept() for the rationale.
 */
int
vmx_nested_exit_invvpid(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	struct vmxctx *vmxctx;
	struct invvpid_desc_l1 desc;
	uint64_t desc_gpa;
	uint64_t type;
	void *mapping;
	void *cookie;
	int rc;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);

	vmxctx = &vcpu->ctx;
	desc_gpa = vmcs_exit_qualification();
	type = vmxctx->guest_rax & 0xffffffffUL;

	if (type != INVVPID_TYPE_ADDRESS &&
	    type != INVVPID_TYPE_SINGLE_CONTEXT &&
	    type != INVVPID_TYPE_ALL_CONTEXTS) {
		VMX_CTR1(vcpu, "nested INVVPID: invalid type %#lx",
		    (unsigned long)type);
		return (-1);
	}

	/*
	 * Descriptor must be 16-byte aligned (SDM §30.7) and
	 * must fit entirely within a single 4KB page; otherwise
	 * inject #GP into L1.
	 */
	if ((desc_gpa & 0xf) != 0 || (desc_gpa & 0xfff) > 0xff0) {
		VMX_CTR1(vcpu, "nested INVVPID: unaligned/cross-page "
		    "desc=%#lx", (unsigned long)desc_gpa);
		vm_inject_gp(vcpu->vcpu);
		return (0);
	}

	mapping = vm_gpa_hold(vcpu->vcpu, desc_gpa, sizeof(desc), VM_PROT_READ,
	    &cookie);
	if (mapping == NULL) {
		VMX_CTR1(vcpu, "nested INVVPID: vm_gpa_hold failed for "
		    "desc=%#lx", (unsigned long)desc_gpa);
		vm_inject_gp(vcpu->vcpu);
		return (0);
	}
	memcpy(&desc, mapping, sizeof(desc));
	vm_gpa_release(cookie);

	rc = vmx_nested_invvpid_handle(vcpu, type, desc.vpid,
	    desc.linear_addr);
	if (rc != 0) {
		VMX_CTR1(vcpu, "nested INVVPID: handle failed type=%#lx",
		    (unsigned long)type);
		return (-1);
	}

	VMX_CTR3(vcpu, "nested INVVPID: type=%#lx vpid=%u gla=%#lx",
	    (unsigned long)type, (unsigned)desc.vpid,
	    (unsigned long)desc.linear_addr);
	return (0);
}
