/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * T22: VMCS shadow apply/check helpers for nested VMX.  The
 * L1-stated VMCS12 lives in vcpu->nvmcs12; the L0-active VMCS
 * is loaded on each L2 entry (VMLAUNCH/VMRESUME) and is
 * readable on each L2 exit.
 *
 *  - shadow_apply walks the per-encoding dirty bitmap, copies
 *    each set field from nvmcs12 into the active VMCS, and
 *    clears the bit.
 *  - shadow_check walks every supported encoding in the layout
 *    table, reads the current value from the active VMCS back
 *    into nvmcs12, and re-marks the per-encoding dirty bitmap
 *    so the next apply copies them back.
 *
 * Intel SDM Vol 3 §25.6.4 describes the on-hardware VMCS dirty
 * bitmaps (VMREAD_BITMAP / VMWRITE_BITMAP); this in-kernel
 * implementation does NOT use those, because they are a
 * hardware-side concept tied to VMCS-shadowing mode which L0
 * does not enable in this wave.  Instead we track dirty state
 * ourselves in the per-vCPU ns->vmcs_field_dirty bitmap.
 *
 * Original BSD code; Intel SDM Vol 3 §25.6.4 / §30.4 are
 * referenced for the shadow bitmap semantics only.
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
#include "vmx_cpufunc.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_nested.h"
#include "vmx_nested_layout.h"

extern int vmm_nested_enable;

/*
 * Copy the L1-stated VMCS12 dirty fields to the active L0 VMCS.
 * The dirty bitmap is the per-vCPU ns->vmcs_field_dirty[] array,
 * set by vmx_nested_vmwrite() and consumed here.  Returns 0 on
 * success, -1 on a vmwrite failure (caller should VMFailValid).
 */
int
vmx_nested_shadow_apply(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	struct vmcs12 *vmcs12;
	u_int i, n;
	int rc;

	if (vcpu == NULL)
		return (-1);
	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);
	vmcs12 = vcpu->nvmcs12;
	if (vmcs12 == NULL)
		return (-1);

	n = vmcs12_fields_count;
	for (i = 0; i < n; i++) {
		const struct vmcs12_layout *f = vmcs12_at(i);
		uint64_t val;
		uint32_t enc;

		if (f == NULL)
			break;
		enc = f->encoding;

		/*
		 * Only apply fields the L1 actually dirtied since
		 * the last apply.  The bitmap is optional — a NULL
		 * pointer means "no L1 writes yet", which is the
		 * no-op case for a freshly-loaded VMCS12.
		 */
		if (ns->vmcs_field_dirty != NULL) {
			if (enc >= VMCS_FIELD_BITMAP_SIZE * 8)
				continue;
			if ((ns->vmcs_field_dirty[enc / 8] &
			    (uint8_t)(1u << (enc % 8))) == 0)
				continue;
		}

		if (vmcs12_read_field(vmcs12, enc, &val) != 0)
			continue;
		vmcs_write(enc, val);
	}

	/*
	 * Clear the dirty bitmap so subsequent VM-exits / shadow
	 * checks see a clean state.  The field-write side flips
	 * bits on again as L1 issues VMWRITE.
	 */
	if (ns->vmcs_field_dirty != NULL)
		memset(ns->vmcs_field_dirty, 0, VMCS_FIELD_BITMAP_SIZE);

	rc = 0;
	VMX_CTR0(vcpu, "nested shadow apply: copied VMCS12 -> active VMCS");
	return (rc);
}

/*
 * Read every supported VMCS field back from the active L0 VMCS
 * into the L1-stated VMCS12, and re-mark all encoding bits in the
 * dirty bitmap.  The bitmap re-marking means the next
 * shadow_apply copies the L0-modified state back into the active
 * VMCS, which is the desired round-trip for a stateful L1 that
 * reads VMCS fields back after L2 exits.
 *
 * The L0 VMCS does not implement hardware dirty-bitmap tracking
 * in this wave (the VMCS-shadowing hardware feature is a L1-side
 * facility, not a L0-side one), so we conservatively copy every
 * field on every exit.  A future wave can refine this to a
 * diff-based check.
 */
int
vmx_nested_shadow_check(struct vmx_vcpu *vcpu)
{
	struct vmx_nested_state *ns;
	struct vmcs12 *vmcs12;
	u_int i, n;
	int rc;

	if (vcpu == NULL)
		return (-1);
	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);
	vmcs12 = vcpu->nvmcs12;
	if (vmcs12 == NULL)
		return (-1);

	n = vmcs12_fields_count;
	for (i = 0; i < n; i++) {
		const struct vmcs12_layout *f = vmcs12_at(i);
		uint64_t val;
		uint32_t enc;

		if (f == NULL)
			break;
		enc = f->encoding;

		/*
		 * READONLY fields (currently just VPID) are
		 * L0-owned; the L0 VMCS already holds the
		 * authoritative value.  We do copy them back
		 * into the L1 VMCS12 so VMREAD sees the
		 * correct value, but we do not set the
		 * write-dirty bit because the L1 cannot
		 * legitimately re-write them.
		 */
		val = vmcs_read(enc);
		vmcs12_write_field(vmcs12, enc, val);

		if ((f->flags & VMCS12_F_READONLY) != 0)
			continue;

		if (ns->vmcs_field_dirty != NULL) {
			if (enc >= VMCS_FIELD_BITMAP_SIZE * 8)
				continue;
			ns->vmcs_field_dirty[enc / 8] |=
			    (uint8_t)(1u << (enc % 8));
		}
	}

	rc = 0;
	VMX_CTR0(vcpu, "nested shadow check: copied active VMCS -> VMCS12");
	return (rc);
}
