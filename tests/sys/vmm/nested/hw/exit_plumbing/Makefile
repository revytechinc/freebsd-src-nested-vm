#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Wire this directory into the build so its tests ship in the tests package
# with the release. A harness that is copied onto hosts by hand drifts out of
# step with the kernel it is meant to be testing.


PACKAGE=	tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/hw/exit_plumbing
BINDIR=		${TESTSDIR}

ATF_TESTS_SH+=	acpi_pm_test
ATF_TESTS_SH+=	hpet_test
ATF_TESTS_SH+=	ioapic_test
ATF_TESTS_SH+=	lapic_ipi_test
ATF_TESTS_SH+=	lapic_test
ATF_TESTS_SH+=	msi_test
ATF_TESTS_SH+=	pci_cfg_test
ATF_TESTS_SH+=	pic_test
ATF_TESTS_SH+=	pit_test
ATF_TESTS_SH+=	rtc_test
ATF_TESTS_SH+=	uart_test
ATF_TESTS_SH+=	virtio_blk_test
ATF_TESTS_SH+=	virtio_console_test
ATF_TESTS_SH+=	virtio_rnd_test

${PACKAGE}FILES+=	run_exit_plumbing_tests.sh

.include <bsd.test.mk>
