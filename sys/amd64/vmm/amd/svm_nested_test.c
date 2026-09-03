/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * svm_nested_test.ko: in-kernel self-tests for the nested-SVM helpers
 * that can run without a live vCPU. Each test is a sysctl under
 * hw.vmm.svm.nested.test_*; writing 1 runs it and the verdict goes to
 * the console as "svm_nested_test: <name> PASS|FAIL ...".
 *
 * The tests call the production svm_msr_bitmap_*() functions exported
 * by vmm.ko (this module depends on it) and check them against the
 * MSRPM layout in AMD APM Vol 2 §15.11, so a regression in the real
 * code is what fails here.
 */

#include <sys/cdefs.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/errno.h>
#include <sys/kernel.h>
#include <sys/malloc.h>
#include <sys/module.h>
#include <sys/proc.h>
#include <sys/sysctl.h>

#include <machine/vmm.h>

#include "vmm_nested.h"
#include "svm_softc.h"
#include "svm_nested.h"

#define	TEST_MSR_VM_HSAVE_PA	0xC0010117U
#define	TEST_MSR_LBR_START	0xC0010200U
#define	TEST_MSR_LBR_END	0xC0010233U

static int
test_run(const char *name, int (*fn)(struct nested_bitmap *), SYSCTL_HANDLER_ARGS)
{
	struct nested_bitmap nb;
	uint8_t *backing;
	int error, val = 0;

	error = sysctl_handle_int(oidp, &val, 0, req);
	if (error != 0 || req->newptr == NULL)
		return (error);
	if (val != 1)
		return (0);

	backing = malloc(SVM_MSR_BITMAP_SIZE, M_DEVBUF, M_WAITOK | M_ZERO);
	svm_msr_bitmap_init(&nb, backing);
	error = fn(&nb);
	printf("svm_nested_test: %s %s\n", name, error == 0 ? "PASS" : "FAIL");
	free(backing, M_DEVBUF);
	return (0);
}

/*
 * Layout: the read bit for MSR n in each range sits at bit 2*(n-base)
 * of the range's 2 KB region; the write bit is the next one.
 */
static int
test_layout(struct nested_bitmap *nb)
{
	size_t byte;
	unsigned bit;

	/* 0x1FFF is the last MSR of the first region: byte 0x7FF, bit 6. */
	if (svm_msr_bitmap_locate(0x1fff, &byte, &bit) != 0 ||
	    byte != 0x7ff || bit != 6) {
		printf("svm_nested_test: layout: MSR 0x1fff -> %#zx/%u\n",
		    byte, bit);
		return (EINVAL);
	}
	/* 0xC0000080 (EFER): region 2, index 0x80 -> byte 0x800+0x20, bit 0. */
	if (svm_msr_bitmap_locate(0xc0000080, &byte, &bit) != 0 ||
	    byte != 0x820 || bit != 0) {
		printf("svm_nested_test: layout: EFER -> %#zx/%u\n", byte, bit);
		return (EINVAL);
	}
	/* VM_HSAVE_PA: region 3, index 0x117 -> byte 0x1000+0x45, bit 6. */
	if (svm_msr_bitmap_locate(TEST_MSR_VM_HSAVE_PA, &byte, &bit) != 0 ||
	    byte != 0x1045 || bit != 6) {
		printf("svm_nested_test: layout: HSAVE_PA -> %#zx/%u\n",
		    byte, bit);
		return (EINVAL);
	}
	/* Gaps between the ranges are not mappable. */
	if (svm_msr_bitmap_locate(0x2000, &byte, &bit) == 0 ||
	    svm_msr_bitmap_locate(0xc0002000, &byte, &bit) == 0 ||
	    svm_msr_bitmap_locate(0xc0012000, &byte, &bit) == 0) {
		printf("svm_nested_test: layout: gap MSR mapped\n");
		return (EINVAL);
	}
	return (0);
}

