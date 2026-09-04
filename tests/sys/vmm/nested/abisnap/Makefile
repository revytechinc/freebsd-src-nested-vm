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

ATF_TESTS_SH+=	abisnap

${PACKAGE}FILES+=	abisnap.sh
${PACKAGE}FILES+=	golden_abisnap.txt

# The L0 dump helper.  Built from sys/amd64/vmm/test/abisnap_dump.c
# (added in a follow-up wave) and installed into the test dir so
# the script can find it via $DUMP_BIN.
PROG=		abisnap_dump
MAN=
SRCS+=		abisnap_dump.c
DPADD+=		${LIBVMMAPI}
LDADD+=		-lvmmapi
WARNS?=		6

.include <bsd.prog.mk>
