/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * Nested interrupt controller (T25b) prototype declarations for
 * sys/amd64/vmm/amd/svm_nested_intr.c.
 */

#ifndef _VMM_SVM_NESTED_INTR_H_
#define _VMM_SVM_NESTED_INTR_H_

struct svm_vcpu;

/*
 * Record a pending interrupt vector for vCPU 'vcpuid' so the
 * next L2 entry can re-deliver it through the interrupt-window
 * path.
 */
void	 svm_nested_pir_set(int vcpuid, uint8_t vector);

/*
 * Clear a previously-recorded pending vector (typically after a
 * successful inject).
 */
void	 svm_nested_pir_clear(int vcpuid, uint8_t vector);

/*
 * Return the highest-priority pending vector for vcpuid, or -1
 * if the PIR is empty or vcpuid is out of range.
 */
int	 svm_nested_pir_highest(int vcpuid);

/*
 * Inject the pending vector into L2 via the EventInjection field
 * of L1's VMCB12.
 */
void	 svm_nested_inject_pending_interrupt(struct svm_vcpu *vcpu,
	     uint8_t vector, uint8_t type);

/* INTR/NMI/exception helpers layered on top of the above. */
void	 svm_nested_inject_extint(struct svm_vcpu *vcpu, uint8_t vector);
void	 svm_nested_inject_nmi(struct svm_vcpu *vcpu);
void	 svm_nested_inject_exception(struct svm_vcpu *vcpu, uint8_t vector,
	     uint32_t error_code, int ec_valid);

/*
 * Drain the per-L2-vCPU PIR into the VMCB EventInjection field on
 * L2 entry (T25 VMRUN). Returns the vector delivered, or -1 if the
 * PIR was empty.
 */
int	 svm_nested_drain_pir(struct svm_vcpu *vcpu);

#endif /* _VMM_SVM_NESTED_INTR_H_ */