/* init = intercept everything; clear/set/test round-trip on HSAVE_PA. */
static int
test_bitmap(struct nested_bitmap *nb)
{
	uint32_t msr = TEST_MSR_VM_HSAVE_PA;

	if (svm_msr_bitmap_test_intercept(nb, msr, MSR_BITMAP_ACCESS_RW) != 1) {
		printf("svm_nested_test: bitmap: init did not intercept\n");
		return (EINVAL);
	}
	if (svm_msr_bitmap_clear_intercept(nb, msr, MSR_BITMAP_ACCESS_RW) != 0 ||
	    svm_msr_bitmap_test_intercept(nb, msr, MSR_BITMAP_ACCESS_RW) != 0) {
		printf("svm_nested_test: bitmap: clear failed\n");
		return (EINVAL);
	}
	if (svm_msr_bitmap_set_intercept(nb, msr, MSR_BITMAP_ACCESS_WRITE) != 0 ||
	    svm_msr_bitmap_test_intercept(nb, msr, MSR_BITMAP_ACCESS_READ) != 0 ||
	    svm_msr_bitmap_test_intercept(nb, msr, MSR_BITMAP_ACCESS_WRITE) != 1) {
		printf("svm_nested_test: bitmap: write-only set failed\n");
		return (EINVAL);
	}
	/*
	 * Init set every bit; the clear above dropped bits 6 and 7 of byte
	 * 0x1045 and the write-only set restored bit 7: 0xff -> 0x3f -> 0xbf.
	 */
	if (nb->map[0x1045] != 0xbf) {
		printf("svm_nested_test: bitmap: byte 0x1045=%#x, want 0xbf\n",
		    nb->map[0x1045]);
		return (EINVAL);
	}
	/* Neighbouring MSRs must be untouched by the clear above. */
	if (svm_msr_bitmap_test_intercept(nb, msr - 1, MSR_BITMAP_ACCESS_RW) != 1 ||
	    svm_msr_bitmap_test_intercept(nb, msr + 1, MSR_BITMAP_ACCESS_RW) != 1) {
		printf("svm_nested_test: bitmap: neighbour clobbered\n");
		return (EINVAL);
	}
	/* Unmappable MSRs are reported as intercepted and rejected by set. */
	if (svm_msr_bitmap_test_intercept(nb, 0xc0002000, MSR_BITMAP_ACCESS_RW) != 1 ||
	    svm_msr_bitmap_set_intercept(nb, 0xc0002000, MSR_BITMAP_ACCESS_RW) != EINVAL) {
		printf("svm_nested_test: bitmap: out-of-range handling\n");
		return (EINVAL);
	}
	return (0);
}

/* The LBR range must be individually addressable and intercepted. */
static int
test_lbr(struct nested_bitmap *nb)
{
	uint32_t msr;

	for (msr = TEST_MSR_LBR_START; msr <= TEST_MSR_LBR_END; msr++) {
		if (svm_msr_bitmap_clear_intercept(nb, msr,
		    MSR_BITMAP_ACCESS_RW) != 0)
			return (EINVAL);
	}
	for (msr = TEST_MSR_LBR_START; msr <= TEST_MSR_LBR_END; msr++) {
		if (svm_msr_bitmap_set_intercept(nb, msr,
		    MSR_BITMAP_ACCESS_RW) != 0 ||
		    svm_msr_bitmap_test_intercept(nb, msr,
		    MSR_BITMAP_ACCESS_RW) != 1) {
			printf("svm_nested_test: lbr: MSR %#x\n", msr);
			return (EINVAL);
		}
	}
	return (0);
}

static int
test_bitmap_handler(SYSCTL_HANDLER_ARGS)
{

	return (test_run("bitmap", test_bitmap, oidp, arg1, arg2, req));
}

static int
test_layout_handler(SYSCTL_HANDLER_ARGS)
{

	return (test_run("layout", test_layout, oidp, arg1, arg2, req));
}

static int
test_lbr_handler(SYSCTL_HANDLER_ARGS)
{

	return (test_run("lbr", test_lbr, oidp, arg1, arg2, req));
}

SYSCTL_DECL(_hw_vmm_svm);
SYSCTL_NODE(_hw_vmm_svm, OID_AUTO, nested, CTLFLAG_RW | CTLFLAG_MPSAFE,
    NULL, "AMD SVM nested-virt self-tests");

SYSCTL_PROC(_hw_vmm_svm_nested, OID_AUTO, test_bitmap,
    CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_MPSAFE, NULL, 0,
    test_bitmap_handler, "I", "MSRPM set/clear/test round trip (write 1)");
SYSCTL_PROC(_hw_vmm_svm_nested, OID_AUTO, test_layout,
    CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_MPSAFE, NULL, 0,
    test_layout_handler, "I", "MSRPM offsets against APM 15.11 (write 1)");
SYSCTL_PROC(_hw_vmm_svm_nested, OID_AUTO, test_lbr,
    CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_MPSAFE, NULL, 0,
    test_lbr_handler, "I", "LBR MSR range interception (write 1)");

static int
svm_nested_test_modevent(module_t mod, int type, void *unused)
{

	switch (type) {
	case MOD_LOAD:
	case MOD_UNLOAD:
		return (0);
	default:
		return (EOPNOTSUPP);
	}
}

static moduledata_t svm_nested_test_mod = {
	.name = "svm_nested_test",
	.evhand = svm_nested_test_modevent,
	.priv = NULL,
};

DECLARE_MODULE(svm_nested_test, svm_nested_test_mod, SI_SUB_PSEUDO,
    SI_ORDER_ANY);
MODULE_DEPEND(svm_nested_test, vmm, 1, 1, 1);
