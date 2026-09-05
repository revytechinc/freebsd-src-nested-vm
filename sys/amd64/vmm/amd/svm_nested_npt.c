/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 *
 * Shadow nested page tables for nested SVM.
 *
 * L1 programs VMCB12.N_CR3 with its own nested page table, which maps
 * L2 guest-physical addresses to L1 guest-physical addresses. Hardware
 * only performs one level of nested translation, so L0 keeps a per-vCPU
 * "NPT02" pmap that maps L2 GPAs straight to host memory and runs L2
 * under it. It is filled lazily: every #NPF taken while in L2 walks
 * L1's table in L1 memory, resolves the L1 GPA with
 * the ordinary vm_gpa_hold() machinery, and enters the page into NPT02.
 * A fault L1's table cannot resolve is reflected to L1 as an #NPF for
 * its L2 guest, exactly as hardware would report it.
 *
 * The shadow is discarded whenever L1 asks for a TLB flush on VMRUN or
 * switches N_CR3, which is what hardware would do with the cached
 * nested translations; the next L2 accesses refault and rebuild it.
 *
 * Original BSD code.
 */

#include <sys/cdefs.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/lock.h>
#include <sys/malloc.h>
#include <sys/mutex.h>

#include <vm/vm.h>
#include <vm/vm_param.h>
#include <vm/pmap.h>
#include <vm/vm_page.h>

#include <machine/pmap.h>
#include <machine/vmm.h>

#include <dev/vmm/vmm_mem.h>
#include <dev/vmm/vmm_ktr.h>

#include "svm_softc.h"
#include "svm_nested.h"
#include "svm_nested_exit.h"
#include "svm_nested_stubs.h"
#include "npt.h"
#include "vmcb.h"

static MALLOC_DEFINE(M_SVM_NPT02, "svm_npt02", "nested SVM shadow NPT");

#define	NPT_PG_V	0x001ul
#define	NPT_PG_RW	0x002ul
#define	NPT_PG_U	0x004ul
#define	NPT_PG_PS	0x080ul
#define	NPT_PG_NX	(1ul << 63)
#define	NPT_FRAME	0x000ffffffffff000ul
#define	NPT_FRAME_2M	0x000fffffffe00000ul
#define	NPT_FRAME_1G	0x000fffffc0000000ul

int
svm_nested_npt_init(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;
	struct pmap *pmap;

	ns = svm_nested_lookup(vcpu);
	if (ns->npt02 != NULL)
		return (0);
	pmap = malloc(sizeof(*pmap), M_SVM_NPT02, M_WAITOK | M_ZERO);
	PMAP_LOCK_INIT(pmap);
	if (svm_npt_pinit(pmap) == 0) {
		PMAP_LOCK_DESTROY(pmap);
		free(pmap, M_SVM_NPT02);
		return (ENOMEM);
	}
	ns->npt02 = pmap;
	ns->npt02_pa = vtophys(pmap->pm_pmltop);
	return (0);
}

void
svm_nested_npt_flush(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;

	ns = svm_nested_lookup(vcpu);
	if (ns->npt02 == NULL)
		return;
	pmap_remove(ns->npt02, 0, VM_MAXUSER_ADDRESS);
}

void
svm_nested_npt_cleanup(struct svm_vcpu *vcpu)
{
	struct svm_nested *ns;

	ns = svm_nested_lookup(vcpu);
	if (ns->npt02 == NULL)
		return;
	svm_nested_npt_flush(vcpu);
	pmap_release(ns->npt02);
	PMAP_LOCK_DESTROY(ns->npt02);
	free(ns->npt02, M_SVM_NPT02);
	ns->npt02 = NULL;
	ns->npt02_pa = 0;
}

static int
svm_nested_read_l1(struct svm_vcpu *vcpu, uint64_t gpa, uint64_t *val)
{
	void *mapping, *cookie;

	mapping = vm_gpa_hold(vcpu->vcpu, gpa, sizeof(*val), VM_PROT_READ,
	    &cookie);
	if (mapping == NULL)
		return (EFAULT);
	*val = *(uint64_t *)mapping;
	vm_gpa_release(cookie);
	return (0);
}

/*
 * Walk L1's 4-level nested page table for L2 GPA 'g2'. Guest accesses
 * are user accesses for the nested walk, so U/S must be set at every
 * level. On success *g1 is the L1 GPA and *prot the permissions the
 * table grants. On failure *info1 holds the #NPF EXITINFO1 to report
 * to L1.
 */
