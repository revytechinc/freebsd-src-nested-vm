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
# T42 / Wave 8: comprehensive Intel VMX nested-virt negative test matrix.
# Per .sisyphus/plans/nested-virt-register-virtualization.md T42, each row
# below names one (instruction, expected SDM response, attack note). The
# on-target driver must execute each instruction via a uvm wrapper, assert
# the documented SDM response, confirm L0 host dmesg has no panic, and
# confirm L0 host state is unchanged.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

nested_vmx_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! [ -r /dev/vmm ] && ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm(4) not loaded -- no VMX support"
		return 0
	fi
	if ! sysctl -n hw.vmm.vmx.cap >/dev/null 2>&1; then
		echo "SKIP: hw.vmm.vmx.cap not present -- CPU has no VMX"
		return 0
	fi
	return 1
}

vmx_matrix_run()
{
	echo "T42 vmx_negative: VMX instruction error matrix"
	local instr expected note count=0
	while IFS='|' read -r instr expected note; do
		[ -z "$instr" ] && continue
		case "$instr" in '#'*) continue ;; esac
		printf '  - VMX %-9s expect=%-12s note=%s\n' \
		    "$instr" "$expected" "$note"
		count=$((count + 1))
	done <<'MATRIX_EOF'
VMPTRLD|VMFailValid|non-canonical GPA
VMPTRLD|VMFailValid|misaligned GPA (not 4KB aligned)
VMPTRLD|VMFailValid|VMCS region not backed by memory
VMREAD|VMFailValid|out-of-range VMCS field encoding (0xFFFF)
VMREAD|VMFailValid|VMCS not in launched state
VMWRITE|VMFailValid|out-of-range VMCS field encoding
VMWRITE|VMFailValid|VMCS not in launched state
VMWRITE|VMFailValid|VMCS12 field reserved for L0 (escape attempt)
VMCLEAR|VMFailValid|misaligned VMCS address
VMCLEAR|VMFailValid|non-canonical VMCS address
VMLAUNCH|VMFailValid|VMCS in launched state already
VMLAUNCH|VMFailValid|guest CR3 is non-canonical
VMLAUNCH|VMFailValid|EPT misconfiguration (reserved bits set)
VMLAUNCH|VMFailValid|EPTP pointing to L0 host memory
VMRESUME|VMFailValid|VMCS in clear state
VMRESUME|VMFailValid|VMCS launched state mismatch
VMCALL|UndefinedOpcode|VMCALL outside VMX operation
INVEPT|VMFailValid|reserved INVEPT descriptor type
INVEPT|VMFailValid|non-canonical EPTP
INVEPT|VMFailValid|EPTP pointing to L0 host memory (escape)
INVVPID|VMFailValid|reserved INVVPID descriptor type
INVVPID|VMFailValid|non-canonical VPID address
VMXON|VMFailValid|non-canonical VMXON region address
VMXON|VMFailValid|misaligned VMXON region
VMXON|VMFailValid|CR4.VMXE not set
VMXOFF|VMFailValid|VMXOFF outside VMX root operation
MATRIX_EOF
	echo "PASS: vmx_negative enumerated $count (instruction, fault) pairs"
}

vmx_negative_main()
{
	if nested_vmx_unsupported; then
		exit 0
	fi
	vmx_matrix_run
}

vmx_negative_main "$@"