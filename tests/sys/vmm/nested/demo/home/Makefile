#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# The six scripts a person actually types. install_demo_kit.sh copies these
# into a user's home directory; they are thin wrappers on purpose, so that what
# someone reads before running it is short enough to read.

PACKAGE=	tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/demo/home
BINDIR=		${TESTSDIR}

${PACKAGE}FILES+=	0-what-can-this-host-do.sh
${PACKAGE}FILES+=	1-run-nested-demo.sh
${PACKAGE}FILES+=	2-step-through.sh
${PACKAGE}FILES+=	3-run-nested-demo-all-cores.sh
${PACKAGE}FILES+=	4-find-the-core-ceiling.sh
${PACKAGE}FILES+=	5-many-nested-at-once.sh
${PACKAGE}FILES+=	README

.include <bsd.test.mk>
