/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 *
 * Nested interrupt controller virtualization (T25b) for AMD SVM.
 *
 * The nested interrupt chain:
 *   - L2 device fires interrupt → virtual interrupt pending in L2's
 *     vAPIC (handled by the existing bhyve vlAPIC code).
 *   - On L2 VMEXIT, L0's exit handler injects the interrupt into
 *     L2's pending list (interrupt-window-open, etc.) so L1's
 *     interrupt-window logic can re-deliver.
 *   - Alternatively, propagate the interrupt up to L1, which then
 *     decides what to do.
 *
 * Wave1 implements injection via the L1 VMCB12 EventInjection
 * field. The PIR (Pending Interrupt Register)
 * is maintained per-L2-vCPU so a noisy L2 device does not flood L1.
 *
 * Original BSD code.
 */

#include <sys/cdefs.h>

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/types.h>

#include <machine/vmm.h>

#include "svm_softc.h"
#include "svm_nested.h"
#include "svm_nested_intr.h"
#include <dev/vmm/vmm_ktr.h>
#include "vmcb.h"

/*
 * Per-L2-vCPU Pending Interrupt Register. L0 records vectors that
 * are pending for L2 but have not yet been delivered because the
 * L2 interrupt-window was not open at the time of the L2 exit.
 *
 * 256 bits = 32 bytes = 8 ulongs. Stored as uint64_t[4] for
 * 32-byte alignment and zero-init.
 */
#define	SVM_NESTED_PIR_WORDS	4

/* The PIR lives in the per-vCPU nested state so VMs cannot alias. */
static uint64_t *
svm_nested_pir_of(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;

	ns = svm_nested_lookup(vcpu);
	return (ns != NULL ? ns->pir : NULL);
}

static void
svm_nested_pir_set(struct svm_vcpu *vcpu, uint8_t vector)
{
	uint64_t *pir, mask;
	unsigned idx;

	pir = svm_nested_pir_of(vcpu);
	if (pir == NULL)
		return;
	idx = vector / 64;
	mask = (uint64_t)1 << (vector % 64);
	pir[idx] |= mask;
}

static void
svm_nested_pir_clear(struct svm_vcpu *vcpu, uint8_t vector)
{
	uint64_t *pir, mask;
	unsigned idx;

	pir = svm_nested_pir_of(vcpu);
	if (pir == NULL)
		return;
	idx = vector / 64;
	mask = (uint64_t)1 << (vector % 64);
	pir[idx] &= ~mask;
}

static int
svm_nested_pir_highest(struct svm_vcpu *vcpu)
{
	uint64_t *pir;
	int word;

	pir = svm_nested_pir_of(vcpu);
	if (pir == NULL)
		return (-1);
	for (word = SVM_NESTED_PIR_WORDS - 1; word >= 0; word--) {
		if (pir[word] != 0) {
			uint64_t bits = pir[word];
			int bit;
			for (bit = 63; bit >= 0; bit--) {
				if (bits & ((uint64_t)1 << bit))
					return (word * 64 + bit);
			}
		}
	}
	return (-1);
}

/*
 * Build the EventInjection word:
 *   bits  7:0  : vector
 *   bits 10:8  : type (0=INTR, 2=NMI, 3=EXCEPTION, 4=INTn)
 *   bit  11    : error-code valid
 *   bits 31:12 : reserved
 *   bit  31    : VALID
 *   bits 63:32 : error code (when bit 11 set)
 */
static uint64_t
svm_nested_encode_eventinj(uint8_t vector, uint8_t type, uint32_t error_code,
    int ec_valid)
{
	uint64_t eventinj;

	eventinj = (uint64_t)vector;
	eventinj |= ((uint64_t)(type & 0x7)) << 8;
	if (ec_valid)
		eventinj |= VMCB_EVENTINJ_EC_VALID;
	eventinj |= VMCB_EVENTINJ_VALID;
	if (ec_valid)
		eventinj |= ((uint64_t)error_code) << 32;
	return (eventinj);
}

void
svm_nested_inject_pending_interrupt(struct svm_vcpu *vcpu, uint8_t vector,
    uint8_t type)
{
	struct vmcb_ctrl *ctrl;

	if (vcpu == NULL)
		return;
	ctrl = svm_get_vmcb_ctrl(vcpu);
	if (ctrl == NULL)
		return;

	if (type == VMCB_EVENTINJ_TYPE_INTR) {
		svm_nested_pir_set(vcpu, vector);
	}

	ctrl->eventinj = svm_nested_encode_eventinj(vector, type, 0, 0);
	SVM_CTR2(vcpu, "intr_inject: vector=%u type=%u",
	    (unsigned)vector, (unsigned)type);
}

void
svm_nested_inject_extint(struct svm_vcpu *vcpu, uint8_t vector)
{

	if (vcpu == NULL)
		return;
	svm_nested_inject_pending_interrupt(vcpu, vector,
	    VMCB_EVENTINJ_TYPE_INTR);
	svm_nested_pir_set(vcpu, vector);
}

void
svm_nested_inject_nmi(struct svm_vcpu *vcpu)
{

	if (vcpu == NULL)
		return;
	svm_nested_inject_pending_interrupt(vcpu, 2 /* NMI_VECTOR */,
	    VMCB_EVENTINJ_TYPE_NMI);
}

void
svm_nested_inject_exception(struct svm_vcpu *vcpu, uint8_t vector,
    uint32_t error_code, int ec_valid)
{
	struct vmcb_ctrl *ctrl;

	if (vcpu == NULL)
		return;
	ctrl = svm_get_vmcb_ctrl(vcpu);
	if (ctrl == NULL)
		return;

	ctrl->eventinj = svm_nested_encode_eventinj(vector,
	    VMCB_EVENTINJ_TYPE_EXCEPTION, error_code, ec_valid);
	SVM_CTR3(vcpu, "exception_inject: vector=%u ec=%#x ec_valid=%d",
	    (unsigned)vector, (unsigned)error_code, ec_valid ? 1 : 0);
}

/*
 * Drain the per-L2-vCPU PIR into the VMCB EventInjection field.
 * Called on each L2 entry (T25 VMRUN) when the interrupt window is
 * open. Returns the vector delivered, or -1 if no vector was
 * pending.
 */
int
svm_nested_drain_pir(struct svm_vcpu *vcpu)
{
	int vector;

	if (vcpu == NULL)
		return (-1);
	vector = svm_nested_pir_highest(vcpu);
	if (vector < 0)
		return (-1);

	svm_nested_pir_clear(vcpu, (uint8_t)vector);
	svm_nested_inject_pending_interrupt(vcpu, (uint8_t)vector,
	    VMCB_EVENTINJ_TYPE_INTR);
	SVM_CTR1(vcpu, "pir_drain: delivered vector=%d", vector);
	return (vector);
}