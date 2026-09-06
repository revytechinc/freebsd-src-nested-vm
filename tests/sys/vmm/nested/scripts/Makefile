#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Wire this directory into the build so its tests ship in the tests package
# with the release. A harness that is copied onto hosts by hand drifts out of
# step with the kernel it is meant to be testing.


PACKAGE=	tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/scripts
BINDIR=		${TESTSDIR}

${PACKAGE}FILES+=	activate_oneshot_be.sh
${PACKAGE}FILES+=	build_artifacts.sh
${PACKAGE}FILES+=	build_l2_image.sh
${PACKAGE}FILES+=	build_packages.sh
${PACKAGE}FILES+=	disable-panic-debugger.8
${PACKAGE}FILES+=	disable-panic-debugger.sh
${PACKAGE}FILES+=	disable-vmm-autoload.sh
${PACKAGE}FILES+=	enable-fail-watchdog.sh
${PACKAGE}FILES+=	run_full_regression.sh
${PACKAGE}FILES+=	run_l2_smoke.sh
${PACKAGE}FILES+=	run_vm_boot_gate.sh

.include <bsd.test.mk>