static int
svm_nested_npt_walk(struct svm_vcpu *vcpu, uint64_t ncr3, uint64_t g2,
    int access, uint64_t *g1, int *prot, uint64_t *info1)
{
	uint64_t table, pte, frame;
	int level, shift, granted;
	bool present;

	granted = VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE;
	table = ncr3 & NPT_FRAME;
	present = false;
	frame = 0;
	for (level = 4; level >= 1; level--) {
		shift = 12 + 9 * (level - 1);
		if (svm_nested_read_l1(vcpu, table +
		    ((g2 >> shift) & 0x1ff) * sizeof(pte), &pte) != 0)
			goto fault;
		if ((pte & NPT_PG_V) == 0)
			goto fault;
		if ((pte & NPT_PG_U) == 0)
			goto fault;
		if ((pte & NPT_PG_RW) == 0)
			granted &= ~VM_PROT_WRITE;
		if ((pte & NPT_PG_NX) != 0)
			granted &= ~VM_PROT_EXECUTE;
		if ((level == 3 || level == 2) && (pte & NPT_PG_PS) != 0) {
			frame = pte & (level == 3 ? NPT_FRAME_1G : NPT_FRAME_2M);
			frame |= g2 & ((1ul << shift) - 1);
			break;
		}
		if (level == 1) {
			frame = (pte & NPT_FRAME) | (g2 & PAGE_MASK);
			break;
		}
		table = pte & NPT_FRAME;
	}
	present = true;
	if ((access & granted) != access)
		goto fault;
	*g1 = frame;
	*prot = granted;
	return (0);

fault:
	*info1 = VMCB_NPF_INFO1_U | VMCB_NPF_INFO1_GPA;
	if (present)
		*info1 |= VMCB_NPF_INFO1_P;
	if (access & VM_PROT_WRITE)
		*info1 |= VMCB_NPF_INFO1_W;
	if (access & VM_PROT_EXECUTE)
		*info1 |= VMCB_NPF_INFO1_ID;
	return (EFAULT);
}

/*
 * Resolve an #NPF taken while running L2 under NPT02.
 *
 * Returns 0 when the translation was installed and L2 can be resumed,
 * 1 when the fault was reflected to L1 (the vCPU now runs L1), and -1
 * when L1 runs its guest without nested paging, in which case L2 GPAs
 * are L1 GPAs and L0's own #NPF handling applies.
 */
int
svm_nested_npt_fault(struct svm_vcpu *vcpu, uint64_t g2, uint64_t exitinfo1)
{
	struct svm_nested *ns;
	vm_page_t m;
	void *mapping, *cookie;
	uint64_t g1, info1;
	int access, prot, error;

	ns = svm_nested_lookup(vcpu);
	if (ns->vmcb12 == NULL || ns->vmcb12->ctrl.np_enable == 0)
		return (-1);
	KASSERT(ns->npt02 != NULL, ("L2 running without NPT02"));

	if (exitinfo1 & VMCB_NPF_INFO1_W)
		access = VM_PROT_WRITE;
	else if (exitinfo1 & VMCB_NPF_INFO1_ID)
		access = VM_PROT_EXECUTE;
	else
		access = VM_PROT_READ;

	if (svm_nested_npt_walk(vcpu, ns->vmcb12->ctrl.n_cr3, g2, access,
	    &g1, &prot, &info1) != 0) {
		SVM_CTR2(vcpu, "L2 #NPF gpa=%#lx not mapped by L1 (info1 %#lx)",
		    (unsigned long)g2, (unsigned long)info1);
		svm_nested_reflect_l2_exit(vcpu, VMCB_EXIT_NPF, info1, g2);
		return (1);
	}

	mapping = vm_gpa_hold(vcpu->vcpu, g1 & ~PAGE_MASK, PAGE_SIZE, access,
	    &cookie);
	if (mapping == NULL) {
		/* L1 mapped its guest onto memory it does not have. */
		info1 = VMCB_NPF_INFO1_U | VMCB_NPF_INFO1_GPA | VMCB_NPF_INFO1_P;
		if (access & VM_PROT_WRITE)
			info1 |= VMCB_NPF_INFO1_W;
		if (access & VM_PROT_EXECUTE)
			info1 |= VMCB_NPF_INFO1_ID;
		SVM_CTR2(vcpu, "L2 #NPF gpa=%#lx -> L1 gpa %#lx unbacked",
		    (unsigned long)g2, (unsigned long)g1);
		svm_nested_reflect_l2_exit(vcpu, VMCB_EXIT_NPF, info1, g2);
		return (1);
	}
	m = cookie;

	/*
	 * Enter the page into NPT02 with the permissions L1's table grants.
	 * pmap_enter() wants the page busied; it is already wired by the
	 * hold. The mapping is unwired so the page stays under the normal
	 * control of L1's VM object; NPT02 is torn down through its PV
	 * entries when the page goes away.
	 */
	vm_page_busy_acquire(m, 0);
	error = pmap_enter(ns->npt02, g2 & ~PAGE_MASK, m, prot, prot, 0);
	vm_page_xunbusy(m);
	vm_gpa_release(cookie);
	if (error != KERN_SUCCESS) {
		SVM_CTR2(vcpu, "NPT02 pmap_enter(%#lx) failed: %d",
		    (unsigned long)g2, error);
		svm_nested_reflect_l2_exit(vcpu, VMCB_EXIT_NPF,
		    VMCB_NPF_INFO1_U | VMCB_NPF_INFO1_GPA, g2);
		return (1);
	}
	SVM_CTR3(vcpu, "NPT02 %#lx -> L1 %#lx prot %#x", (unsigned long)g2,
	    (unsigned long)g1, prot);
	return (0);
}
