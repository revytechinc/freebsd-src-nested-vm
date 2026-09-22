#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
# All rights reserved.
#
# Wave 7 / T39 — Nested-virt ABI snapshot test.
#
# Builds the L0 dump helper (abisnap_dump) and integrates
# the abisnap.sh test into the FreeBSD kyua test runner.
#
# Build target: abisnap_dump
#   - links against libvmmapi (added in wave 1)
#   - produces /usr/tests/sys/vmm/nested/abisnap/abisnap_dump
#   - writes the live ABI snapshot to stdout for diff against
#     the committed golden file
#
# Test target: abisnap
#   - runs abisnap.sh --self-check (always)
#   - if the dump helper is built, also runs abisnap.sh --check


PACKAGE=	nested-tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/abisnap
BINDIR=		${TESTSDIR}

# abisnap.sh is NOT the ATF test, whatever this comment used to say. It is a
# tool: it parses --check / --regen-golden / --self-check and contains no
# atf_test_case at all. Registered as ATF_TESTS_SH it was handed `-l' by kyua
# to list its cases, its argument parser rejected the flag, and it exited
# non-zero before printing anything kyua could read -- "broken: Test program
# did not exit cleanly". That went unnoticed because this directory was not
# reachable from any Kyuafile until now.
#
# So the tool is installed as a file and abisnap_test.sh provides the atf
# surface, which is how the rest of the tree separates the two. It also keeps
# --regen-golden available by hand: regenerating a golden file is not
# something a test run should ever do.
#
# (This Makefile also used to declare PROG=abisnap_dump from abisnap_dump.c,
# which does not exist in the tree -- invisible until the directory was wired
# into the build.)
ATF_TESTS_SH+=	abisnap_test

${PACKAGE}FILES+=	abisnap.sh
${PACKAGE}FILESMODE_abisnap.sh=	0555
${PACKAGE}FILES+=	golden_abisnap.txt

.include <bsd.test.mk>
