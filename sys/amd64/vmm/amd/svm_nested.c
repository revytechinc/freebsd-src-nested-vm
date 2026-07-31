/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * Nested virtualization support for bhyve on AMD SVM.
 * MSR bitmap primitives backing the per-vCPU MSRPM. Layout follows
 * AMD APM Vol 2 §15.11; this is original BSD code that implements the
 * primitive set/clear/test operations on a shared 'nested_bitmap'.
 */

#include <sys/cdefs.h>

#include <sys/errno.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/types.h>

#include <machine/cpufunc.h>
#include <machine/vmm.h>

#include "svm_softc.h"
#include "svm_nested.h"
#include "vmm_nested.h"
#include "vmcb.h"

/*
 * MSR_BITMAP_ACCESS_* values come from intel/vmx_msr.h. Re-declare here
 * locally so this file does not need to pull in VMX-only headers.
 */
#ifndef MSR_BITMAP_ACCESS_NONE
#define	MSR_BITMAP_ACCESS_NONE	0x0
#endif
#ifndef MSR_BITMAP_ACCESS_READ
#define	MSR_BITMAP_ACCESS_READ	0x1
#endif
#ifndef MSR_BITMAP_ACCESS_WRITE
#define	MSR_BITMAP_ACCESS_WRITE	0x2
#endif
#ifndef MSR_BITMAP_ACCESS_RW
#define	MSR_BITMAP_ACCESS_RW	(MSR_BITMAP_ACCESS_READ|MSR_BITMAP_ACCESS_WRITE)
#endif

/*
 * Translate an MSR number into the (page_base, msr_within_page) pair
 * used by the rest of the bitmap primitives. Returns 0 on success,
 * EINVAL if the MSR falls outside both AMD-supported ranges
 * (0x00000000-0x00001FFF and 0xC0000000-0xC0001FFF).
 *
 * On success:
 *   *page_base   = absolute byte offset of the 2 KB read map for the
 *                  chosen page (0 for page 0, 0x1000 for page 1)
 *   *msr_in_page = MSR index within that 2 KB region (0 .. 0x1FFF)
 */
static int
svm_msr_bitmap_locate(uint32_t msr, size_t *page_base, uint32_t *msr_in_page)
{
	uint32_t offset;

	if (msr <= (SVM_MSR_BITMAP_PAGE0_MSRS - 1)) {
		*page_base = 0;
		*msr_in_page = msr;
		return (0);
	}
	if (msr >= SVM_MSR_BITMAP_PAGE1_BASE &&
	    msr < SVM_MSR_BITMAP_PAGE1_BASE + SVM_MSR_BITMAP_PAGE1_MSRS) {
		offset = msr - SVM_MSR_BITMAP_PAGE1_BASE;
		if (offset >= SVM_MSR_BITMAP_PAGE1_MSRS)
			return (EINVAL);
		*page_base = SVM_MSR_BITMAP_PAGE1_BASE_OFF;
		*msr_in_page = offset;
		return (0);
	}
	return (EINVAL);
}

void
svm_msr_bitmap_init(struct nested_bitmap *nb, void *backing)
{

	KASSERT(nb != NULL, ("%s: nb is NULL", __func__));
	KASSERT(backing != NULL, ("%s: backing is NULL", __func__));

	nb->map = backing;
	nb->size = SVM_MSR_BITMAP_SIZE;
	/*
	 * AMD-default semantics: every MSR access is intercepted. Bits
	 * are cleared (allowed) by svm_msr_bitmap_clear_intercept(). This
	 * matches the initialization in sys/amd64/vmm/amd/svm.c.
	 */
	memset(nb->map, 0xff, SVM_MSR_BITMAP_SIZE);
}

