/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 *
 * VMCS12 field layout.
 *
 * L1's VMCS is never interpreted in place: VMPTRLD copies the page
 * into a private per-vCPU buffer (struct vmcs12) and VMREAD/VMWRITE
 * are emulated against that buffer using the table below, so the
 * offsets are our own and only the revision ID at offset 0 has to
 * match what L1 wrote. Every field an L1 hypervisor may legitimately
 * access has a slot; fields in the read-only VM-exit information
 * class (encoding bits 11:10 == 01) reject VMWRITE
 * with VM-instruction error 13.
 *
 * Original BSD code.
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/vmm.h>

#include "vmx_cpufunc.h"
#include "vmcs.h"
#include "vmx_nested.h"
#include "vmx_nested_layout.h"

#define	F16(enc)	{ (enc), 0, VMCS_W_16, 0 }
#define	F32(enc)	{ (enc), 0, VMCS_W_32, 0 }
#define	F64(enc)	{ (enc), 0, VMCS_W_64, 0 }
#define	RO32(enc)	{ (enc), 0, VMCS_W_32, VMCS12_F_READONLY }
#define	RO64(enc)	{ (enc), 0, VMCS_W_64, VMCS12_F_READONLY }

/*
 * Offsets are assigned on first use by vmcs12_layout_init() so the
 * table stays readable; the struct vmcs12 header (revision, abort,
 * launch state) occupies the first 16 bytes.
 */
