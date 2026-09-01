/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * Nested VMX support for bhyve: per-vCPU state and the entry points
 * used by vmx.c to emulate the VMX instruction set for an L1
 * hypervisor.
 */

#ifndef	_VMX_NESTED_H_
#define	_VMX_NESTED_H_

#ifdef _KERNEL

#include <sys/types.h>

struct vmx;
struct vmx_vcpu;
struct vmcs;
struct pmap;
struct vm_exit;
struct vcpu;
struct vm_guest_paging;

/*
 * Private copy of the VMCS L1 currently has loaded. The revision ID at
 * offset 0 is the only part whose position is architectural; the
 * launch state is kept in the header so VMCLEAR of a non-current VMCS
 * can update it in L1 memory without loading the whole page.
 */
struct vmcs12 {
	uint32_t	revision_id;
	uint32_t	abort_code;
	uint32_t	launch_state;
	uint32_t	_pad;
	uint8_t		data[PAGE_SIZE - 4 * sizeof(uint32_t)];
};
CTASSERT(sizeof(struct vmcs12) == PAGE_SIZE);

#define	VMCS12_CLEAR		0
#define	VMCS12_LAUNCHED		1

enum vmcs12_state {
	VMCS12_STATE_NONE = 0,	/* no current VMCS12 */
	VMCS12_STATE_CLEAR,	/* current, launch state clear */
	VMCS12_STATE_LAUNCHED,	/* current, launch state launched */
};

struct vmx_nested_state {
	bool			vmxon;		/* L1 is in VMX operation */
	uint64_t		vmxon_gpa;	/* L1's VMXON region */
	enum vmcs12_state	state;
	uint64_t		vmcs12_gpa;	/* L1 GPA of the current VMCS */
	bool			vmcs12_active;	/* a current VMCS exists */
	bool			in_l2;
	bool			l1_vmcs_current;	/* vmcs01 is deliberately loaded */		/* hardware VMCS holds L2 */
	uint64_t		ept12_pte;	/* L1 EPT root (ept12 walker) */
	/* Nested L2 execution (vmx_nested_entry.c), gated by hw.vmm.nested.vmx_l2 */
	struct vmcs		*vmcs02;	/* hardware VMCS used to run L2 */
	bool			vmcs02_launched;
	struct pmap		*ept02;		/* shadow EPT: L2 GPA -> host */
	uint64_t		ept02_eptp;
};

/* VM-instruction error numbers (SDM Vol 3 §30.4). */
#define	VMX_INSERR_VMCALL_IN_ROOT		1
#define	VMX_INSERR_VMCLEAR_INVALID_ADDR		2
#define	VMX_INSERR_VMCLEAR_VMXON_PTR		3
#define	VMX_INSERR_VMLAUNCH_NOT_CLEAR		4
#define	VMX_INSERR_VMRESUME_NOT_LAUNCHED	5
#define	VMX_INSERR_ENTRY_INVALID_CTLS		7
#define	VMX_INSERR_ENTRY_INVALID_HOST		8
#define	VMX_INSERR_VMPTRLD_INVALID_ADDR		9
#define	VMX_INSERR_VMPTRLD_VMXON_PTR		10
#define	VMX_INSERR_VMPTRLD_REVISION		11
#define	VMX_INSERR_UNSUPPORTED_FIELD		12
#define	VMX_INSERR_VMWRITE_READONLY		13
#define	VMX_INSERR_VMXON_IN_ROOT		15
#define	VMX_INSERR_ENTRY_BLOCKED_MOVSS		26
#define	VMX_INSERR_INVALID_OPERAND		28

/*
 * Per-vCPU state accessor. Returns NULL unless the VM was created with
 * nested virtualization and the host-wide gate is on.
 */
struct vmx_nested_state *vmx_nested_state(struct vmx_vcpu *vcpu);

/* vmx.c helpers shared with the nested code. */
int	vmx_cpl(void);
enum vm_cpu_mode vmx_cpu_mode(void);
void	vmx_paging_info(struct vm_guest_paging *paging);
extern uint64_t vmx_cr0_ones_mask, vmx_cr0_zeros_mask;
extern uint64_t vmx_cr4_ones_mask, vmx_cr4_zeros_mask;

/* vmx_nested_insn.c */
uint64_t vmx_nested_vmcs_read(struct vmx_vcpu *vcpu, uint32_t encoding);
void	vmx_nested_vmcs_write(struct vmx_vcpu *vcpu, uint32_t encoding,
	    uint64_t val);
