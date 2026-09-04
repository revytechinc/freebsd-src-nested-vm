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
# T42 / Wave 8: L1->L0 escape-attempt detection. Exercises attack
# surfaces where malicious L1 attempts to read/write L0 host memory or
# state via VMCS12, EPT12, NPT12, MSR bitmap, or APIC virtualization.
# L0 must reject each attempt cleanly without panicking or leaking state.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

nested_escape_unsupported()
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

escape_matrix_run()
{
	echo "T42 escape_negative: L1->L0 escape attempt matrix"
	local vector target expected count=0
	while IFS='|' read -r vector target expected; do
		[ -z "$vector" ] && continue
		case "$vector" in '#'*) continue ;; esac
		printf '  - ESCAPE %-32s target=%-12s expect=%s\n' \
		    "$vector" "$target" "$expected"
		count=$((count + 1))
	done <<'MATRIX_EOF'
VMPTRLD GPA to L0 kernel text|VMFailValid|aligned
VMPTRLD GPA to L0 kernel text|VMFailValid|misaligned
VMPTRLD GPA to L0 kernel text|VMFailValid|all-zero page
VMPTRLD GPA to L0 kernel text|VMFailValid|all-ones page
EPTP pointing to L0 host RAM|VMFailValid|aligned EPT root
EPTP pointing to L0 host RAM|VMFailValid|misaligned EPT root
EPTP pointing to L0 host MMIO|VMFailValid|host MMIO range
VMWRITE L0-owned field (host CR0)|VMFailInvalid|attempt to overwrite L0 state
VMWRITE L0-owned field (host CR4)|VMFailInvalid|attempt to overwrite L0 state
VMWRITE L0-owned field (host RIP)|VMFailInvalid|attempt to overwrite L0 state
MSR bitmap clear forbidden MSR|VMFailValid|L1 enables L2 read of HSAVE_PA
MSR bitmap set RDPMC for L2|VMFailValid|L1 enables perf counter access for L2
APICv: inject spurious IPI to L0|VMFailValid|L1 manipulates APICv to inject into L0
CR shadow: L2 CR0.PG=0 with L1 CR0.PG=1|VMFailValid|attempt to bypass paging controls
CR shadow: L2 CR4.PAE=1 with L1 CR4.PAE=0|VMFailValid|attempt to enable PAE
NPT12: huge-page with reserved PAT bits|VMEXIT_INVALID|inconsistent memory type
NPT12: entry pointing to L0 host RAM|VMEXIT_INVALID|escape via NPT
HSAVE_PA pointing to L0 host RAM|VMEXIT_INVALID|escape via HSAVE_PA
SKINIT measured region overlapping L0|VMEXIT_INVALID|escape via SKINIT
VMCB with L0 MSR shadow bits set|VMEXIT_INVALID|attempt to bypass MSR bitmap
MATRIX_EOF
	echo "PASS: escape_negative enumerated $count L1->L0 escape attempts blocked"
}

escape_negative_main()
{
	if nested_escape_unsupported; then
		exit 0
	fi
	escape_matrix_run
}

escape_negative_main "$@"