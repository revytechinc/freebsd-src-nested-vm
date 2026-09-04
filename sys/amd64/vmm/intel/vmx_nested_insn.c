/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 *
 * Shared machinery for emulating VMX instructions issued by an L1
 * hypervisor:
 *
 *   - operand decoding from the VM-exit instruction-information field
 *     (SDM Vol 3 Tables 27-9 .. 27-14) plus guest linear -> physical
 *     translation;
 *   - the VMsucceed / VMfailValid / VMfailInvalid RFLAGS conventions
 *     (SDM Vol 3 §30.2);
 *   - keeping L1's VMCS memory in sync with the private VMCS12 copy;
 *   - delivering a VM exit to L1 by loading the VMCS12 host-state
 *     area into the hardware VMCS (SDM Vol 3 §27.5).
 *
 * Original BSD code.
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/psl.h>
#include <machine/specialreg.h>
#include <machine/vmm.h>
#include <x86/x86_var.h>
#include <machine/vmm_instruction_emul.h>

#include <dev/vmm/vmm_ktr.h>
#include <dev/vmm/vmm_mem.h>
#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmx_cpufunc.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_controls.h"
#include "vmx_msr.h"
#include "vmx_nested.h"
#include "vmx_nested_layout.h"

/* VM-exit instruction information (SDM Vol 3 Table 27-13). */
#define	INSN_INFO_SCALING(i)		((i) & 0x3)
#define	INSN_INFO_REG1(i)		(((i) >> 3) & 0xf)
#define	INSN_INFO_ADDRSIZE(i)		(((i) >> 7) & 0x7)
#define	INSN_INFO_MEMREG(i)		(((i) >> 10) & 0x1)
#define	INSN_INFO_SEG(i)		(((i) >> 15) & 0x7)
#define	INSN_INFO_INDEX(i)		(((i) >> 18) & 0xf)
#define	INSN_INFO_INDEX_INVALID(i)	(((i) >> 22) & 0x1)
#define	INSN_INFO_BASE(i)		(((i) >> 23) & 0xf)
#define	INSN_INFO_BASE_INVALID(i)	(((i) >> 27) & 0x1)
#define	INSN_INFO_REG2(i)		(((i) >> 28) & 0xf)

static const enum vm_reg_name insn_seg_regs[] = {
	VM_REG_GUEST_ES, VM_REG_GUEST_CS, VM_REG_GUEST_SS, VM_REG_GUEST_DS,
	VM_REG_GUEST_FS, VM_REG_GUEST_GS,
};

/*
 * The nested instruction handlers run from vm_run() (vmm_ops.nested),
 * where the vcpu is FROZEN and no VMCS is current. Every VMCS access
 * therefore loads and clears the vcpu's VMCS around itself, the way
 * vmx_getreg()/vmx_setreg() do for a stopped vcpu; keeping the VMCS
 * loaded across calls into vm_*() helpers is not possible because those
 * helpers do the same and would clear it underneath us.
 */
uint64_t
vmx_nested_vmcs_read(struct vmx_vcpu *vcpu, uint32_t encoding)
{
	uint64_t val;
	int error __diagused;

	error = vmcs_getreg(vcpu->vmcs,
	    vmx_nested_state(vcpu)->l1_vmcs_current, VMCS_IDENT(encoding), &val);
	KASSERT(error == 0, ("vmcs_getreg(%#x): %d", encoding, error));
	return (val);
}

void
vmx_nested_vmcs_write(struct vmx_vcpu *vcpu, uint32_t encoding, uint64_t val)
{
	int error __diagused;

	error = vmcs_setreg(vcpu->vmcs,
	    vmx_nested_state(vcpu)->l1_vmcs_current, VMCS_IDENT(encoding), val);
	KASSERT(error == 0, ("vmcs_setreg(%#x): %d", encoding, error));
}

int
vmx_nested_cpl(struct vmx_vcpu *vcpu)
{

	return ((vmx_nested_vmcs_read(vcpu, VMCS_GUEST_SS_ACCESS_RIGHTS) >> 5)
	    & 3);
}

