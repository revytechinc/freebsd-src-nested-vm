#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Wire this directory into the build so its tests ship in the tests package
# with the release. A harness that is copied onto hosts by hand drifts out of
# step with the kernel it is meant to be testing.


PACKAGE=	tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/hw/stress
BINDIR=		${TESTSDIR}

ATF_TESTS_SH+=	acpi_powerbutton_stress_test
ATF_TESTS_SH+=	ahci_stress_test
ATF_TESTS_SH+=	dma_nested_paging_stress_test
ATF_TESTS_SH+=	e1000_stress_test
ATF_TESTS_SH+=	hda_stress_test
ATF_TESTS_SH+=	nvme_stress_test
ATF_TESTS_SH+=	pci_hotplug_stress_test
ATF_TESTS_SH+=	virtio_net_stress_test
ATF_TESTS_SH+=	virtio_scsi_stress_test
ATF_TESTS_SH+=	xhci_stress_test

${PACKAGE}FILES+=	run_stress_tests.sh

.include <bsd.test.mk>
