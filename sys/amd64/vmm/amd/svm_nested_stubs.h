/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * Prototypes for svm_nested_stubs (see svm_nested_stubs.c).
 * This header exists so svm.c can reference the stub functions
 * without including svm_nested_stubs.c directly (which would create
 * a circular dependency).
 */

#ifndef _VMM_SVM_NESTED_STUBS_H_
#define _VMM_SVM_NESTED_STUBS_H_

struct svm_vcpu;
struct vmcb;

int	svm_nested_vmrun(struct svm_vcpu *vcpu, struct vmcb *vmcb);
int	svm_nested_vmsave(struct svm_vcpu *vcpu);
int	svm_nested_vmload(struct svm_vcpu *vcpu);
int	svm_nested_clgi(struct svm_vcpu *vcpu);
int	svm_nested_stgi(struct svm_vcpu *vcpu);
void	svm_nested_skinit(struct svm_vcpu *vcpu);

#endif /* _VMM_SVM_NESTED_STUBS_H_ */
