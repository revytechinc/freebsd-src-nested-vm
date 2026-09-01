/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * INVEPT / INVVPID emulation for nested VMX (SDM Vol 3 §30.3).
 *
 * L2 runs on L0's EPT and VPID, so an L1 EPTP or VPID names nothing
 * the hardware knows about. Any valid L1 request is honoured by
 * invalidating the L0 context it could be aliased to: all EPT
 * contexts, or every translation for L0's VPID for this vCPU.
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/vmm.h>

#include <dev/vmm/vmm_ktr.h>
#include <dev/vmm/vmm_mem.h>
#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmx_cpufunc.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_nested.h"

static inline bool
vmx_canonical_address(uint64_t gla)
{

	return ((uint64_t)(((int64_t)gla << 16) >> 16) == gla);
}

struct invept_desc_l1 {
	uint64_t	eptp;
	uint64_t	reserved;
};
CTASSERT(sizeof(struct invept_desc_l1) == 16);

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

	if (type != INVEPT_TYPE_SINGLE_CONTEXT &&
	    type != INVEPT_TYPE_ALL_CONTEXTS)
		return (-1);
	if (type == INVEPT_TYPE_SINGLE_CONTEXT &&
	    (eptp & 0xfff0000000000000ul) != 0)
		return (-1);	/* reserved bits in the L1 EPTP */

	/* L1's EPTP is meaningless to hardware; flush every context. */
	desc.eptp = 0;
	desc._res = 0;
	invept(INVEPT_TYPE_ALL_CONTEXTS, desc);
	/*
	 * L1 issues INVEPT after changing EPT12. A pure ADDITION never makes
	 * the ept02 shadow stale: the added L2 GPA had no ept02 mapping (it
	 * faulted and was reflected because EPT12 did not map it). But an L1
	 * unmap or remap of a GPA already cached in ept02 -- e.g. a 2MB EPT12
	 * superpage that pmap later demotes/promotes to a different host frame
	 * -- would leave ept02 pointing at the OLD frame, so L2 would read
	 * another page's contents.
	 *
	 * Flushing the whole shadow inline on every INVEPT (tens of thousands
	 * during boot) with an all-CPU rendezvous is the flush storm that
	 * livelocked the host. Instead just bump a generation; build_vmcs02()
	 * tears the shadow down lazily at most once per L2 (re-)entry, with a
	 * local INVEPT rather than a rendezvous. The per-INVEPT local
	 * invept(ALL_CONTEXTS) above still drops any cached TLB translation.
	 */
	vmx_nested_state(vcpu)->ept12_gen++;
	return (VM_SUCCESS);
}

int
vmx_nested_invvpid_handle(struct vmx_vcpu *vcpu, uint64_t type, uint16_t vpid,
    uint64_t gla)
{
	struct invvpid_desc desc;

	if (type != INVVPID_TYPE_ADDRESS &&
	    type != INVVPID_TYPE_SINGLE_CONTEXT &&
	    type != INVVPID_TYPE_ALL_CONTEXTS)
		return (-1);
	if ((type == INVVPID_TYPE_ADDRESS ||
	    type == INVVPID_TYPE_SINGLE_CONTEXT) && vpid == 0)
		return (-1);
	if (type == INVVPID_TYPE_ADDRESS && !vmx_canonical_address(gla))
		return (-1);

	/* L2 shares L0's VPID: drop everything tagged with it. */
	desc.vpid = vcpu->state.vpid;
	desc._res1 = 0;
	desc._res2 = 0;
	desc.linear_addr = 0;
	if (desc.vpid != 0)
		invvpid(INVVPID_TYPE_SINGLE_CONTEXT, desc);
	return (VM_SUCCESS);
}

/*
 * Both instructions take the type in the register named by
 * instruction-information bits 31:28 and a 16-byte descriptor in
 * memory.
 */
static int
vmx_nested_read_invdesc(struct vmx_vcpu *vcpu, uint64_t *type, void *desc,
    size_t len)
{
	uint64_t info, gpa;

	info = vmx_nested_vmcs_read(vcpu, VMCS_EXIT_INSTRUCTION_INFO);
	*type = vmx_nested_get_reg(vcpu, (info >> 28) & 0xf);
	if (vmx_nested_decode_mem_operand(vcpu, len, VM_PROT_READ, &gpa) != 0)
		return (-1);
	if (vmx_nested_read_guest(vcpu, gpa, desc, len) != 0) {
		vm_inject_gp(vcpu->vcpu);
		return (-1);
	}
	return (0);
}

int
vmx_nested_exit_invept(struct vmx_vcpu *vcpu)
{
	struct invept_desc_l1 desc;
	uint64_t type;

	if (vmx_nested_insn_check(vcpu, true) != 0)
		return (0);
	if (vmx_nested_read_invdesc(vcpu, &type, &desc, sizeof(desc)) != 0)
		return (0);
	if (vmx_nested_invept_handle(vcpu, type, desc.eptp) != 0) {
		vmx_nested_vmfail_valid(vcpu, VMX_INSERR_INVALID_OPERAND);
		return (0);
	}
	vmx_nested_vmsucceed(vcpu);
	return (0);
}

int
vmx_nested_exit_invvpid(struct vmx_vcpu *vcpu)
{
	struct invvpid_desc_l1 desc;
	uint64_t type;

	if (vmx_nested_insn_check(vcpu, true) != 0)
		return (0);
	if (vmx_nested_read_invdesc(vcpu, &type, &desc, sizeof(desc)) != 0)
		return (0);
	if (desc._res1 != 0 || desc._res2 != 0 ||
	    vmx_nested_invvpid_handle(vcpu, type, desc.vpid,
	    desc.linear_addr) != 0) {
		vmx_nested_vmfail_valid(vcpu, VMX_INSERR_INVALID_OPERAND);
		return (0);
	}
	vmx_nested_vmsucceed(vcpu);
	return (0);
}