enum vm_cpu_mode
vmx_nested_cpu_mode(struct vmx_vcpu *vcpu)
{

	if (vmx_nested_vmcs_read(vcpu, VMCS_GUEST_IA32_EFER) & EFER_LMA) {
		if (vmx_nested_vmcs_read(vcpu, VMCS_GUEST_CS_ACCESS_RIGHTS) &
		    0x2000)
			return (CPU_MODE_64BIT);	/* CS.L = 1 */
		return (CPU_MODE_COMPATIBILITY);
	} else if (vmx_nested_vmcs_read(vcpu, VMCS_GUEST_CR0) & CR0_PE)
		return (CPU_MODE_PROTECTED);
	return (CPU_MODE_REAL);
}

static enum vm_paging_mode
vmx_nested_paging_mode(struct vmx_vcpu *vcpu)
{
	uint64_t cr4;

	if (!(vmx_nested_vmcs_read(vcpu, VMCS_GUEST_CR0) & CR0_PG))
		return (PAGING_MODE_FLAT);
	cr4 = vmx_nested_vmcs_read(vcpu, VMCS_GUEST_CR4);
	if (!(cr4 & CR4_PAE))
		return (PAGING_MODE_32);
	if (vmx_nested_vmcs_read(vcpu, VMCS_GUEST_IA32_EFER) & EFER_LME) {
		if (!(cr4 & CR4_LA57))
			return (PAGING_MODE_64);
		return (PAGING_MODE_64_LA57);
	}
	return (PAGING_MODE_PAE);
}

static void
vmx_nested_paging_info(struct vmx_vcpu *vcpu, struct vm_guest_paging *paging)
{

	paging->cr3 = vmx_nested_vmcs_read(vcpu, VMCS_GUEST_CR3);
	paging->cpl = vmx_nested_cpl(vcpu);
	paging->cpu_mode = vmx_nested_cpu_mode(vcpu);
	paging->paging_mode = vmx_nested_paging_mode(vcpu);
}

/* Segment descriptor cache of one of the six data/code segments. */
static void
vmx_nested_seg_desc(struct vmx_vcpu *vcpu, int seg, struct seg_desc *desc)
{
	static const uint32_t base[] = { VMCS_GUEST_ES_BASE, VMCS_GUEST_CS_BASE,
	    VMCS_GUEST_SS_BASE, VMCS_GUEST_DS_BASE, VMCS_GUEST_FS_BASE,
	    VMCS_GUEST_GS_BASE };
	static const uint32_t limit[] = { VMCS_GUEST_ES_LIMIT,
	    VMCS_GUEST_CS_LIMIT, VMCS_GUEST_SS_LIMIT, VMCS_GUEST_DS_LIMIT,
	    VMCS_GUEST_FS_LIMIT, VMCS_GUEST_GS_LIMIT };
	static const uint32_t ar[] = { VMCS_GUEST_ES_ACCESS_RIGHTS,
	    VMCS_GUEST_CS_ACCESS_RIGHTS, VMCS_GUEST_SS_ACCESS_RIGHTS,
	    VMCS_GUEST_DS_ACCESS_RIGHTS, VMCS_GUEST_FS_ACCESS_RIGHTS,
	    VMCS_GUEST_GS_ACCESS_RIGHTS };

	desc->base = vmx_nested_vmcs_read(vcpu, base[seg]);
	desc->limit = vmx_nested_vmcs_read(vcpu, limit[seg]);
	desc->access = vmx_nested_vmcs_read(vcpu, ar[seg]);
}

uint64_t
vmx_nested_get_reg(struct vmx_vcpu *vcpu, int ident)
{
	const struct vmxctx *c = &vcpu->ctx;

	switch (ident) {
	case 0: return (c->guest_rax);
	case 1: return (c->guest_rcx);
	case 2: return (c->guest_rdx);
	case 3: return (c->guest_rbx);
	case 4: return (vmx_nested_vmcs_read(vcpu, VMCS_GUEST_RSP));
	case 5: return (c->guest_rbp);
	case 6: return (c->guest_rsi);
	case 7: return (c->guest_rdi);
	case 8: return (c->guest_r8);
	case 9: return (c->guest_r9);
	case 10: return (c->guest_r10);
	case 11: return (c->guest_r11);
	case 12: return (c->guest_r12);
	case 13: return (c->guest_r13);
	case 14: return (c->guest_r14);
	default: return (c->guest_r15);
	}
}

