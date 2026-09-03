#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 The FreeBSD Foundation
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# Wave 7 / T40 nested-virt fuzz harness build glue.
#
# ATF_C_TESTS_C marks fuzz_all as a compiled ATF test program that kyua(1)
# will run on the FreeBSD test box.  On the Linux dev box the source is
# carried as the contract for the remote build; the `make` invocation here
# requires libatf-c, libvmmapi and bhyve ioctl headers that only exist on
# the FreeBSD test box (see ../README.test for the build invocation).
#
# The wrapper script fuzz_all.sh is the operator-facing entry point on the
# remote box; it spawns fuzz_all under kyua and asserts the L1 integrity
# post-condition (see Acceptance Criteria in the plan).

PACKAGE=	tests

TESTSDIR=	${TESTSBASE}/sys/vmm/nested/fuzz

ATF_TESTS_SH+=	fuzz_all
ATF_TESTS_C+=	fuzz_all

WARNS?=		6

.include <bsd.test.mk>
