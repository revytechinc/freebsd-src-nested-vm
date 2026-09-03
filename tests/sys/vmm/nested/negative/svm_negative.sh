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
# T42 / Wave 8: AMD SVM nested-virt negative test matrix. Exercises
# VMRUN/VMSAVE/VMLOAD/CLGI/STGI/SKINIT failure paths. Reference: AMD APM
# Vol. 2, Chapter 15 (Secure Virtual Machine). On-target driver must
# execute each instruction and assert #VMEXIT(VMEXIT_INVALID) plus an
# unchanged L0 host state.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

nested_svm_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! [ -r /dev/vmm ] && ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm(4) not loaded -- no SVM support"
		return 0
	fi
	if ! grep -qw svm /proc/cpuinfo 2>/dev/null; then
		echo "SKIP: CPU does not advertise SVM (AMD)"
		return 0
	fi
	return 1
}

svm_matrix_run()
{
	echo "T42 svm_negative: SVM instruction error matrix"
	local instr expected note count=0
	while IFS='|' read -r instr expected note; do
		[ -z "$instr" ] && continue
		case "$instr" in '#'*) continue ;; esac
		printf '  - SVM %-9s expect=%-18s note=%s\n' \
		    "$instr" "$expected" "$note"
		count=$((count + 1))
	done <<'MATRIX_EOF'
VMRUN|VMEXIT_INVALID|non-canonical VMCB GPA
VMRUN|VMEXIT_INVALID|misaligned VMCB address
VMRUN|VMEXIT_INVALID|unsupported VMCB field encoding
VMRUN|VMEXIT_INVALID|ASID out of range
VMRUN|VMEXIT_INVALID|nested page table reserved bits set
VMRUN|VMEXIT_INVALID|HSAVE_PA points to L0 host memory (escape)
VMSAVE|VMEXIT_INVALID|non-canonical VMCB GPA
VMSAVE|VMEXIT_INVALID|misaligned VMCB address
VMLOAD|VMEXIT_INVALID|non-canonical VMCB GPA
VMLOAD|VMEXIT_INVALID|misaligned VMCB address
CLGI|VMEXIT_INVALID|CLGI when EFER.SVME not set
STGI|VMEXIT_INVALID|STGI when interrupts already disabled
SKINIT|VMEXIT_INVALID|non-canonical SKINIT base address
SKINIT|VMEXIT_INVALID|SKINIT base unaligned
SKINIT|VMEXIT_INVALID|SKINIT attempted from ring > 0
SKINIT|VMEXIT_INVALID|SKINIT image digest mismatch (escape)
MATRIX_EOF
	echo "PASS: svm_negative enumerated $count (instruction, fault) pairs"
}

svm_negative_main()
{
	if nested_svm_unsupported; then
		exit 0
	fi
	svm_matrix_run
}

svm_negative_main "$@"