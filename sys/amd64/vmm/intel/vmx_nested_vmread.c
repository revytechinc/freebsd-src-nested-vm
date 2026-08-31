/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * VMREAD / VMWRITE emulation for nested VMX (SDM Vol 3 §30.3), against
 * the private VMCS12 copy. Operands are decoded from the VM-exit
 * instruction-information field: the field encoding is always in the
 * register named by bits 31:28, the value in the register named by
 * bits 6:3 or in memory when bit 10 is clear.
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
#include "vmx_nested_layout.h"

int
vmx_nested_vmread(struct vmx_vcpu *vcpu, uint32_t encoding, uint64_t *val)
{

	if (vcpu->nvmcs12 == NULL)
		return (-1);
	return (vmcs12_read_field(vcpu->nvmcs12, encoding, val));
}

int
vmx_nested_vmwrite(struct vmx_vcpu *vcpu, uint32_t encoding, uint64_t val)
{
	const struct vmcs12_layout *f;

	if (vcpu->nvmcs12 == NULL)
		return (-1);
	f = vmcs12_lookup(encoding);
	if (f == NULL)
		return (-1);
	if ((f->flags & VMCS12_F_READONLY) != 0)
		return (-2);
	return (vmcs12_write_field(vcpu->nvmcs12, encoding, val));
}

static size_t
vmx_nested_operand_size(struct vmx_vcpu *vcpu)
{

	return (vmx_nested_cpu_mode(vcpu) == CPU_MODE_64BIT ? 8 : 4);
}

int
vmx_nested_exit_vmread(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	uint64_t info, encoding, val, gpa;
	size_t size;

	if (vmx_nested_insn_check(vcpu, true) != 0)
		return (0);
	ns = vmx_nested_state(vcpu);
	if (!ns->vmcs12_active) {
		vmx_nested_vmfail_invalid(vcpu);
		return (0);
	}

	info = vmx_nested_vmcs_read(vcpu, VMCS_EXIT_INSTRUCTION_INFO);
	encoding = vmx_nested_get_reg(vcpu, (info >> 28) & 0xf);
	if (vmx_nested_vmread(vcpu, (uint32_t)encoding, &val) != 0) {
		vmx_nested_vmfail_valid(vcpu, VMX_INSERR_UNSUPPORTED_FIELD);
		return (0);
	}

	size = vmx_nested_operand_size(vcpu);
	if (size == 4)
		val &= 0xffffffff;
	if (((info >> 10) & 1) != 0) {
		vmx_nested_set_reg(vcpu, (info >> 3) & 0xf, val);
	} else {
		if (vmx_nested_decode_mem_operand(vcpu, size, VM_PROT_WRITE,
		    &gpa) != 0)
			return (0);
		if (vmx_nested_write_guest(vcpu, gpa, &val, size) != 0) {
			vm_inject_gp(vcpu->vcpu);
			return (0);
		}
	}
	vmx_nested_vmsucceed(vcpu);
	return (0);
}

int
vmx_nested_exit_vmwrite(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	uint64_t info, encoding, val, gpa;
	size_t size;
	int rc;

	if (vmx_nested_insn_check(vcpu, true) != 0)
		return (0);
	ns = vmx_nested_state(vcpu);
	if (!ns->vmcs12_active) {
		vmx_nested_vmfail_invalid(vcpu);
		return (0);
	}

	info = vmx_nested_vmcs_read(vcpu, VMCS_EXIT_INSTRUCTION_INFO);
	encoding = vmx_nested_get_reg(vcpu, (info >> 28) & 0xf);
	size = vmx_nested_operand_size(vcpu);
	val = 0;
	if (((info >> 10) & 1) != 0) {
		val = vmx_nested_get_reg(vcpu, (info >> 3) & 0xf);
	} else {
		if (vmx_nested_decode_mem_operand(vcpu, size, VM_PROT_READ,
		    &gpa) != 0)
			return (0);
		if (vmx_nested_read_guest(vcpu, gpa, &val, size) != 0) {
			vm_inject_gp(vcpu->vcpu);
			return (0);
		}
	}
	if (size == 4)
		val &= 0xffffffff;

	rc = vmx_nested_vmwrite(vcpu, (uint32_t)encoding, val);
	if (rc == -2)
		vmx_nested_vmfail_valid(vcpu, VMX_INSERR_VMWRITE_READONLY);
	else if (rc != 0)
		vmx_nested_vmfail_valid(vcpu, VMX_INSERR_UNSUPPORTED_FIELD);
	else
		vmx_nested_vmsucceed(vcpu);
	return (0);
}
