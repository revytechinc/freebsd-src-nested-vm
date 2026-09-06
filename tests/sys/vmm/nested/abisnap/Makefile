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


PACKAGE=	tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/abisnap
BINDIR=		${TESTSDIR}

# abisnap.sh is the ATF test; ATF_TESTS_SH installs the script itself, so it
# must not also be listed in FILES. The Makefile also used to declare
# PROG=abisnap_dump from abisnap_dump.c, which does not exist in the tree --
# invisible until this directory was wired into the build.
ATF_TESTS_SH+=	abisnap

${PACKAGE}FILES+=	golden_abisnap.txt

.include <bsd.test.mk>
