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
# Wave 7 / T41 nested-virt performance regression test build glue.
#
# The shell scripts in this directory are operator-facing harnesses
# (not ATF), per the plan's "Test-first" + free-floating operator
# script pattern (matches T37's bhyve_in_bhyve.sh model).  The
# baseline.txt artifact is committed and MUST be present on the
# test box; perf_regression.sh refuses to skip when it is missing.
#
# Files installed under ${TESTSBASE}/sys/vmm/nested/perf:
#   perf_microbench.sh    CPUID / RDMSR / VMEXIT hot-path rates
#   perf_regression.sh    hot-path + macro <2% regression check
#   perf_nested.sh        nested-L1 macrobench (informational)
#   baseline.txt          MANDATORY committed reference numbers

PACKAGE=	tests

TESTSDIR=	${TESTSBASE}/sys/vmm/nested/perf

FILES+=		perf_microbench.sh
FILES+=		perf_regression.sh
FILES+=		perf_nested.sh
FILES+=		baseline.txt

# No ATF_C / ATF_SH tests; the scripts are operator-invoked.
# They do not consume libatf-c / libvmmapi; kyua just installs them.

.include <bsd.test.mk>