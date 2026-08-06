/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * T19: VMREAD/VMWRITE field-by-field handlers for nested VMX.
 * The L1 hypervisor reads/writes its VMCS12 fields directly via
 * these instructions; we translate each encoding to a load/store
 * against vcpu->nvmcs12 using a per-encoding (offset, width) table.
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
 * In-memory VMCS12 field descriptor.  Each supported encoding maps
 * to a (offset, width) pair within the 4KB VMCS12 page.  Offset is
 * relative to the start of the VMCS12 (i.e. starts at byte 0 of
 * the page).  Width is in bytes.
 *
 * The encoding map here covers the L1-readable / L1-writable fields
 * a real L1 hypervisor touches first when building a guest VMCS12:
 * guest control registers, segment bases/limits/AR, RSP/RIP/RFLAGS,
 * EFER, EPT pointer, MSR bitmap, exception bitmap, VPID, pin/proc/
 * exit/entry controls.  For encodings not in this table, vmx_nested_
 * vmread/vmwrite return -1 and the caller injects #GP into L1, which
 * is the architecturally-correct VMfailValid response.
 *
 * Field widths follow SDM Vol 3 §30.4 (Appendix B):
 *   - 16-bit fields  -> 2 bytes (packed, low bits of the 4-byte slot)
 *   - 32-bit fields  -> 4 bytes
 *   - 64-bit / natural-width fields on x86-64 -> 8 bytes
 */
struct vmcs12_layout {
	uint32_t	encoding;
	uint16_t	offset;
	uint8_t		width;
	uint8_t		flags;
};

/*
 * Bit flags for vmcs12_layout.flags.  VMCS12_F_READONLY means the
 * field is L0-owned (e.g. VPID): VMWRITE returns -1, VMREAD returns
 * the L0 value via vmx->vm state.
 */
#define	VMCS12_F_READONLY	0x01

#define	VMCS_W_16	2
#define	VMCS_W_32	4
#define	VMCS_W_64	8

