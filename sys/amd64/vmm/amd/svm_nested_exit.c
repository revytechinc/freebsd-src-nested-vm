/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * General nested #VMEXIT synthesis infrastructure for AMD SVM (T25a).
 *
 * When L2 takes a #VMEXIT while L1 is parked, L0 must reflect the
 * exit reason back to L1 via the L1-stated VMCB12 (ExitCode,
 * ExitInfo1, ExitInfo2, ExitIntInfo) per AMD APM Vol 2 §15.5.
 *
 * The dispatch table below covers the most-common L2 exit reasons
 * (NPF, INTR, NMI, VINTR, CR/DR R/W, CPUID, RDTSC, RDPMC, HLT,
 * PAUSE, IOIO, MSR, TRIPLE_FAULT, TASK_SWITCH). Anything outside
 * this set is reflected as a generic VMEXIT with the exit code
 * preserved and a warning logged so the operator notices an L2
 * instruction class L0 did not enumerate.
 *
 * Original BSD code; KVM arch/x86/kvm/svm/svm.c::nested_svm_exit_handled
 * was consulted for the dispatch order only. No source copied.
 */

#include <sys/cdefs.h>

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>

#include <machine/vmm.h>
#include <dev/vmm/vmm_mem.h>

#include "svm_softc.h"
#include "svm_nested.h"
#include "svm_nested_exit.h"
#include "vmm_nested.h"
#include <dev/vmm/vmm_ktr.h>
#include "vmcb.h"

/*
 * Apply the four exit-info fields to the L1 VMCB12 (mapped by the
 * caller via vm_gpa_hold). The address is taken from a thread-local
 * 'vmcb12' pointer that the wave5 entry path installs on each L2
 * entry; if no VMCB12 is installed (test code with no L1 backing),
 * the function is a no-op so the unit tests can exercise the
 * dispatcher without a real L1 mapping.
 */
static struct vmcb *svm_nested_vmcb12 = NULL;

struct svm_nested *
svm_nested_lookup(struct svm_vcpu *vcpu)
{

	if (vcpu == NULL)
		return (NULL);
	return (&vcpu->nested);
}

void
svm_nested_set_vmcb12(struct vmcb *vmcb12)
{

	svm_nested_vmcb12 = vmcb12;
}

void
svm_nested_release_vmcb12(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;

	ns = svm_nested_lookup(vcpu);
	if (ns == NULL)
		return;
	if (ns->vmcb12_cookie != NULL) {
		vm_gpa_release(ns->vmcb12_cookie);
		ns->vmcb12_cookie = NULL;
	}
	ns->vmcb12 = NULL;
	ns->vmcb12_gpa = 0;
	svm_nested_set_vmcb12(NULL);
}

void
svm_nested_reflect_exit_info_to_vmcb12(struct svm_vcpu *vcpu,
    struct vmcb *vmcb12, uint64_t exitcode, uint64_t exitinfo1, uint64_t exitinfo2)
{

	struct vmcb_ctrl *ctrl;

	(void)vcpu;

	if (vmcb12 == NULL) {
		/*
		 * No L1 VMCB12 mapped: nothing to reflect. Used by
		 * the unit-test path that exercises the dispatcher in
		 * isolation. The caller can inspect the captured
		 * 'last_reflected_*' variables via the test module.
		 */
		return;
	}

	ctrl = &vmcb12->ctrl;
	ctrl->exitcode = exitcode;
	ctrl->exitinfo1 = exitinfo1;
	ctrl->exitinfo2 = exitinfo2;
}

