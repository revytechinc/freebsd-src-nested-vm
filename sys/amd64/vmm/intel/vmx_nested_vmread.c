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

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/cpufunc.h>
#include <machine/vmm.h>

#include <dev/vmm/vmm_ktr.h>
#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_cpufunc.h"
#include "vmx_nested.h"

extern int vmm_nested_enable;

/*
 * Layout of the VMCS12 region.  The 4KB page mirrors the L1-owned
 * VMCS image exactly (per Intel SDM Vol 3 §30.4): the encoding
 * number maps to a natural-width slot inside the page.
 *
 * Encoding widths from SDM §30 (Appendix H):
 *   - 16-bit fields occupy the low 16 bits of their natural slot
 *   - 32-bit fields occupy the low 32 bits
 *   - 64-bit fields occupy all 64 bits
 *   - natural-width (64-bit on x86-64) fields occupy all 64 bits
 *
 * The VMCS12 layout below treats every encoding as a uint64_t and
 * just maps to the natural-width slot.  When the L1 writes a
 * 16/32-bit field, the upper bits are preserved (architecturally
 * the hardware ignores writes beyond the field width on a real
 * VMCS read; the same behaviour is acceptable here because L1
 * should not read fields with width-mismatched encodings).
 */
static inline uint64_t *
vmcs12_slot(struct vmcs12 *vmcs12, uint32_t encoding)
{
	uint32_t index;

	index = encoding & 0x3FFu;
	return ((uint64_t *)&vmcs12->data[index * sizeof(uint64_t)]);
}

/*
 * Wave 4 first-pass read-only allow-list.  Encodings here return
 * -1 from vmx_nested_vmwrite (caller injects #GP into L1).  For
 * the MVP everything is writable except VPID (encoding 0x0000)
 * which is L0-managed.
 */
static const uint8_t vmcs12_field_ro_default[VMCS_FIELD_BITMAP_SIZE / 8] = {
	[0] = 0x01,
};

static bool
vmcs12_field_is_writable(uint32_t encoding)
{
	u_int byte, bit;

	if (encoding >= VMCS_FIELD_BITMAP_SIZE * 8)
		return (false);
	byte = encoding / 8;
	bit = encoding % 8;
	return ((vmcs12_field_ro_default[byte] & (1u << bit)) == 0);
}

int
vmx_nested_vmread(struct vmx_vcpu *vcpu, uint32_t encoding, uint64_t *val)
{
	struct vmx_nested_state *ns;
	struct vmcs12 *vmcs12;

	if (vcpu == NULL || vcpu->nvmcs12 == NULL || val == NULL)
		return (-1);
	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);
	if (ns->vmcs12_gpa == 0)
		return (-1);

	vmcs12 = (struct vmcs12 *)vcpu->nvmcs12;
	*val = *vmcs12_slot(vmcs12, encoding);
	return (0);
}

int
vmx_nested_vmwrite(struct vmx_vcpu *vcpu, uint32_t encoding, uint64_t val)
{
	struct vmx_nested_state *ns;
	struct vmcs12 *vmcs12;

	if (vcpu == NULL || vcpu->nvmcs12 == NULL)
		return (-1);
	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);
	if (ns->vmcs12_gpa == 0)
		return (-1);

	if (!vmcs12_field_is_writable(encoding))
		return (-1);

	vmcs12 = (struct vmcs12 *)vcpu->nvmcs12;
	*vmcs12_slot(vmcs12, encoding) = val;
	vmx_nested_shadow_mark_dirty(ns, encoding);
	return (0);
}

int
vmx_nested_exit_vmread(struct vmx_vcpu *vcpu)
{
	struct vmxctx *vmxctx;
	uint64_t encoding;
	uint64_t val;
	int rc;

	vmxctx = &vcpu->ctx;
	encoding = vmxctx->guest_rcx & 0xFFFFFFFFu;
	rc = vmx_nested_vmread(vcpu, (uint32_t)encoding, &val);
	if (rc != 0)
		return (-1);

	vmxctx->guest_rdi = val;
	return (0);
}

int
vmx_nested_exit_vmwrite(struct vmx_vcpu *vcpu)
{
	struct vmxctx *vmxctx;
	uint32_t encoding;
	uint64_t val;
	int rc;

	vmxctx = &vcpu->ctx;
	encoding = vmxctx->guest_rcx & 0xFFFFFFFFu;
	val = vmxctx->guest_rdx & 0xFFFFFFFFu;

	rc = vmx_nested_vmwrite(vcpu, encoding, val);
	if (rc != 0)
		return (-1);
	return (0);
}