static const struct vmcs12_layout vmcs12_fields[] = {
	/* 16-bit control fields (subset, common to L1) */
	{ VMCS_VPID,			0x0000, VMCS_W_16, VMCS12_F_READONLY },
	{ VMCS_GUEST_ES_SELECTOR,	0x0002, VMCS_W_16, 0 },
	{ VMCS_GUEST_CS_SELECTOR,	0x0004, VMCS_W_16, 0 },
	{ VMCS_GUEST_SS_SELECTOR,	0x0006, VMCS_W_16, 0 },
	{ VMCS_GUEST_DS_SELECTOR,	0x0008, VMCS_W_16, 0 },
	{ VMCS_GUEST_FS_SELECTOR,	0x000A, VMCS_W_16, 0 },
	{ VMCS_GUEST_GS_SELECTOR,	0x000C, VMCS_W_16, 0 },
	{ VMCS_GUEST_LDTR_SELECTOR,	0x000E, VMCS_W_16, 0 },
	{ VMCS_GUEST_TR_SELECTOR,	0x0010, VMCS_W_16, 0 },
	{ VMCS_GUEST_INTERRUPTIBILITY,	0x0012, VMCS_W_16, 0 },

	/* 16-bit guest-state fields (segment AR fields, etc.) */
	{ VMCS_GUEST_ES_LIMIT,		0x0014, VMCS_W_16, 0 },
	{ VMCS_GUEST_CS_LIMIT,		0x0016, VMCS_W_16, 0 },
	{ VMCS_GUEST_SS_LIMIT,		0x0018, VMCS_W_16, 0 },
	{ VMCS_GUEST_DS_LIMIT,		0x001A, VMCS_W_16, 0 },
	{ VMCS_GUEST_FS_LIMIT,		0x001C, VMCS_W_16, 0 },
	{ VMCS_GUEST_GS_LIMIT,		0x001E, VMCS_W_16, 0 },
	{ VMCS_GUEST_LDTR_LIMIT,	0x0020, VMCS_W_16, 0 },
	{ VMCS_GUEST_TR_LIMIT,		0x0022, VMCS_W_16, 0 },
	{ VMCS_GUEST_GDTR_LIMIT,	0x0024, VMCS_W_16, 0 },
	{ VMCS_GUEST_IDTR_LIMIT,	0x0026, VMCS_W_16, 0 },
	{ VMCS_GUEST_ES_ACCESS_RIGHTS,	0x0028, VMCS_W_16, 0 },
	{ VMCS_GUEST_CS_ACCESS_RIGHTS,	0x002A, VMCS_W_16, 0 },
	{ VMCS_GUEST_SS_ACCESS_RIGHTS,	0x002C, VMCS_W_16, 0 },
	{ VMCS_GUEST_DS_ACCESS_RIGHTS,	0x002E, VMCS_W_16, 0 },
	{ VMCS_GUEST_FS_ACCESS_RIGHTS,	0x0030, VMCS_W_16, 0 },
	{ VMCS_GUEST_GS_ACCESS_RIGHTS,	0x0032, VMCS_W_16, 0 },
	{ VMCS_GUEST_LDTR_ACCESS_RIGHTS,0x0034, VMCS_W_16, 0 },
	{ VMCS_GUEST_TR_ACCESS_RIGHTS,	0x0036, VMCS_W_16, 0 },
	{ VMCS_GUEST_IA32_SYSENTER_CS,	0x0038, VMCS_W_16, 0 },

	/* 32-bit control fields */
	{ VMCS_PIN_BASED_CTLS,		0x003A, VMCS_W_32, 0 },
	{ VMCS_PRI_PROC_BASED_CTLS,	0x003E, VMCS_W_32, 0 },
	{ VMCS_EXCEPTION_BITMAP,	0x0042, VMCS_W_32, 0 },
	{ VMCS_PF_ERROR_MASK,		0x0046, VMCS_W_32, 0 },
	{ VMCS_PF_ERROR_MATCH,		0x004A, VMCS_W_32, 0 },
	{ VMCS_EXIT_CTLS,		0x004E, VMCS_W_32, 0 },
	{ VMCS_EXIT_MSR_STORE_COUNT,	0x0052, VMCS_W_32, 0 },
	{ VMCS_EXIT_MSR_LOAD_COUNT,	0x0056, VMCS_W_32, 0 },
	{ VMCS_ENTRY_CTLS,		0x005A, VMCS_W_32, 0 },
	{ VMCS_ENTRY_MSR_LOAD_COUNT,	0x005E, VMCS_W_32, 0 },
	{ VMCS_ENTRY_INTR_INFO,		0x0062, VMCS_W_32, 0 },
	{ VMCS_ENTRY_EXCEPTION_ERROR,	0x0066, VMCS_W_32, 0 },
	{ VMCS_ENTRY_INST_LENGTH,	0x006A, VMCS_W_32, 0 },

	/* 32-bit guest-state fields beyond the 16-bit segment ones */
	{ VMCS_GUEST_SMBASE,		0x006E, VMCS_W_32, 0 },
	{ VMCS_PREEMPTION_TIMER_VALUE,	0x0072, VMCS_W_32, 0 },

	/* 64-bit control fields */
	{ VMCS_IO_BITMAP_A,		0x0076, VMCS_W_64, 0 },
	{ VMCS_IO_BITMAP_B,		0x007E, VMCS_W_64, 0 },
	{ VMCS_MSR_BITMAP,		0x0086, VMCS_W_64, 0 },
	{ VMCS_EXIT_MSR_STORE,		0x008E, VMCS_W_64, 0 },
	{ VMCS_EXIT_MSR_LOAD,		0x0096, VMCS_W_64, 0 },
	{ VMCS_ENTRY_MSR_LOAD,		0x009E, VMCS_W_64, 0 },
	{ VMCS_TSC_OFFSET,		0x00A6, VMCS_W_64, 0 },
	{ VMCS_VIRTUAL_APIC,		0x00AE, VMCS_W_64, 0 },
	{ VMCS_APIC_ACCESS,		0x00B6, VMCS_W_64, 0 },
	{ VMCS_EPTP,			0x00BE, VMCS_W_64, 0 },
	{ VMCS_GUEST_IA32_DEBUGCTL,	0x00C6, VMCS_W_64, 0 },
	{ VMCS_GUEST_IA32_PAT,		0x00CE, VMCS_W_64, 0 },
	{ VMCS_GUEST_IA32_EFER,		0x00D6, VMCS_W_64, 0 },
	{ VMCS_GUEST_PDPTE0,		0x00DE, VMCS_W_64, 0 },
	{ VMCS_GUEST_PDPTE1,		0x00E6, VMCS_W_64, 0 },
	{ VMCS_GUEST_PDPTE2,		0x00EE, VMCS_W_64, 0 },
	{ VMCS_GUEST_PDPTE3,		0x00F6, VMCS_W_64, 0 },

	/* Natural-width control fields */
	{ VMCS_CR0_MASK,		0x00FE, VMCS_W_64, 0 },
	{ VMCS_CR4_MASK,		0x0106, VMCS_W_64, 0 },
	{ VMCS_CR0_SHADOW,		0x010E, VMCS_W_64, 0 },
	{ VMCS_CR4_SHADOW,		0x0116, VMCS_W_64, 0 },
	{ VMCS_CR3_TARGET0,		0x011E, VMCS_W_64, 0 },
	{ VMCS_CR3_TARGET1,		0x0126, VMCS_W_64, 0 },
	{ VMCS_CR3_TARGET2,		0x012E, VMCS_W_64, 0 },
	{ VMCS_CR3_TARGET3,		0x0136, VMCS_W_64, 0 },

	/* Natural-width guest-state fields */
	{ VMCS_GUEST_CR0,		0x013E, VMCS_W_64, 0 },
	{ VMCS_GUEST_CR3,		0x0146, VMCS_W_64, 0 },
	{ VMCS_GUEST_CR4,		0x014E, VMCS_W_64, 0 },
	{ VMCS_GUEST_ES_BASE,		0x0156, VMCS_W_64, 0 },
	{ VMCS_GUEST_CS_BASE,		0x015E, VMCS_W_64, 0 },
	{ VMCS_GUEST_SS_BASE,		0x0166, VMCS_W_64, 0 },
	{ VMCS_GUEST_DS_BASE,		0x016E, VMCS_W_64, 0 },
	{ VMCS_GUEST_FS_BASE,		0x0176, VMCS_W_64, 0 },
	{ VMCS_GUEST_GS_BASE,		0x017E, VMCS_W_64, 0 },
	{ VMCS_GUEST_LDTR_BASE,		0x0186, VMCS_W_64, 0 },
	{ VMCS_GUEST_TR_BASE,		0x018E, VMCS_W_64, 0 },
	{ VMCS_GUEST_GDTR_BASE,		0x0196, VMCS_W_64, 0 },
	{ VMCS_GUEST_IDTR_BASE,		0x019E, VMCS_W_64, 0 },
	{ VMCS_GUEST_DR7,		0x01A6, VMCS_W_64, 0 },
	{ VMCS_GUEST_RSP,		0x01AE, VMCS_W_64, 0 },
	{ VMCS_GUEST_RIP,		0x01B6, VMCS_W_64, 0 },
	{ VMCS_GUEST_RFLAGS,		0x01BE, VMCS_W_64, 0 },
	{ VMCS_GUEST_PENDING_DBG_EXCEPTIONS, 0x01C6, VMCS_W_64, 0 },
	{ VMCS_GUEST_IA32_SYSENTER_ESP,	0x01CE, VMCS_W_64, 0 },
	{ VMCS_GUEST_IA32_SYSENTER_EIP,	0x01D6, VMCS_W_64, 0 },
};

