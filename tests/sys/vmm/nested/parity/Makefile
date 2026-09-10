#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Wire this directory into the build so its tests ship in the tests package
# with the release. A harness that is copied onto hosts by hand drifts out of
# step with the kernel it is meant to be testing.


PACKAGE=	nested-tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/parity
BINDIR=		${TESTSDIR}

${PACKAGE}FILES+=	PARITY.md
${PACKAGE}FILES+=	cpuid_vectors.txt
${PACKAGE}FILES+=	exit_reason_vectors.txt
${PACKAGE}FILES+=	kvm_parity_check.sh
${PACKAGE}FILES+=	vmcb_vectors.txt
${PACKAGE}FILES+=	vmcs_vectors.txt

.include <bsd.test.mk>
