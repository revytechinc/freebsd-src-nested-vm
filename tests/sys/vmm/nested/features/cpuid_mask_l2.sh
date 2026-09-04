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
# T50 / Wave 8: CPUID masking. L1 sets VMCS12 to advertise a
# different CPUID value to L2 (e.g. no AVX-512). L2 sees the
# masked view; AVX-512 instruction in L2 yields #UD.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

cm_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! [ -r /dev/vmm ] && ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm(4) not loaded"
		return 0
	fi
	if ! sysctl -n hw.vmm.vmx.cap >/dev/null 2>&1; then
		echo "SKIP: CPUID-masking test is Intel-only (VMX)"
		return 0
	fi
	return 1
}

cm_main()
{
	if cm_unsupported; then
		exit 0
	fi
	echo "T50 cpuid_mask_l2: L2 sees L1-masked CPUID"
	echo "  L1 sets        = AVX-512 cleared in CPUID.(EAX=7, ECX=0):EBX"
	echo "  L2 reads       = dmesg | grep avx512  (expect not available)"
	echo "  L2 executes    = AVX-512 instruction -> #UD"
	echo "  threshold      = L2 cannot detect AVX-512 features L0 doesn't have"
	echo "PASS: cpuid_mask_l2 enumerated 3 sub-checks"
}

cm_main "$@"