void
vmx_nested_set_reg(struct vmx_vcpu *vcpu, int ident, uint64_t val)
{
	struct vmxctx *c = &vcpu->ctx;

	switch (ident) {
	case 0: c->guest_rax = val; break;
	case 1: c->guest_rcx = val; break;
	case 2: c->guest_rdx = val; break;
	case 3: c->guest_rbx = val; break;
	case 4: vmx_nested_vmcs_write(vcpu, VMCS_GUEST_RSP, val); break;
	case 5: c->guest_rbp = val; break;
	case 6: c->guest_rsi = val; break;
	case 7: c->guest_rdi = val; break;
	case 8: c->guest_r8 = val; break;
	case 9: c->guest_r9 = val; break;
	case 10: c->guest_r10 = val; break;
	case 11: c->guest_r11 = val; break;
	case 12: c->guest_r12 = val; break;
	case 13: c->guest_r13 = val; break;
	case 14: c->guest_r14 = val; break;
	default: c->guest_r15 = val; break;
	}
}

/*
 * Decode the memory operand of the VMX instruction that just exited
 * and translate it to a guest-physical address. 'size' is the operand
 * size in bytes, 'prot' the access being performed.
 *
 * Returns 0 with *gpa set, or -1 after injecting the appropriate fault
 * into L1 (#GP for a non-canonical / unmapped address, #PF via
 * vm_gla2gpa).
 */
int
vmx_nested_decode_mem_operand(struct vmx_vcpu *vcpu, size_t size, int prot,
    uint64_t *gpa)
{
	struct vm_guest_paging paging;
	struct seg_desc desc;
	uint64_t info, gla, disp, base, index;
	int addrsize, fault, seg, scale, error;

	error = 0;

	info = vmx_nested_vmcs_read(vcpu, VMCS_EXIT_INSTRUCTION_INFO);
	if (INSN_INFO_MEMREG(info) != 0)
		return (-1);		/* register operand: not memory */

	disp = vmx_nested_vmcs_read(vcpu, VMCS_EXIT_QUALIFICATION);
	base = INSN_INFO_BASE_INVALID(info) ? 0 :
	    vmx_nested_get_reg(vcpu, INSN_INFO_BASE(info));
	index = INSN_INFO_INDEX_INVALID(info) ? 0 :
	    vmx_nested_get_reg(vcpu, INSN_INFO_INDEX(info));
	scale = 1 << INSN_INFO_SCALING(info);
	seg = INSN_INFO_SEG(info);
	if (seg >= nitems(insn_seg_regs))
		seg = 3;		/* DS */

	switch (INSN_INFO_ADDRSIZE(info)) {
	case 0: addrsize = 2; break;
	case 1: addrsize = 4; break;
	default: addrsize = 8; break;
	}

	vmx_nested_paging_info(vcpu, &paging);
	vmx_nested_seg_desc(vcpu, seg, &desc);

	if (vie_calculate_gla(paging.cpu_mode, insn_seg_regs[seg], &desc,
	    base + index * scale + disp, size, addrsize, prot, &gla) != 0) {
		vm_inject_gp(vcpu->vcpu);
		return (-1);
	}

	error = vm_gla2gpa(vcpu->vcpu, &paging, gla, prot, gpa, &fault);
	if (error != 0 || fault != 0)
		return (-1);	/* vm_gla2gpa injected #PF on fault */
	return (0);
}

int
vmx_nested_read_guest(struct vmx_vcpu *vcpu, uint64_t gpa, void *buf,
    size_t len)
{
	void *mapping, *cookie;

	if ((gpa & PAGE_MASK) + len > PAGE_SIZE)
		return (-1);
	mapping = vm_gpa_hold(vcpu->vcpu, gpa, len, VM_PROT_READ, &cookie);
	if (mapping == NULL)
		return (-1);
	memcpy(buf, mapping, len);
	vm_gpa_release(cookie);
	return (0);
}