int	vmx_nested_cpl(struct vmx_vcpu *vcpu);
enum vm_cpu_mode vmx_nested_cpu_mode(struct vmx_vcpu *vcpu);
uint64_t vmx_nested_get_reg(struct vmx_vcpu *vcpu, int ident);
void	vmx_nested_set_reg(struct vmx_vcpu *vcpu, int ident, uint64_t val);
int	vmx_nested_decode_mem_operand(struct vmx_vcpu *vcpu, size_t size,
	    int prot, uint64_t *gpa);
int	vmx_nested_read_m64_operand(struct vmx_vcpu *vcpu, uint64_t *val);
int	vmx_nested_read_guest(struct vmx_vcpu *vcpu, uint64_t gpa, void *buf,
	    size_t len);
int	vmx_nested_write_guest(struct vmx_vcpu *vcpu, uint64_t gpa,
	    const void *buf, size_t len);
void	vmx_nested_vmsucceed(struct vmx_vcpu *vcpu);
void	vmx_nested_vmfail_valid(struct vmx_vcpu *vcpu, uint32_t error);
void	vmx_nested_vmfail_invalid(struct vmx_vcpu *vcpu);
int	vmx_nested_insn_check(struct vmx_vcpu *vcpu, bool need_vmxon);
void	vmx_nested_flush_vmcs12(struct vmx_vcpu *vcpu);
void	vmx_nested_vmexit_to_l1(struct vmx_vcpu *vcpu, uint32_t reason,
	    uint64_t qualification);
int	vmx_nested_exit_vmxon(struct vmx_vcpu *vcpu);
int	vmx_nested_op(void *vcpui, struct vm_exit *vme);

/* vmx_nested_entry.c -- L2 execution (gated by hw.vmm.nested.vmx_l2) */
extern int vmx_nested_l2_enable;
int	vmx_nested_build_vmcs02(struct vmx_vcpu *vcpu);
void	vmx_nested_reflect_l2_exit(struct vmx_vcpu *vcpu, uint32_t reason,
	    uint64_t qual, uint64_t gpa);
int	vmx_nested_l2_exit(struct vmx_vcpu *vcpu, uint32_t reason,
	    struct vm_exit *vmexit);
int	vmx_nested_op_l2_ept(struct vmx_vcpu *vcpu, uint64_t gpa, uint64_t qual);
void	vmx_nested_reflect_copy(struct vmx_vcpu *vcpu, uint32_t reason, uint64_t qual, uint64_t gpa);
int	vmx_nested_ept02_init(struct vmx_vcpu *vcpu);
void	vmx_nested_ept02_flush(struct vmx_vcpu *vcpu);
void	vmx_nested_ept02_cleanup(struct vmx_vcpu *vcpu);
int	vmx_nested_ept02_fault(struct vmx_vcpu *vcpu, uint64_t l2_gpa,
	    uint64_t qual);
int	vmx_nested_exit_vmxoff(struct vmx_vcpu *vcpu);

/* Instruction emulation building blocks. */
int	vmx_nested_load_vmcs12(struct vmx_vcpu *vcpu, uint64_t gpa,
	    uint32_t *error);
int	vmx_nested_vmread(struct vmx_vcpu *vcpu, uint32_t encoding,
	    uint64_t *val);
int	vmx_nested_vmwrite(struct vmx_vcpu *vcpu, uint32_t encoding,
	    uint64_t val);
int	vmx_nested_vmclear_handle(struct vmx_vcpu *vcpu, uint64_t gpa,
	    uint32_t *error);
int	vmx_nested_vmlaunch_handle(struct vmx_vcpu *vcpu);
int	vmx_nested_vmresume_handle(struct vmx_vcpu *vcpu);
int	vmx_nested_vmcall_handle(struct vmx_vcpu *vcpu);
void	vmx_nested_ept12_install(struct vmx_vcpu *vcpu, uint64_t ept12_pte);
int	vmx_nested_ept12_translate(struct vmx_vcpu *vcpu, uint64_t l2_gpa,
	    int access, uint64_t *out_l1_gpa);
int	vmx_nested_invept_handle(struct vmx_vcpu *vcpu, uint64_t type,
	    uint64_t eptp);
int	vmx_nested_invvpid_handle(struct vmx_vcpu *vcpu, uint64_t type,
	    uint16_t vpid, uint64_t gla);

/*
 * VM-exit dispatch entry points (called from vmx_exit_process()).
 * Return 0 when the instruction has been emulated and L1 continues at
 * the next instruction, or 1 when a VM exit was delivered to L1 and
 * RIP has already been set. Faults into L1 are injected internally.
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
