#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# The hands-on demo kit ships with the build it demonstrates, for the same
# reason the tests do: a copy placed on a host by hand drifts out of step with
# the kernel underneath it, and a stale copy fails a working kernel in a way
# that reads as a hypervisor defect.

PACKAGE=	tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/demo
BINDIR=		${TESTSDIR}

${PACKAGE}FILES+=	install_demo_kit.sh
${PACKAGE}FILES+=	patch_demo_image.sh
${PACKAGE}FILES+=	patch_l1_relay.sh
${PACKAGE}FILES+=	patch_l2_spin.sh

SUBDIR+=	home
SUBDIR+=	libexec

.include <bsd.test.mk>