int
vmx_nested_write_guest(struct vmx_vcpu *vcpu, uint64_t gpa, const void *buf,
    size_t len)
{
	void *mapping, *cookie;

	if ((gpa & PAGE_MASK) + len > PAGE_SIZE)
		return (-1);
	mapping = vm_gpa_hold(vcpu->vcpu, gpa, len, VM_PROT_WRITE, &cookie);
	if (mapping == NULL)
		return (-1);
	memcpy(mapping, buf, len);
	vm_gpa_release(cookie);
	return (0);
}

/*
 * Read the 64-bit memory operand of VMPTRLD/VMCLEAR/VMXON/VMPTRST
 * style instructions (the VMCS pointer itself lives in memory).
 */
int
vmx_nested_read_m64_operand(struct vmx_vcpu *vcpu, uint64_t *val)
{
	uint64_t gpa;

	if (vmx_nested_decode_mem_operand(vcpu, sizeof(*val), VM_PROT_READ,
	    &gpa) != 0)
		return (-1);
	if (vmx_nested_read_guest(vcpu, gpa, val, sizeof(*val)) != 0) {
		vm_inject_gp(vcpu->vcpu);
		return (-1);
	}
	return (0);
}

/* SDM Vol 3 §30.2: VMsucceed clears CF, PF, AF, ZF, SF and OF. */
#define	VMX_RFLAGS_STATUS	(PSL_C | PSL_PF | PSL_AF | PSL_Z | PSL_N | PSL_V)

void
vmx_nested_vmsucceed(struct vmx_vcpu *vcpu __unused)
{
	uint64_t rflags;

	rflags = vmx_nested_vmcs_read(vcpu, VMCS_GUEST_RFLAGS);
	rflags &= ~VMX_RFLAGS_STATUS;
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_RFLAGS, rflags);
}

void
vmx_nested_vmfail_invalid(struct vmx_vcpu *vcpu __unused)
{
	uint64_t rflags;

	rflags = vmx_nested_vmcs_read(vcpu, VMCS_GUEST_RFLAGS);
	rflags &= ~VMX_RFLAGS_STATUS;
	rflags |= PSL_Z;
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_RFLAGS, rflags);
}

/*
 * VMfailValid: CF set, the error number goes into the *current VMCS12*
 * (L1 reads it back with VMREAD of VM_INSTRUCTION_ERROR). Without a
 * current VMCS the architecture only allows VMfailInvalid.
 */
void
vmx_nested_vmfail_valid(struct vmx_vcpu *vcpu, uint32_t error)
{
	struct vmx_nested_state *ns;
	uint64_t rflags;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL || !ns->vmcs12_active) {
		vmx_nested_vmfail_invalid(vcpu);
		return;
	}
	vmcs12_write_field(vcpu->nvmcs12, VMCS_INSTRUCTION_ERROR, error);
	rflags = vmx_nested_vmcs_read(vcpu, VMCS_GUEST_RFLAGS);
	rflags &= ~VMX_RFLAGS_STATUS;
	rflags |= PSL_C;
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_RFLAGS, rflags);
}

/*
 * Common legality check for every VMX instruction (SDM §30.3): #UD
 * outside VMX operation, #GP for CPL > 0. Returns 0 if the instruction
 * may proceed; otherwise the fault has been injected.
 */
int
vmx_nested_insn_check(struct vmx_vcpu *vcpu, bool need_vmxon)
{
	struct vmx_nested_state *ns;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL || (need_vmxon && !ns->vmxon)) {
		vm_inject_ud(vcpu->vcpu);
		return (-1);
	}
	if (vmx_nested_cpl(vcpu) != 0) {
		vm_inject_gp(vcpu->vcpu);
		return (-1);
	}
	return (0);
}

/*
 * Write the private VMCS12 copy back to L1's memory. Called before the
 * current VMCS changes (VMPTRLD of another VMCS, VMCLEAR) so an L1 that
 * juggles several VMCSes (one per L2 vCPU) does not lose state.
 */
void
vmx_nested_flush_vmcs12(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL || !ns->vmcs12_active || vcpu->nvmcs12 == NULL)
		return;
	if (vmx_nested_write_guest(vcpu, ns->vmcs12_gpa, vcpu->nvmcs12,
	    sizeof(struct vmcs12)) != 0)
		VMX_CTR1(vcpu, "nested: could not flush VMCS12 to %#lx",
		    (unsigned long)ns->vmcs12_gpa);
}

