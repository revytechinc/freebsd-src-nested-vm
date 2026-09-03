/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * AMD SVM MSR permission map (MSRPM) helpers shared by the nested-SVM
 * code: L0 uses them to build the MSRPM it runs L1 under, and the L2
 * exit path uses the same offset computation to consult L1's MSRPM.
 *
 * Layout per AMD APM Vol 2 §15.11 ("MSR Intercepts"). The map is two
 * 4 KB pages; each MSR owns two consecutive bits, the lower one for
 * RDMSR and the upper one for WRMSR, a set bit meaning "intercept":
 *
 *   offset 0x0000-0x07FF   MSRs 0x00000000-0x00001FFF
 *   offset 0x0800-0x0FFF   MSRs 0xC0000000-0xC0001FFF
 *   offset 0x1000-0x17FF   MSRs 0xC0010000-0xC0011FFF
 *   offset 0x1800-0x1FFF   reserved
 *
 * MSRs outside those three ranges are always intercepted.
 */

#include <sys/cdefs.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/errno.h>

#include <machine/specialreg.h>
#include <machine/vmm.h>

#include "svm_softc.h"
#include "svm_nested.h"

/*
 * Return the byte offset and bit number of the read-intercept bit for
 * 'msr'; the write bit is the next one. EINVAL for MSRs outside the
 * mapped ranges.
 */
int
svm_msr_bitmap_locate(uint32_t msr, size_t *byte, unsigned *bit)
{
	uint32_t base, index;

	if (msr <= 0x1fff) {
		base = 0x0000;
		index = msr;
	} else if (msr >= 0xc0000000 && msr <= 0xc0001fff) {
		base = 0x0800;
		index = msr - 0xc0000000;
	} else if (msr >= 0xc0010000 && msr <= 0xc0011fff) {
		base = 0x1000;
		index = msr - 0xc0010000;
	} else {
		return (EINVAL);
	}
	*byte = base + (index * 2) / 8;
	*bit = (index * 2) % 8;
	return (0);
}

void
svm_msr_bitmap_init(struct nested_bitmap *nb, void *backing)
{

	KASSERT(nb != NULL, ("%s: nb is NULL", __func__));
	KASSERT(backing != NULL, ("%s: backing is NULL", __func__));

	nb->map = backing;
	nb->size = SVM_MSR_BITMAP_SIZE;
	/* AMD default: every MSR access is intercepted. */
	memset(nb->map, 0xff, SVM_MSR_BITMAP_SIZE);
}

static int
svm_msr_bitmap_op(struct nested_bitmap *nb, uint32_t msr, int rw, bool set)
{
	size_t byte;
	unsigned bit;

	if (rw == 0 || (rw & ~MSR_BITMAP_ACCESS_RW) != 0)
		return (EINVAL);
	if (svm_msr_bitmap_locate(msr, &byte, &bit) != 0)
		return (EINVAL);
	if (byte >= nb->size)
		return (EINVAL);

	if (rw & MSR_BITMAP_ACCESS_READ) {
		if (set)
			nb->map[byte] |= (uint8_t)(1u << bit);
		else
			nb->map[byte] &= (uint8_t)~(1u << bit);
	}
	if (rw & MSR_BITMAP_ACCESS_WRITE) {
		if (set)
			nb->map[byte] |= (uint8_t)(1u << (bit + 1));
		else
			nb->map[byte] &= (uint8_t)~(1u << (bit + 1));
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

/*
 * Non-zero if any access in 'rw' is intercepted for 'msr'. MSRs outside
 * the mapped ranges are reported as intercepted, matching hardware.
 */
int
svm_msr_bitmap_test_intercept(const struct nested_bitmap *nb, uint32_t msr,
    int rw)
{
	size_t byte;
	unsigned bit;
	int intercepted = 0;

	if (rw == 0 || (rw & ~MSR_BITMAP_ACCESS_RW) != 0)
		return (0);
	if (svm_msr_bitmap_locate(msr, &byte, &bit) != 0)
		return (1);
	if (nb == NULL || nb->map == NULL || byte >= nb->size)
		return (1);

	if ((rw & MSR_BITMAP_ACCESS_READ) &&
	    (nb->map[byte] & (1u << bit)) != 0)
		intercepted = 1;
	if ((rw & MSR_BITMAP_ACCESS_WRITE) &&
	    (nb->map[byte] & (1u << (bit + 1))) != 0)
		intercepted = 1;
	return (intercepted);
}

/*
 * L0-side additions to the MSRPM of a nested-enabled VM: an L1
 * hypervisor must never program the hardware HSAVE area directly.
 */
void
svm_nested_build_msrpm(struct svm_softc *sc, struct svm_vcpu *vcpu)
{
	struct nested_bitmap nb;

	KASSERT(sc != NULL, ("%s: sc is NULL", __func__));
	KASSERT(vcpu != NULL, ("%s: vcpu is NULL", __func__));
	nb.map = sc->msr_bitmap;
	nb.size = SVM_MSR_BITMAP_SIZE;
	(void)svm_msr_bitmap_set_intercept(&nb, MSR_VM_HSAVE_PA,
	    MSR_BITMAP_ACCESS_RW);
}
