#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Wire this directory into the build so its tests ship in the tests package
# with the release. A harness that is copied onto hosts by hand drifts out of
# step with the kernel it is meant to be testing.


PACKAGE=	tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/io
BINDIR=		${TESTSDIR}

${PACKAGE}FILES+=	buildkernel_l2.sh
${PACKAGE}FILES+=	fio_l2.sh
${PACKAGE}FILES+=	hotplug_l2.sh
${PACKAGE}FILES+=	iperf_l2.sh
${PACKAGE}FILES+=	mmio_l2.sh
${PACKAGE}FILES+=	nvme_l2.sh

.include <bsd.test.mk>
