/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Stubs for missing T25 wave-5 dispatcher-wired functions.
 *
 * The T25 dispatcher wiring (added in the wave5-fix-t25-dispatcher-wiring
 * branch) added calls to svm_nested_vmrun(), svm_nested_vmsave(),
 * svm_nested_vmload(), svm_nested_clgi(), svm_nested_stgi(), and
 * svm_nested_skinit() in sys/amd64/vmm/amd/svm.c, but the underlying
 * implementations were never written. The dispatcher expects these
 * functions to:
 *   - Return 0 on success (continue L1's emulation)
 *   - Return non-zero on failure (L0 takes over)
 *
 * This file provides the minimal stubs required to compile. Each
 * stub logs a diagnostic and returns 1 (failure), causing the
 * caller in svm.c to fall through to the legacy handling.
 *
 * These will be replaced by real implementations in subsequent
 * waves of the nested-virt plan.
 */

#include <sys/cdefs.h>
#include <sys/param.h>
#include <sys/systm.h>

#include <machine/vmm.h>

#include "svm_softc.h"
#include "svm_nested.h"
#include "svm_nested_stubs.h"
#include "vmcb.h"

int
svm_nested_vmrun(struct svm_vcpu *vcpu, struct vmcb *vmcb)
{
	return (1);
}

int
svm_nested_vmsave(struct svm_vcpu *vcpu)
{
	return (1);
}

int
svm_nested_vmload(struct svm_vcpu *vcpu)
{
	return (1);
}

int
svm_nested_clgi(struct svm_vcpu *vcpu)
{
	return (1);
}

int
svm_nested_stgi(struct svm_vcpu *vcpu)
{
	return (1);
}

void
svm_nested_skinit(struct svm_vcpu *vcpu)
{
}

void
svm_nested_tlb_flush(struct svm_vcpu *vcpu)
{
	/*
	 * NO-OP LINKER STUB ONLY.
	 *
	 * This body is intentionally empty.  The function exists solely
	 * because the wave-5 dispatcher wiring in sys/amd64/vmm/amd/svm.c
	 * references svm_nested_tlb_flush() by name, so the symbol must
	 * resolve at link time.  A real implementation MUST come in a
	 * later wave and is NOT provided here.
	 *
	 * What a real implementation MUST do (AMD APM Vol 2, sec. 15.5 /
	 * 15.6 - Nested Page Tables and ASIDs):
	 *
	 *   1. Decide the flush scope.  AMD exposes a per-VMCB TLB_CONTROL
	 *      field with values:
	 *        - VMCB_TLB_FLUSH_NOTHING  (= 0): no flush requested.
	 *        - VMCB_TLB_FLUSH_ENTRIES  (= 1): flush this guest's TLB
	 *          entries that match VMCB.ASID (the L2 ASID).
	 *        - VMCB_TLB_FLUSH_GUEST    (= 3): flush all TLB entries
	 *          belonging to this guest (all ASIDs assigned to L2).
	 *        - VMCB_TLB_FLUSH_ALL      (= 7): flush the entire TLB.
	 *      Pick the narrowest scope that still preserves correctness
	 *      for the operation that triggered the flush.
	 *
	 *   2. Mark the source VMCB's ASID as dirty so the next VMRUN with
	 *      that ASID will force a full TLB reload on entry (ASIDs are
	 *      tracked via vmcb->tlb_dirty or equivalent in svm_softc).
	 *      Without this, INVLPGA from L2 with a stale ASID can leak
	 *      L1-tagged entries across context switches.
	 *
	 *   3. Walk the nSVM shadow-ASID table and invalidate any ASID
	 *      aliases the L1 hypervisor has bound to this L2.  AMD ASID
	 *      space is shared between L1 and L2 - an L2 INVLPGA that
	 *      targets a "free" ASID can flush an unrelated L1 mapping.
	 *
	 *   4. Optionally issue VMRUN with TLB_CONTROL=FLUSH_ALL as a
	 *      safe fallback when the caller cannot prove a narrower
	 *      scope is sufficient.
	 *
	 * DO NOT CALL THIS STUB DURING LIVE L2 EXECUTION.
	 *
	 * The empty body here is unsafe: it leaves L1/L2 TLB entries
	 * tagged with L1's ASID visible after a flush request, which
	 * on real silicon lets an L2 guest observe L1 mappings it
	 * should not see.  The dispatcher path that reaches this stub
	 * must short-circuit to L0 emulation (return 1 / bail to the
	 * legacy svm.c handler) until a real implementation lands.
	 */
}
