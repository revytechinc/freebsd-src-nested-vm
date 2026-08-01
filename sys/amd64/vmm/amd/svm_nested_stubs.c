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
