/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * General nested #VMEXIT synthesis infrastructure for AMD SVM (T25a).
 *
 * When L2 takes a #VMEXIT while L1 is parked, L0 cannot blindly
 * return control to L1 — L1's view of "VMEXIT" is the same view L0
 * has of its own VMEXITs. The L2 exit must therefore be reflected
 * into L1's VMCB12 (ExitCode, ExitInfo1, ExitInfo2, ExitIntInfo)
 * with semantics identical to the AMD APM Vol 2 §15.5 specification.
 *
 * Original BSD code. KVM arch/x86/kvm/svm/svm.c::nested_svm_exit_handled
 * was consulted for the dispatch order only; no source was copied.
 */

#ifndef _VMM_SVM_NESTED_EXIT_H_
#define _VMM_SVM_NESTED_EXIT_H_

struct svm_vcpu;

/*
 * Reflect a hardware-emulated L2 #VMEXIT into the L1 VMCB12 area.
 *
 * 'vmcb12' is the L1-stated VMCB (mapped into kernel memory by the
 * caller via vm_gpa_hold). May be NULL when the dispatcher is
 * exercised in isolation by the unit test (T11 / T30).
 *
 * 'exitcode' is the L2 hardware exit code (one of VMCB_EXIT_*).
 * 'exitinfo1' and 'exitinfo2' are the L2 hardware qualification
 * data (per AMD APM Vol 2 §15.5; for an NPF, info1 carries the
 * error code and info2 the GPA).
 *
 * After this call returns:
 *   - vcpu->nested_in_l2 is cleared (L1 resumes).
 *   - the L1 VMCB12 has its ExitCode, ExitInfo1, ExitInfo2 and,
 *     where applicable, ExitIntInfo fields updated.
 *   - L1 ASID TLB entries are flushed (T29b) to drop L2
 *     translations.
 */
/*
 * Critical-section safe: does an exit taken while running L2 need the
 * nested machinery (reflection to L1 or a shadow-NPT fill)? Uses only
 * the VMCB12 and the L1 IOPM/MSRPM pages held at VMRUN.
 */
bool	 svm_nested_l2_exit_needed(struct svm_vcpu *vcpu, uint64_t exitcode,
	     uint64_t exitinfo1);
/*
 * vm_run() context: complete an L2 exit. Returns 2 when the fault was
 * resolved and L2 resumes, 1 when the exit was delivered to L1, 0 when
 * the exit was not for the nested machinery.
 */
int	 svm_nested_l2_exit(struct svm_vcpu *vcpu, uint64_t exitcode,
	     uint64_t exitinfo1, uint64_t exitinfo2);
void	 svm_nested_reflect_l2_exit(struct svm_vcpu *vcpu, uint64_t exitcode,
	     uint64_t exitinfo1, uint64_t exitinfo2);
/*
 * Direct writer of the L1 VMCB12 exit-info fields. Useful when the
 * caller has already inspected the L2 exit and wants to push the
 * raw values into L1 without going through the full dispatch.
 */
#endif /* _VMM_SVM_NESTED_EXIT_H_ */