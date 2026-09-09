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
${PACKAGE}FILES+=	boot_artifact.sh
${PACKAGE}FILES+=	run_release_round.sh
${PACKAGE}FILES+=	nested_l2_inguest.sh
${PACKAGE}FILES+=	verify_media_nested.sh
${PACKAGE}FILES+=	run_full_regression.sh
${PACKAGE}FILES+=	run_l2_smoke.sh
${PACKAGE}FILES+=	run_vm_boot_gate.sh
${PACKAGE}FILES+=	verify_stock_install.sh
${PACKAGE}FILES+=	verify_upgrade.sh
${PACKAGE}FILES+=	run_published_gates.sh
${PACKAGE}FILES+=	check_artifacts.sh
${PACKAGE}FILES+=	check_internal_tls.sh
${PACKAGE}FILES+=	check_public_endpoints.sh
${PACKAGE}FILES+=	check_release_contract.sh
${PACKAGE}FILES+=	run_nested_demo.sh
${PACKAGE}FILES+=	build_release_media.sh
${PACKAGE}FILES+=	stage_release_artifacts.sh
${PACKAGE}FILES+=	gen_release_manifest.sh
${PACKAGE}FILES+=	gen_release_manifest.py
${PACKAGE}FILES+=	publish_release.sh

# bsd.files.mk gives a FILES group SHAREMODE, and a 0444 script cannot be
# executed -- not even by root, which needs at least one x bit set.  Nearly
# everything here is a script that gets run, including one that runs INSIDE a
# release image to start the inner guest, so shipping them unexecutable fails
# the release gate at its last step and reports it as "the nested guest never
# booted".  Set the mode for the whole group rather than per file: a per-file
# list has to be kept in step with the list above by hand, and a script added
# without its line reproduces exactly this bug.  The manual page is the one
# member that is data, not a program.
${PACKAGE}FILESMODE=	0555
${PACKAGE}FILESMODE_disable-panic-debugger.8=	0444

.include <bsd.test.mk>
