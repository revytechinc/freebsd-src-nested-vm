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

# run_exit_plumbing_tests is GONE, not moved.
#
# It was registered here as an atf test and could never have worked. Its
# runner loop ran at TOP LEVEL, so merely asking the program to list its test
# cases executed the whole loop; it was bash (mapfile, <<<, (( ))) while
# atf-sh runs a test program with /bin/sh; and it re-invoked itself with
# `bash "$0"'. kyua reported all of that as "broken: Test program did not exit
# cleanly", which names neither a shell nor a line.
#
# It also ended with an UNCONDITIONAL
#
#	printf 'PASS: 14/14 device classes, 0 data corruption, 0 interrupts lost'
#
# Nothing in it measured data corruption or lost interrupts, and the count was
# a literal. A check that prints a specific pass regardless of what ran is
# worse than no check.
#
# Nothing is lost by removing it: the 14 exit_plumbing tests it wrapped are
# now registered individually (see the TESTS_SUBDIRS note in the parent
# Makefile), so kyua runs them directly and reports a real result per device
# class instead of one summary line. `kyua test hw/exit_plumbing' is the
# equivalent command. The separate manual driver at
# exit_plumbing/run_exit_plumbing_tests.sh is a different, POSIX file and is
# untouched.

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
