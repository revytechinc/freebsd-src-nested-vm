/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 *
 * Nested interrupt controller (T25b) prototype declarations for
 * sys/amd64/vmm/amd/svm_nested_intr.c.
 *
 * The per-L2-vCPU PIR (pending interrupt register) helpers
 * (svm_nested_pir_set/clear/highest) are file-local to
 * svm_nested_intr.c and are NOT exposed here.
 */

#ifndef _VMM_SVM_NESTED_INTR_H_
#define _VMM_SVM_NESTED_INTR_H_

struct svm_vcpu;

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
