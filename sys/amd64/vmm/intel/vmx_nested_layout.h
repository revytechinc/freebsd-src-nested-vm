/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 *
 * Shared VMCS12 field layout table for nested VMX.  The encoding
 * -> (offset, width) map is consumed by:
 *   - vmx_nested_vmread.c (VMREAD/VMWRITE against vcpu->nvmcs12)
 *   - vmx_nested_shadow.c (copy VMCS12 -> active VMCS at L2 entry)
 *
 * Extracted from vmx_nested_vmread.c so multiple compilation units
 * can share the same field table without duplicating the static
 * array.  Original BSD code.
 */

#ifndef	_VMX_NESTED_LAYOUT_H_
#define	_VMX_NESTED_LAYOUT_H_

#ifdef _KERNEL

#include <sys/types.h>

#include "vmx_nested.h"

/*
 * In-memory VMCS12 field descriptor.  Each supported encoding maps
 * to a (offset, width) pair within the 4KB VMCS12 page.  Offset is
 * relative to the start of the VMCS12 (i.e. starts at byte 0 of
 * the page).  Width is in bytes.
 *
 * The encoding map covers the L1-readable / L1-writable fields a
 * real L1 hypervisor touches first when building a guest VMCS12:
 * guest control registers, segment bases/limits/AR, RSP/RIP/RFLAGS,
 * EFER, EPT pointer, MSR bitmap, exception bitmap, VPID, pin/proc/
 * exit/entry controls.  For encodings not in this table readers
 * return -1 and the caller is expected to inject #GP into L1.
 *
 * Field widths follow the architectural field encoding:
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

extern const u_int vmcs12_fields_count;

/*
 * Look up an L1-stated VMCS12 encoding in the descriptor table.
 * Returns NULL if the encoding is unsupported (caller should
 * VMfailValid with #GP into L1).
 */
const struct vmcs12_layout *vmcs12_lookup(uint32_t encoding);

/*
 * Bulk read of a VMCS12 field into *val.  Return 0 on success, -1
 * if the encoding is unsupported or *val is NULL.  Mirrors the
 * existing in-line implementation in vmx_nested_vmread.c.
 */
int	vmcs12_read_field(const struct vmcs12 *vmcs12, uint32_t encoding,
	    uint64_t *val);

/*
 * Bulk write of a VMCS12 field from val.  Returns 0 on success,
 * -1 if the encoding is unsupported or the field is L0-owned.
 */
int	vmcs12_write_field(struct vmcs12 *vmcs12, uint32_t encoding,
	    uint64_t val);

/*
 * Index-based accessor: returns the descriptor at 'index' or
 * NULL if 'index' is out of range.  Used by the shadow apply
 * and check steps to walk the supported encodings.
 */
const struct vmcs12_layout *vmcs12_at(u_int index);

#endif	/* _KERNEL */

#endif	/* _VMX_NESTED_LAYOUT_H_ */
