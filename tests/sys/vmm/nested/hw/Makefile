#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Wire this directory into the build so its tests ship in the tests package
# with the release. A harness that is copied onto hosts by hand drifts out of
# step with the kernel it is meant to be testing.


PACKAGE=	tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/hw
BINDIR=		${TESTSDIR}

ATF_TESTS_SH+=	run_exit_plumbing_tests

${PACKAGE}FILES+=	hw_test_common.sh
${PACKAGE}FILES+=	nested_utils.subr

# TESTS_SUBDIRS, not SUBDIR: see the note in ../Makefile.  These three
# hold the only tests in this tree that actually boot bhyve, and with
# SUBDIR they installed to /usr/tests and were never discovered.
TESTS_SUBDIRS+=	exit_plumbing
TESTS_SUBDIRS+=	preflight
TESTS_SUBDIRS+=	stress

.include <bsd.test.mk>