/*
 * Segment access-rights values loaded on VM exit (SDM §27.5.2).
 */
#define	AR_CS_64	0xa09b
#define	AR_CS_32	0xc09b
#define	AR_DATA		0xc093
#define	AR_TR		0x008b
#define	AR_UNUSABLE	0x10000

static void
vmx_nested_load_host_seg(struct vmx_vcpu *vcpu, uint32_t sel_enc,
    uint32_t base_enc, uint32_t limit_enc, uint32_t ar_enc, uint16_t sel,
    uint64_t base, uint32_t limit, uint32_t ar, bool unusable_if_null)
{

	vmx_nested_vmcs_write(vcpu, sel_enc, sel);
	vmx_nested_vmcs_write(vcpu, base_enc, base);
	vmx_nested_vmcs_write(vcpu, limit_enc, limit);
	if (unusable_if_null && sel == 0)
		ar = AR_UNUSABLE;
	vmx_nested_vmcs_write(vcpu, ar_enc, ar);
}

/*
 * Deliver a VM exit to L1: record the exit information in VMCS12 and
 * load the VMCS12 host-state area into the hardware VMCS so L1 resumes
 * at HOST_RIP in its own address space. The general-purpose registers
 * other than RSP are untouched, as on hardware.
 *
 * 'basic_reason' may have bit 31 set to report a failed VM entry.
 */
