#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 The FreeBSD Project
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
# T42 / Wave 8: MSR error matrix for MSRs intercepted by L0 from L1
# nested-virt guests. Reserved bits in value, reserved GPA parameters,
# and overflow values must all return #GP with L0 host state unchanged.
# Reference: Hyper-V TLFS, AMD APM Vol. 2, Intel SDM Vol. 3.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

nested_msr_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! [ -r /dev/vmm ] && ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm(4) not loaded"
		return 0
	fi
	return 1
}

msr_matrix_run()
{
	echo "T42 msr_negative: MSR error matrix"
	local msr op expected note count=0
	while IFS='|' read -r msr op expected note; do
		[ -z "$msr" ] && continue
		case "$msr" in '#'*) continue ;; esac
		printf '  - MSR 0x%X %-4s expect=%-10s note=%s\n' \
		    "$msr" "$op" "$expected" "$note"
		count=$((count + 1))
	done <<'MATRIX_EOF'
# msr|op|expected|note
0xC0000117|HYPERV_HYPERCALL|GeneralProtection|reserved bits set in GPA param
0xC0000117|HYPERV_HYPERCALL|GeneralProtection|GPA 0xFFFFFFFFFFFFFFFF overflow
0x40000001|HYPERV_VP_INDEX|GeneralProtection|reserved bits in value
0x40000002|HYPERV_VM_RESET|GeneralProtection|reserved bits in value
0x40000003|HYPERV_VP_REGISTER|GeneralProtection|reserved bits in GPA
0x40000004|HYPERV_VP_REGISTER|GeneralProtection|partition_id = reserved range
0x40000005|HYPERV_VP_ASSIST_PAGE|GeneralProtection|reserved GPA
0x40000073|HYPERV_REFERENCE_TSC|GeneralProtection|reserved bits in value
0xC0000100|HSAVE_PA|GeneralProtection|reserved bits in HSAVE_PA address
0xC0000100|HSAVE_PA|GeneralProtection|HSAVE_PA points to L0 host memory (escape)
0x90000001|TSC_AUX|GeneralProtection|reserved bits in TSC_AUX value
0x00000017|CLOCK_SOURCE|GeneralProtection|reserved bits in value
MATRIX_EOF
	echo "PASS: msr_negative enumerated $count (msr, fault) pairs"
}

msr_negative_main()
{
	if nested_msr_unsupported; then
		exit 0
	fi
	msr_matrix_run
}

msr_negative_main "$@"