static int
svm_msr_bitmap_op(struct nested_bitmap *nb, uint32_t msr, int rw, bool set)
{
	size_t page_base;
	uint32_t msr_in_page;
	size_t read_byte, write_byte;
	uint8_t mask;

	if (rw & ~(MSR_BITMAP_ACCESS_READ | MSR_BITMAP_ACCESS_WRITE))
		return (EINVAL);

	if (svm_msr_bitmap_locate(msr, &page_base, &msr_in_page) != 0)
		return (EINVAL);

	read_byte = page_base + (msr_in_page / SVM_MSR_BITMAP_MSRS_PER_BYTE);
	write_byte = read_byte + SVM_MSR_BITMAP_WRITE_HALF_OFF;

	if (read_byte + 1 > nb->size || write_byte + 1 > nb->size)
		return (EINVAL);

	mask = (uint8_t)((msr_in_page % SVM_MSR_BITMAP_MSRS_PER_BYTE) *
	    SVM_MSR_BITMAP_BITS_PER_MSR);

	if (rw & MSR_BITMAP_ACCESS_READ) {
		if (set)
			nb->map[read_byte] |= (uint8_t)(0x1 << mask);
		else
			nb->map[read_byte] &= (uint8_t)~(0x1 << mask);
	}
	if (rw & MSR_BITMAP_ACCESS_WRITE) {
		if (set)
			nb->map[write_byte] |= (uint8_t)(0x1 << (mask + 1));
		else
			nb->map[write_byte] &= (uint8_t)~(0x1 << (mask + 1));
	}
	return (0);
}

int
svm_msr_bitmap_set_intercept(struct nested_bitmap *nb, uint32_t msr, int rw)
{

	KASSERT(nb != NULL, ("%s: nb is NULL", __func__));
	return (svm_msr_bitmap_op(nb, msr, rw, true));
}

int
svm_msr_bitmap_clear_intercept(struct nested_bitmap *nb, uint32_t msr, int rw)
{

	KASSERT(nb != NULL, ("%s: nb is NULL", __func__));
	return (svm_msr_bitmap_op(nb, msr, rw, false));
}

int
svm_msr_bitmap_test_intercept(const struct nested_bitmap *nb, uint32_t msr,
    int rw)
{
	size_t page_base;
	uint32_t msr_in_page;
	size_t read_byte, write_byte;
	uint8_t mask;
	int intercepted = 0;

	if ((rw & ~(MSR_BITMAP_ACCESS_READ | MSR_BITMAP_ACCESS_WRITE)) == 0)
		return (0);
	if (svm_msr_bitmap_locate(msr, &page_base, &msr_in_page) != 0)
		return (0);

	if (nb == NULL || nb->map == NULL)
		return (0);

	read_byte = page_base + (msr_in_page / SVM_MSR_BITMAP_MSRS_PER_BYTE);
	write_byte = read_byte + SVM_MSR_BITMAP_WRITE_HALF_OFF;

	if (read_byte + 1 > nb->size || write_byte + 1 > nb->size)
		return (0);

	mask = (uint8_t)((msr_in_page % SVM_MSR_BITMAP_MSRS_PER_BYTE) *
	    SVM_MSR_BITMAP_BITS_PER_MSR);

	if ((rw & MSR_BITMAP_ACCESS_READ) &&
	    (nb->map[read_byte] & (0x1 << mask)) != 0)
		intercepted = 1;
	if ((rw & MSR_BITMAP_ACCESS_WRITE) &&
	    (nb->map[write_byte] & (0x1 << (mask + 1))) != 0)
		intercepted = 1;

	return (intercepted);
}

/*
 * Builder placeholder. Composes the per-vCPU MSRPM by walking the list
 * of MSR ranges that the L1 hypervisor must NOT access directly when
 * nested-virt is enabled. Currently a no-op so that T8-T11 can extend
 * it incrementally; intentionally empty (rather than absent) so that
 * the build always links to a single composed bitmap site.
 */
void
svm_nested_build_msrpm(struct svm_softc *sc, struct svm_vcpu *vcpu)
{

	(void)sc;
	(void)vcpu;
}