#define	VMCS12_FIELDS_COUNT	nitems(vmcs12_fields)

/*
 * Look up an L1-stated VMCS12 encoding in the descriptor table.
 * Returns NULL if the encoding is unsupported (caller should
 * VMfailValid with #GP into L1).
 */
static const struct vmcs12_layout *
vmcs12_lookup(uint32_t encoding)
{
	u_int i;

	for (i = 0; i < VMCS12_FIELDS_COUNT; i++) {
		if (vmcs12_fields[i].encoding == encoding)
			return (&vmcs12_fields[i]);
	}
	return (NULL);
}

int
vmx_nested_vmread(struct vmx_vcpu *vcpu, uint32_t encoding, uint64_t *val)
{
	struct vmx_nested_state *ns;
	struct vmcs12 *vmcs12;
	const struct vmcs12_layout *f;

	if (vcpu == NULL || vcpu->nvmcs12 == NULL || val == NULL)
		return (-1);
	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);
	if (ns->vmcs12_gpa == 0)
		return (-1);

	f = vmcs12_lookup(encoding);
	if (f == NULL)
		return (-1);

	vmcs12 = (struct vmcs12 *)vcpu->nvmcs12;

	/*
	 * Read up to 8 bytes little-endian.  All supported widths
	 * are 2/4/8 bytes, so a single memcpy + zero-extend is
	 * sufficient.
	 */
	switch (f->width) {
	case VMCS_W_16: {
		uint16_t v16;
		memcpy(&v16, (uint8_t *)vmcs12 + f->offset, sizeof(v16));
		*val = v16;
		break;
	}
	case VMCS_W_32: {
		uint32_t v32;
		memcpy(&v32, (uint8_t *)vmcs12 + f->offset, sizeof(v32));
		*val = v32;
		break;
	}
	case VMCS_W_64: {
		uint64_t v64;
		memcpy(&v64, (uint8_t *)vmcs12 + f->offset, sizeof(v64));
		*val = v64;
		break;
	}
	default:
		return (-1);
	}
	return (0);
}