void
vmx_nested_vmexit_to_l1(struct vmx_vcpu *vcpu, uint32_t reason,
    uint64_t qualification)
{
	struct vmx_nested_state *ns;
	struct vmcs12 *v12;
	uint64_t val, exit_ctls, cr0, cr4, efer;
	bool host64;

	ns = vmx_nested_state(vcpu);
	v12 = vcpu->nvmcs12;
	KASSERT(ns != NULL && ns->vmcs12_active && v12 != NULL,
	    ("vmx_nested_vmexit_to_l1 without a current VMCS12"));

	vmcs12_write_field(v12, VMCS_EXIT_REASON, reason);
	vmcs12_write_field(v12, VMCS_EXIT_QUALIFICATION, qualification);
	/*
	 * The IDT-vectoring fields are cleared for every exit delivered to L1:
	 * no event was mid-delivery. The instruction-length, instruction-info,
	 * interrupt-info/errcode and guest-address fields are NOT touched here
	 * -- they belong to whoever describes the exit. For a genuine L2 exit
	 * vmx_nested_reflect_copy() has already filled them from vmcs02, and L1
	 * needs the real EXIT_INSTRUCTION_LENGTH to advance L2's RIP past the
	 * faulting instruction (e.g. CPUID); zeroing it here made L1 advance by
	 * 0 and spin L2 forever on that instruction. The VM-entry-failure
	 * caller, which has no vmcs02 exit to copy, zeroes them itself.
	 */
	vmcs12_write_field(v12, VMCS_IDT_VECTORING_INFO, 0);
	vmcs12_write_field(v12, VMCS_IDT_VECTORING_ERROR, 0);

	vmcs12_read_field(v12, VMCS_EXIT_CTLS, &exit_ctls);
	host64 = (exit_ctls & VM_EXIT_HOST_LMA) != 0;

	/* Control registers (fixed bits enforced the way vmx.c does). */
	vmcs12_read_field(v12, VMCS_HOST_CR0, &cr0);
	vmcs12_read_field(v12, VMCS_HOST_CR4, &cr4);
	vmx_nested_vmcs_write(vcpu, VMCS_CR0_SHADOW, cr0);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_CR0, (cr0 | vmx_cr0_ones_mask) &
	    ~vmx_cr0_zeros_mask);
	vmx_nested_vmcs_write(vcpu, VMCS_CR4_SHADOW, cr4);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_CR4, (cr4 | vmx_cr4_ones_mask) &
	    ~vmx_cr4_zeros_mask);
	vmcs12_read_field(v12, VMCS_HOST_CR3, &val);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_CR3, val);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_DR7, 0x400);

	/* EFER: from the host field when requested, else per host64. */
	if ((exit_ctls & VM_EXIT_LOAD_EFER) != 0) {
		vmcs12_read_field(v12, VMCS_HOST_IA32_EFER, &efer);
	} else {
		efer = vmx_nested_vmcs_read(vcpu, VMCS_GUEST_IA32_EFER);
		if (host64)
			efer |= EFER_LMA | EFER_LME;
		else
			efer &= ~(EFER_LMA | EFER_LME);
	}
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_IA32_EFER, efer);
	if ((exit_ctls & VM_EXIT_LOAD_PAT) != 0) {
		vmcs12_read_field(v12, VMCS_HOST_IA32_PAT, &val);
		vmx_nested_vmcs_write(vcpu, VMCS_GUEST_IA32_PAT, val);
	}

	/* RIP, RSP, RFLAGS. */
	vmcs12_read_field(v12, VMCS_HOST_RIP, &val);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_RIP, val);
	vmcs12_read_field(v12, VMCS_HOST_RSP, &val);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_RSP, val);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_RFLAGS, 0x2);	/* reserved bit 1 */

	/* Segments (SDM Table 27-x, "loading host segment state"). */
	vmcs12_read_field(v12, VMCS_HOST_CS_SELECTOR, &val);
	vmx_nested_load_host_seg(vcpu, VMCS_GUEST_CS_SELECTOR, VMCS_GUEST_CS_BASE,
	    VMCS_GUEST_CS_LIMIT, VMCS_GUEST_CS_ACCESS_RIGHTS, val, 0,
	    0xffffffff, host64 ? AR_CS_64 : AR_CS_32, false);
	vmcs12_read_field(v12, VMCS_HOST_SS_SELECTOR, &val);
	vmx_nested_load_host_seg(vcpu, VMCS_GUEST_SS_SELECTOR, VMCS_GUEST_SS_BASE,
	    VMCS_GUEST_SS_LIMIT, VMCS_GUEST_SS_ACCESS_RIGHTS, val, 0,
	    0xffffffff, AR_DATA, !host64);
	vmcs12_read_field(v12, VMCS_HOST_DS_SELECTOR, &val);
	vmx_nested_load_host_seg(vcpu, VMCS_GUEST_DS_SELECTOR, VMCS_GUEST_DS_BASE,
	    VMCS_GUEST_DS_LIMIT, VMCS_GUEST_DS_ACCESS_RIGHTS, val, 0,
	    0xffffffff, AR_DATA, true);
	vmcs12_read_field(v12, VMCS_HOST_ES_SELECTOR, &val);
	vmx_nested_load_host_seg(vcpu, VMCS_GUEST_ES_SELECTOR, VMCS_GUEST_ES_BASE,
	    VMCS_GUEST_ES_LIMIT, VMCS_GUEST_ES_ACCESS_RIGHTS, val, 0,
	    0xffffffff, AR_DATA, true);
	vmcs12_read_field(v12, VMCS_HOST_FS_SELECTOR, &val);
	vmcs12_read_field(v12, VMCS_HOST_FS_BASE, &cr0);	/* reuse */
	vmx_nested_load_host_seg(vcpu, VMCS_GUEST_FS_SELECTOR, VMCS_GUEST_FS_BASE,
	    VMCS_GUEST_FS_LIMIT, VMCS_GUEST_FS_ACCESS_RIGHTS, val, cr0,
	    0xffffffff, AR_DATA, true);
	vmcs12_read_field(v12, VMCS_HOST_GS_SELECTOR, &val);
	vmcs12_read_field(v12, VMCS_HOST_GS_BASE, &cr0);
	vmx_nested_load_host_seg(vcpu, VMCS_GUEST_GS_SELECTOR, VMCS_GUEST_GS_BASE,
	    VMCS_GUEST_GS_LIMIT, VMCS_GUEST_GS_ACCESS_RIGHTS, val, cr0,
	    0xffffffff, AR_DATA, true);
	vmcs12_read_field(v12, VMCS_HOST_TR_SELECTOR, &val);
	vmcs12_read_field(v12, VMCS_HOST_TR_BASE, &cr0);
	vmx_nested_load_host_seg(vcpu, VMCS_GUEST_TR_SELECTOR, VMCS_GUEST_TR_BASE,
	    VMCS_GUEST_TR_LIMIT, VMCS_GUEST_TR_ACCESS_RIGHTS, val, cr0,
	    0x67, AR_TR, false);
	vmx_nested_load_host_seg(vcpu, VMCS_GUEST_LDTR_SELECTOR,
	    VMCS_GUEST_LDTR_BASE, VMCS_GUEST_LDTR_LIMIT,
	    VMCS_GUEST_LDTR_ACCESS_RIGHTS, 0, 0, 0, AR_UNUSABLE, false);

	vmcs12_read_field(v12, VMCS_HOST_GDTR_BASE, &val);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_GDTR_BASE, val);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_GDTR_LIMIT, 0xffff);
	vmcs12_read_field(v12, VMCS_HOST_IDTR_BASE, &val);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_IDTR_BASE, val);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_IDTR_LIMIT, 0xffff);

	vmcs12_read_field(v12, VMCS_HOST_IA32_SYSENTER_CS, &val);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_IA32_SYSENTER_CS, val);
	vmcs12_read_field(v12, VMCS_HOST_IA32_SYSENTER_ESP, &val);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_IA32_SYSENTER_ESP, val);
	vmcs12_read_field(v12, VMCS_HOST_IA32_SYSENTER_EIP, &val);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_IA32_SYSENTER_EIP, val);

	/* Non-register state. */
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_INTERRUPTIBILITY, 0);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_ACTIVITY, 0);
	vmx_nested_vmcs_write(vcpu, VMCS_GUEST_PENDING_DBG_EXCEPTIONS, 0);

	ns->in_l2 = false;
	VMX_CTR2(vcpu, "nested: VM exit to L1 reason=%#x rip=%#lx", reason,
	    (unsigned long)vmx_nested_vmcs_read(vcpu, VMCS_GUEST_RIP));
}

