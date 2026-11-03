#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.

PACKAGE=	tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/lib
BINDIR=		${TESTSDIR}

# The verdict contract and its self-tests.  The self-tests are shipped
# deliberately: a harness whose own guard rails cannot be re-checked on
# the machine that runs it is a harness nobody can audit.
${PACKAGE}FILES+=	nested_verdict.subr
${PACKAGE}FILES+=	nested_verdict_selftest.sh
${PACKAGE}FILES+=	nested_runner_selftest.sh
${PACKAGE}FILES+=	nested_wiring_selftest.sh
${PACKAGE}FILES+=	gaps.tsv

.include <bsd.test.mk>