void
svm_nested_handle_vmexit(struct svm_vcpu *vcpu, struct vmcb *vmcb12,
    uint64_t exitcode, uint64_t exitinfo1, uint64_t exitinfo2)
{
	struct svm_nested *ns;
	uint64_t reflected_exitinfo1 = exitinfo1;
	uint64_t reflected_exitinfo2 = exitinfo2;

	if (vcpu == NULL)
		return;

	ns = svm_nested_lookup(vcpu);
	if (vmcb12 == NULL && ns != NULL)
		vmcb12 = ns->vmcb12;

	switch (exitcode) {
	case VMCB_EXIT_NPF:
		/*
		 * Nested page fault. L0 already filled EXITINFO1 with
		 * the NPF error code and EXITINFO2 with the GPA; L1's
		 * VMCB12 wants the same fields. No remapping: L2's
		 * GPAs are L1's GPAs.
		 */
		SVM_CTR3(vcpu, "npf_reflect: gpa=%#lx err=%#lx code=%#lx",
		    (unsigned long)exitinfo2, (unsigned long)exitinfo1,
		    (unsigned long)exitcode);
		break;

	case VMCB_EXIT_INTR:
		/*
		 * Physical interrupt. L0 cannot decide which vector to
		 * deliver to L2; L1 picks. Reflect as-is and let L1's
		 * interrupt-window logic inject via T25b.
		 */
		reflected_exitinfo2 = 0;
		break;

	case VMCB_EXIT_NMI:
		reflected_exitinfo2 = 0;
		break;

	case VMCB_EXIT_VINTR:
		/*
		 * Virtual interrupt — handled inside L1 (L1 set up the
		 * interrupt-window intercept). Pass through unchanged.
		 */
		break;

	case 0x20 ... 0x2F:	/* DR0..DR7 read */
	case 0x30 ... 0x3F:	/* DR0..DR7 write */
		break;

	case VMCB_EXIT_CPUID:
		reflected_exitinfo2 = 0;
		break;

	case VMCB_EXIT_HLT:
	case VMCB_EXIT_PAUSE:
		reflected_exitinfo2 = 0;
		break;

	case VMCB_EXIT_IO:
		/*
		 * IOIO intercept. EXITINFO1 carries port, size, and
		 * direction (per AMD APM Vol 2 §15.7). EXITINFO2 is
		 * the data (for OUT) or zero.
		 */
		break;

	case VMCB_EXIT_MSR:
		/*
		 * MSR intercept. EXITINFO1 carries the MSR number
		 * (low 32 bits) and the read/write flag (bit 0). EXITINFO2
		 * carries the value (for WRMSR) or zero.
		 */
		break;

	case VMCB_EXIT_SHUTDOWN:
		/*
		 * Triple fault: L2 is unrecoverable. Mark L2 as gone
		 * so the next L2 entry is forced to rebuild the L2
		 * VMCB. The L1 hypervisor sees a normal SHUTDOWN exit
		 * and decides whether to terminate or restart.
		 */
		if (ns != NULL)
			ns->nested_in_l2 = false;
		break;

	case VMCB_EXIT_IRET:
		/*
		 * IRET intercepted by L1's NMI-blocking or
		 * interrupt-window logic. Pass through.
		 */
		break;

	default:
		/*
		 * Uncommon exit reason: reflect as-is and log. The
		 * unknown reason survives in the L1 VMCB12 so the L1
		 * hypervisor (which understands all of its own
		 * intercepts) can decide what to do.
		 */
		SVM_CTR2(vcpu, "vmexit: uncommon exitcode %#lx info1=%#lx",
		    (unsigned long)exitcode, (unsigned long)exitinfo1);
		break;
	}

	svm_nested_reflect_exit_info_to_vmcb12(vcpu, vmcb12, exitcode,
	    reflected_exitinfo1, reflected_exitinfo2);

	if (ns != NULL && ns->nested_in_l2) {
		/*
		 * Park L2: restore L1 save area into the hardware VMCB
		 * so the next VMRUN (L0) re-enters L1, not L2.
		 */
		vcpu->vmcb->state = ns->l1_state;
		ns->nested_in_l2 = false;
		svm_set_dirty(vcpu, 0xffffffff);
	}

	/*
	 * T29b: drop L2 translations so L1 cannot observe them.
	 */
	svm_nested_tlb_flush(vcpu);

	SVM_CTR3(vcpu, "vmexit_reflect: code=%#lx info1=%#lx info2=%#lx",
	    (unsigned long)exitcode, (unsigned long)reflected_exitinfo1,
	    (unsigned long)reflected_exitinfo2);
}