/*
 * VMXON m64 (SDM Vol 3 §30.3): enter VMX operation. The region pointer
 * is validated but the region is never used by hardware; L1 runs as an
 * ordinary L0 guest throughout.
 */
int
vmx_nested_exit_vmxon(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	uint64_t gpa, cr4, cr0;
	uint32_t revision;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL) {
		vm_inject_ud(vcpu->vcpu);
		return (0);
	}
	/*
	 * Check VMXON legality against the guest's ACTUAL CR0/CR4, not the
	 * read shadow. For a nested (L2) guest, build_vmcs02() seeds vmcs02's
	 * GUEST_CR4 from vmcs12.GUEST_CR4 (which holds CR4.VMXE that L2 set),
	 * but the CR4/CR0 read-shadow fields are not updated by L2's masked
	 * CR4.VMXE write -- so reading the shadow saw no VMXE and injected a
	 * spurious #UD, blocking an L2 guest from itself hosting an L3 guest.
	 */
	cr4 = vmx_nested_vmcs_read(vcpu, VMCS_GUEST_CR4);
	cr0 = vmx_nested_vmcs_read(vcpu, VMCS_GUEST_CR0);
	if ((cr4 & CR4_VMXE) == 0) {
		vm_inject_ud(vcpu->vcpu);
		return (0);
	}
	if (vmx_nested_cpl(vcpu) != 0 || (cr0 & CR0_PE) == 0 ||
	    (cr0 & CR0_PG) == 0 || (cr0 & CR0_NE) == 0) {
		vm_inject_gp(vcpu->vcpu);
		return (0);
	}
	if (ns->vmxon) {
		vmx_nested_vmfail_valid(vcpu, VMX_INSERR_VMXON_IN_ROOT);
		return (0);
	}
	if (vmx_nested_read_m64_operand(vcpu, &gpa) != 0)
		return (0);
	if ((gpa & PAGE_MASK) != 0 || gpa >= (1ul << cpu_maxphyaddr) ||
	    vmx_nested_read_guest(vcpu, gpa, &revision, sizeof(revision)) != 0 ||
	    (revision & 0x7fffffff) != vmx_revision() ||
	    (revision & 0x80000000) != 0) {
		vmx_nested_vmfail_invalid(vcpu);
		return (0);
	}
	ns->vmxon = true;
	ns->vmxon_gpa = gpa;
	ns->vmcs12_active = false;
	ns->vmcs12_gpa = 0;
	ns->state = VMCS12_STATE_NONE;
	ns->in_l2 = false;
	vmx_nested_vmsucceed(vcpu);
	VMX_CTR1(vcpu, "nested VMXON: region=%#lx", (unsigned long)gpa);
	return (0);
}