int
vmx_nested_vmwrite(struct vmx_vcpu *vcpu, uint32_t encoding, uint64_t val)
{
	struct vmx_nested_state *ns;
	struct vmcs12 *vmcs12;
	const struct vmcs12_layout *f;

	if (vcpu == NULL || vcpu->nvmcs12 == NULL)
		return (-1);
	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);
	if (ns->vmcs12_gpa == 0)
		return (-1);

	f = vmcs12_lookup(encoding);
	if (f == NULL)
		return (-1);

	if ((f->flags & VMCS12_F_READONLY) != 0)
		return (-1);

	vmcs12 = (struct vmcs12 *)vcpu->nvmcs12;

	switch (f->width) {
	case VMCS_W_16: {
		uint16_t v16 = (uint16_t)val;
		memcpy((uint8_t *)vmcs12 + f->offset, &v16, sizeof(v16));
		break;
	}
	case VMCS_W_32: {
		uint32_t v32 = (uint32_t)val;
		memcpy((uint8_t *)vmcs12 + f->offset, &v32, sizeof(v32));
		break;
	}
	case VMCS_W_64: {
		uint64_t v64 = val;
		memcpy((uint8_t *)vmcs12 + f->offset, &v64, sizeof(v64));
		break;
	}
	default:
		return (-1);
	}
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
	/*
	 * VMWRITE takes a 64-bit source operand in RDX (Intel SDM
	 * §30.3 / §31.6).  The previous implementation truncated to
	 * 32 bits which silently corrupted natural-width fields.
	 */
	val = vmxctx->guest_rdx;

	rc = vmx_nested_vmwrite(vcpu, encoding, val);
	if (rc != 0)
		return (-1);
	return (0);
}
