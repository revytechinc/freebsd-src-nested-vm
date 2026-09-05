/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 *
 * Nested SVM instruction emulation entry points (see svm_nested_stubs.c).
 */

#ifndef _VMM_SVM_NESTED_STUBS_H_
#define _VMM_SVM_NESTED_STUBS_H_

struct svm_vcpu;
struct vmcb;

int	svm_nested_vmrun(struct svm_vcpu *vcpu, uint64_t l1_next_rip);
int	svm_nested_op(void *vcpui, struct vm_exit *vme);
void	svm_nested_release_l1_maps(struct svm_vcpu *vcpu);
int	svm_nested_vmsave(struct svm_vcpu *vcpu);
int	svm_nested_vmload(struct svm_vcpu *vcpu);
int	svm_nested_clgi(struct svm_vcpu *vcpu);
int	svm_nested_stgi(struct svm_vcpu *vcpu);
bool	svm_nested_gif(struct svm_vcpu *vcpu);
void	svm_nested_trace(struct svm_vcpu *vcpu, const char *what, uint64_t a,
	    uint64_t b);
extern int svm_nested_debug;
struct vmcb *svm_nested_hold_vmcb(struct svm_vcpu *vcpu, uint64_t gpa,
	    int prot, void **cookie);

#endif /* _VMM_SVM_NESTED_STUBS_H_ */