static struct vmcs12_layout vmcs12_fields_table[] = {
	/* 16-bit control fields */
	F16(VMCS_VPID),
	F16(VMCS_PIR_VECTOR),
	/* 16-bit guest state */
	F16(VMCS_GUEST_ES_SELECTOR),
	F16(VMCS_GUEST_CS_SELECTOR),
	F16(VMCS_GUEST_SS_SELECTOR),
	F16(VMCS_GUEST_DS_SELECTOR),
	F16(VMCS_GUEST_FS_SELECTOR),
	F16(VMCS_GUEST_GS_SELECTOR),
	F16(VMCS_GUEST_LDTR_SELECTOR),
	F16(VMCS_GUEST_TR_SELECTOR),
	F16(VMCS_GUEST_INTR_STATUS),
	/* 16-bit host state */
	F16(VMCS_HOST_ES_SELECTOR),
	F16(VMCS_HOST_CS_SELECTOR),
	F16(VMCS_HOST_SS_SELECTOR),
	F16(VMCS_HOST_DS_SELECTOR),
	F16(VMCS_HOST_FS_SELECTOR),
	F16(VMCS_HOST_GS_SELECTOR),
	F16(VMCS_HOST_TR_SELECTOR),
	/* 64-bit control fields */
	F64(VMCS_IO_BITMAP_A),
	F64(VMCS_IO_BITMAP_B),
	F64(VMCS_MSR_BITMAP),
	F64(VMCS_EXIT_MSR_STORE),
	F64(VMCS_EXIT_MSR_LOAD),
	F64(VMCS_ENTRY_MSR_LOAD),
	F64(VMCS_EXECUTIVE_VMCS),
	F64(VMCS_TSC_OFFSET),
	F64(VMCS_VIRTUAL_APIC),
	F64(VMCS_APIC_ACCESS),
	F64(VMCS_PIR_DESC),
	F64(VMCS_EPTP),
	F64(VMCS_EOI_EXIT0),
	F64(VMCS_EOI_EXIT1),
	F64(VMCS_EOI_EXIT2),
	F64(VMCS_EOI_EXIT3),
	/* 64-bit read-only data */
	RO64(VMCS_GUEST_PHYSICAL_ADDRESS),
	/* 64-bit guest state */
	F64(VMCS_LINK_POINTER),
	F64(VMCS_GUEST_IA32_DEBUGCTL),
	F64(VMCS_GUEST_IA32_PAT),
	F64(VMCS_GUEST_IA32_EFER),
	F64(VMCS_GUEST_IA32_PERF_GLOBAL_CTRL),
	F64(VMCS_GUEST_PDPTE0),
	F64(VMCS_GUEST_PDPTE1),
	F64(VMCS_GUEST_PDPTE2),
	F64(VMCS_GUEST_PDPTE3),
	/* 64-bit host state */
	F64(VMCS_HOST_IA32_PAT),
	F64(VMCS_HOST_IA32_EFER),
	F64(VMCS_HOST_IA32_PERF_GLOBAL_CTRL),
	/* 32-bit control fields */
	F32(VMCS_PIN_BASED_CTLS),
	F32(VMCS_PRI_PROC_BASED_CTLS),
	F32(VMCS_EXCEPTION_BITMAP),
	F32(VMCS_PF_ERROR_MASK),
	F32(VMCS_PF_ERROR_MATCH),
	F32(VMCS_CR3_TARGET_COUNT),
	F32(VMCS_EXIT_CTLS),
	F32(VMCS_EXIT_MSR_STORE_COUNT),
	F32(VMCS_EXIT_MSR_LOAD_COUNT),
	F32(VMCS_ENTRY_CTLS),
	F32(VMCS_ENTRY_MSR_LOAD_COUNT),
	F32(VMCS_ENTRY_INTR_INFO),
	F32(VMCS_ENTRY_EXCEPTION_ERROR),
	F32(VMCS_ENTRY_INST_LENGTH),
	F32(VMCS_TPR_THRESHOLD),
	F32(VMCS_SEC_PROC_BASED_CTLS),
	F32(VMCS_PLE_GAP),
	F32(VMCS_PLE_WINDOW),
	/* 32-bit read-only data */
	RO32(VMCS_INSTRUCTION_ERROR),
	RO32(VMCS_EXIT_REASON),
	RO32(VMCS_EXIT_INTR_INFO),
	RO32(VMCS_EXIT_INTR_ERRCODE),
	RO32(VMCS_IDT_VECTORING_INFO),
	RO32(VMCS_IDT_VECTORING_ERROR),
	RO32(VMCS_EXIT_INSTRUCTION_LENGTH),
	RO32(VMCS_EXIT_INSTRUCTION_INFO),
	/* 32-bit guest state */
	F32(VMCS_GUEST_ES_LIMIT),
	F32(VMCS_GUEST_CS_LIMIT),
	F32(VMCS_GUEST_SS_LIMIT),
	F32(VMCS_GUEST_DS_LIMIT),
	F32(VMCS_GUEST_FS_LIMIT),
	F32(VMCS_GUEST_GS_LIMIT),
	F32(VMCS_GUEST_LDTR_LIMIT),
	F32(VMCS_GUEST_TR_LIMIT),
	F32(VMCS_GUEST_GDTR_LIMIT),
	F32(VMCS_GUEST_IDTR_LIMIT),
	F32(VMCS_GUEST_ES_ACCESS_RIGHTS),
	F32(VMCS_GUEST_CS_ACCESS_RIGHTS),
	F32(VMCS_GUEST_SS_ACCESS_RIGHTS),
	F32(VMCS_GUEST_DS_ACCESS_RIGHTS),
	F32(VMCS_GUEST_FS_ACCESS_RIGHTS),
	F32(VMCS_GUEST_GS_ACCESS_RIGHTS),
	F32(VMCS_GUEST_LDTR_ACCESS_RIGHTS),
	F32(VMCS_GUEST_TR_ACCESS_RIGHTS),
	F32(VMCS_GUEST_INTERRUPTIBILITY),
	F32(VMCS_GUEST_ACTIVITY),
	F32(VMCS_GUEST_SMBASE),
	F32(VMCS_GUEST_IA32_SYSENTER_CS),
	F32(VMCS_PREEMPTION_TIMER_VALUE),
	/* 32-bit host state */
	F32(VMCS_HOST_IA32_SYSENTER_CS),
	/* natural-width control fields */
	F64(VMCS_CR0_MASK),
	F64(VMCS_CR4_MASK),
	F64(VMCS_CR0_SHADOW),
	F64(VMCS_CR4_SHADOW),
	F64(VMCS_CR3_TARGET0),
	F64(VMCS_CR3_TARGET1),
	F64(VMCS_CR3_TARGET2),
	F64(VMCS_CR3_TARGET3),
	/* natural-width read-only data */
	RO64(VMCS_EXIT_QUALIFICATION),
	RO64(VMCS_IO_RCX),
	RO64(VMCS_IO_RSI),
	RO64(VMCS_IO_RDI),
	RO64(VMCS_IO_RIP),
	RO64(VMCS_GUEST_LINEAR_ADDRESS),
	/* natural-width guest state */
	F64(VMCS_GUEST_CR0),
	F64(VMCS_GUEST_CR3),
	F64(VMCS_GUEST_CR4),
	F64(VMCS_GUEST_ES_BASE),
	F64(VMCS_GUEST_CS_BASE),
	F64(VMCS_GUEST_SS_BASE),
	F64(VMCS_GUEST_DS_BASE),
	F64(VMCS_GUEST_FS_BASE),
	F64(VMCS_GUEST_GS_BASE),
	F64(VMCS_GUEST_LDTR_BASE),
	F64(VMCS_GUEST_TR_BASE),
	F64(VMCS_GUEST_GDTR_BASE),
	F64(VMCS_GUEST_IDTR_BASE),
	F64(VMCS_GUEST_DR7),
	F64(VMCS_GUEST_RSP),
	F64(VMCS_GUEST_RIP),
	F64(VMCS_GUEST_RFLAGS),
	F64(VMCS_GUEST_PENDING_DBG_EXCEPTIONS),
	F64(VMCS_GUEST_IA32_SYSENTER_ESP),
	F64(VMCS_GUEST_IA32_SYSENTER_EIP),
	/* natural-width host state */
	F64(VMCS_HOST_CR0),
	F64(VMCS_HOST_CR3),
	F64(VMCS_HOST_CR4),
	F64(VMCS_HOST_FS_BASE),
	F64(VMCS_HOST_GS_BASE),
	F64(VMCS_HOST_TR_BASE),
	F64(VMCS_HOST_GDTR_BASE),
	F64(VMCS_HOST_IDTR_BASE),
	F64(VMCS_HOST_IA32_SYSENTER_ESP),
	F64(VMCS_HOST_IA32_SYSENTER_EIP),
	F64(VMCS_HOST_RSP),
	F64(VMCS_HOST_RIP),
};

