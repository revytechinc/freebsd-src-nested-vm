#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# The privileged launchers and the driver they run. These are installed
# root-owned outside the tests tree by install_demo_kit.sh; they are carried
# here so that the version on a host can always be traced to a commit.

PACKAGE=	nested-tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/demo/libexec
BINDIR=		${TESTSDIR}

${PACKAGE}FILES+=	demo-banner
${PACKAGE}FILES+=	nested-demo.sh
${PACKAGE}FILES+=	run-auto-demo
${PACKAGE}FILES+=	run-auto-demo-all-cores
${PACKAGE}FILES+=	run-stepthrough
${PACKAGE}FILES+=	stepthrough-boot.sh
${PACKAGE}FILES+=	watchdog-common

.include <bsd.test.mk>