int
vmx_nested_exit_vmxoff(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;

	if (vmx_nested_insn_check(vcpu, true) != 0)
		return (0);
	ns = vmx_nested_state(vcpu);
	vmx_nested_flush_vmcs12(vcpu);
	ns->vmxon = false;
	ns->vmxon_gpa = 0;
	ns->vmcs12_active = false;
	ns->vmcs12_gpa = 0;
	ns->state = VMCS12_STATE_NONE;
	ns->in_l2 = false;
	vmx_nested_vmsucceed(vcpu);
	VMX_CTR0(vcpu, "nested VMXOFF");
	return (0);
}

/*
 * vmm_ops.nested for VMX: emulate the VMX instruction whose exit was
 * deferred by vmx_exit_process(). Runs from vm_run() with no VMCS
 * current; every VMCS access loads/clears it (see above). The handlers
 * return 1 when they delivered a VM exit
 * to L1 (RIP already set in the VMCS) and 0 when L1 continues after the
 * instruction.
 */
int
vmx_nested_op(void *vcpui, struct vm_exit *vme)
{
	struct vmx_vcpu *vcpu = vcpui;
	int rc;

	if (vme->u.nested.op == VM_NESTED_OP_L2_EPT) {
		struct vmx_nested_state *ns = vmx_nested_state(vcpu);

		rc = vmx_nested_op_l2_ept(vcpu, vme->u.nested.info1,
		    vme->u.nested.info2);
		/*
		 * If the fault was reflected to L1, vmx_nested_vmexit_to_l1()
		 * installed L1's host RIP into vmcs01; publish it so vm_run()'s
		 * nextrip (and the next vmx_run's VMCS_GUEST_RIP write) resumes
		 * L1 at its VM-exit handler rather than re-writing L2's faulting
		 * RIP. When the page was filled (still in L2), vme->rip is
		 * ignored -- vmx_run() reads the RIP from vmcs02.
		 */
		if (!ns->in_l2)
			vme->rip = vmx_nested_vmcs_read(vcpu, VMCS_GUEST_RIP);
		return (rc);
	}
	if (vme->u.nested.op != VM_NESTED_OP_VMXINSN)
		return (EINVAL);

	switch (vme->u.nested.code) {
	case EXIT_REASON_VMXON:
		rc = vmx_nested_exit_vmxon(vcpu);
		break;
	case EXIT_REASON_VMXOFF:
		rc = vmx_nested_exit_vmxoff(vcpu);
		break;
	case EXIT_REASON_VMPTRLD:
		rc = vmx_nested_exit_vmptrld(vcpu);
		break;
	case EXIT_REASON_VMPTRST:
		rc = vmx_nested_exit_vmptrst(vcpu);
		break;
	case EXIT_REASON_VMCLEAR:
		rc = vmx_nested_exit_vmclear(vcpu);
		break;
	case EXIT_REASON_VMREAD:
		rc = vmx_nested_exit_vmread(vcpu);
		break;
	case EXIT_REASON_VMWRITE:
		rc = vmx_nested_exit_vmwrite(vcpu);
		break;
	case EXIT_REASON_VMLAUNCH:
		rc = vmx_nested_exit_vmlaunch(vcpu);
		break;
	case EXIT_REASON_VMRESUME:
		rc = vmx_nested_exit_vmresume(vcpu);
		break;
	case EXIT_REASON_VMCALL:
		rc = vmx_nested_exit_vmcall(vcpu);
		break;
	case EXIT_REASON_INVEPT:
		rc = vmx_nested_exit_invept(vcpu);
		break;
	case EXIT_REASON_INVVPID:
		rc = vmx_nested_exit_invvpid(vcpu);
		break;
	default:
		return (EINVAL);
	}
	if (rc == 1)
		vme->rip = vmx_nested_vmcs_read(vcpu, VMCS_GUEST_RIP);
	else
		vme->rip = vme->rip + vme->u.nested.info1;
	return (0);
}
