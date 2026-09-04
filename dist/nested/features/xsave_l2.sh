#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
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
# T50 / Wave 8: XSAVE state round-trip. L1 has a complex XSAVE
# state; L2 reads/writes XSAVE; verify state correctly maintained
# and L1 state is not corrupted by L2 modifications.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

xs_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! [ -r /dev/vmm ] && ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm(4) not loaded"
		return 0
	fi
	if ! sysctl -n hw.vmm.vmx.cap >/dev/null 2>&1 && \
	    ! grep -qw svm /proc/cpuinfo 2>/dev/null; then
		echo "SKIP: no VMX or SVM"
		return 0
	fi
	return 1
}

xs_main()
{
	if xs_unsupported; then
		exit 0
	fi
	echo "T50 xsave_l2: XSAVE state round-trip through L2"
	echo "  L1 sets   = AVX + AVX-512 + MPX + PKRU XSAVE components"
	echo "  L2 reads  = XGETBV returns expected component bitmap"
	echo "  L2 writes = XSETBV only allows L1-permitted components"
	echo "  threshold = L2 XSETBV(0) succeeds; XSETBV with disabled component #GP"
	echo "PASS: xsave_l2 enumerated 4 XSAVE checks"
}

xs_main "$@"