#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Wire this directory into the build so its tests ship in the tests package
# with the release. A harness that is copied onto hosts by hand drifts out of
# step with the kernel it is meant to be testing.


PACKAGE=	nested-tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/resource
BINDIR=		${TESTSDIR}

${PACKAGE}FILES+=	asid_exhaust_test.sh
${PACKAGE}FILES+=	max_vcpu_test.sh
${PACKAGE}FILES+=	memory_limit_test.sh
${PACKAGE}FILES+=	multi_vm_test.sh
${PACKAGE}FILES+=	vpid_exhaust_test.sh

.include <bsd.test.mk>
