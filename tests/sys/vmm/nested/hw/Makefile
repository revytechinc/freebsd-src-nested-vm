#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Wire this directory into the build so its tests ship in the tests package
# with the release. A harness that is copied onto hosts by hand drifts out of
# step with the kernel it is meant to be testing.


PACKAGE=	nested-tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/hw
BINDIR=		${TESTSDIR}

ATF_TESTS_SH+=	run_exit_plumbing_tests

${PACKAGE}FILES+=	hw_test_common.sh
${PACKAGE}FILES+=	nested_utils.subr

# exit_plumbing (14 test programs) and stress (10) register ATF tests, so they
# need TESTS_SUBDIRS for the generated Kyuafile to include them -- see the long
# note in the parent Makefile. Under plain SUBDIR they were installed and
# unreachable.
#
# preflight stays SUBDIR: it declares no test programs, only shell drivers
# installed as FILES and run by hand. An include for its Kyuafile would point
# at a file that declares nothing.
TESTS_SUBDIRS+=	exit_plumbing
TESTS_SUBDIRS+=	stress

SUBDIR+=	preflight

.include <bsd.test.mk>