const u_int vmcs12_fields_count = nitems(vmcs12_fields_table);

static bool vmcs12_layout_ready;

/*
 * Lay the fields out back to back after the struct vmcs12 header,
 * naturally aligned. Idempotent; called from every lookup so no explicit init
 * ordering is needed.
 */
static void
vmcs12_layout_init(void)
{
	u_int i, off;

	if (vmcs12_layout_ready)
		return;
	off = offsetof(struct vmcs12, data);
	for (i = 0; i < vmcs12_fields_count; i++) {
		struct vmcs12_layout *f = &vmcs12_fields_table[i];

		off = roundup2(off, f->width);
		f->offset = off;
		off += f->width;
	}
	KASSERT(off <= PAGE_SIZE, ("vmcs12 layout overflows a page: %u", off));
	vmcs12_layout_ready = true;
}

const struct vmcs12_layout *
vmcs12_lookup(uint32_t encoding)
{
	u_int i;

	vmcs12_layout_init();
	for (i = 0; i < vmcs12_fields_count; i++) {
		if (vmcs12_fields_table[i].encoding == encoding)
			return (&vmcs12_fields_table[i]);
	}
	return (NULL);
}

const struct vmcs12_layout *
vmcs12_at(u_int index)
{

	vmcs12_layout_init();
	if (index >= vmcs12_fields_count)
		return (NULL);
	return (&vmcs12_fields_table[index]);
}

int
vmcs12_read_field(const struct vmcs12 *vmcs12, uint32_t encoding,
    uint64_t *val)
{
	const struct vmcs12_layout *f;

	if (vmcs12 == NULL || val == NULL)
		return (-1);
	f = vmcs12_lookup(encoding);
	if (f == NULL)
		return (-1);

	switch (f->width) {
	case VMCS_W_16: {
		uint16_t v16;
		memcpy(&v16, (const uint8_t *)vmcs12 + f->offset, sizeof(v16));
		*val = v16;
		break;
	}
	case VMCS_W_32: {
		uint32_t v32;
		memcpy(&v32, (const uint8_t *)vmcs12 + f->offset, sizeof(v32));
		*val = v32;
		break;
	}
	case VMCS_W_64: {
		uint64_t v64;
		memcpy(&v64, (const uint8_t *)vmcs12 + f->offset, sizeof(v64));
		*val = v64;
		break;
	}
	default:
		return (-1);
	}
	return (0);
}

/*
 * L0-side write: used both for VMWRITE emulation (which checks the
 * read-only flag itself) and for filling in exit information, so it
 * does not reject read-only fields.
 */
int
vmcs12_write_field(struct vmcs12 *vmcs12, uint32_t encoding, uint64_t val)
{
	const struct vmcs12_layout *f;

	if (vmcs12 == NULL)
		return (-1);
	f = vmcs12_lookup(encoding);
	if (f == NULL)
		return (-1);

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
	return (0);
}
