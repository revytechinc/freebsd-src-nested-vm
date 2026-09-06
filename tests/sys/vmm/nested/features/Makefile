#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Wire this directory into the build so its tests ship in the tests package
# with the release. A harness that is copied onto hosts by hand drifts out of
# step with the kernel it is meant to be testing.


PACKAGE=	tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/features
BINDIR=		${TESTSDIR}

${PACKAGE}FILES+=	cpuid_mask_l2.sh
${PACKAGE}FILES+=	efer_l2.sh
${PACKAGE}FILES+=	la57_l2.sh
${PACKAGE}FILES+=	mtrr_l2.sh
${PACKAGE}FILES+=	pat_l2.sh
${PACKAGE}FILES+=	xsave_l2.sh

.include <bsd.test.mk>
