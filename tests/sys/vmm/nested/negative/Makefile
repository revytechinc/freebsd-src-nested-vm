#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Wire this directory into the build so its tests ship in the tests package
# with the release. A harness that is copied onto hosts by hand drifts out of
# step with the kernel it is meant to be testing.


PACKAGE=	nested-tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/negative
BINDIR=		${TESTSDIR}

${PACKAGE}FILES+=	escape_negative.sh
${PACKAGE}FILES+=	msr_negative.sh
${PACKAGE}FILES+=	nested_off.sh
${PACKAGE}FILES+=	svm_negative.sh
${PACKAGE}FILES+=	vmx_negative.sh

.include <bsd.test.mk>
