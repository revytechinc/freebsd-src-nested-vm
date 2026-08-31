#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# preflight_vmcs_shadowing_scoped: L1's VMCS must never reach hardware.
#
# The nested-VMX code emulates VMREAD/VMWRITE against a private copy of
# L1's VMCS (vcpu->nvmcs12). This test pins the properties that keep
# L1-supplied values away from the hardware VMCS:
#
#   - no nested source enables PROCBASED2_VMCS_SHADOWING or writes
#     VMCS_LINK_POINTER;
#   - VMREAD/VMWRITE decode their operands from the VM-exit
#     instruction-information field, not from fixed registers;
#   - the VM-exit information fields are read-only to L1 (VMWRITE gives
#     VM-instruction error 13);
#   - the private copy is written back to L1 memory before the current
#     VMCS changes (VMPTRLD of another VMCS, VMCLEAR, VMXOFF).

set -u
PROGRAM="${0##*/}"
: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
INTEL="${repo_root}/sys/amd64/vmm/intel"

fail()
{
	echo "FAIL: $*"
	exit 1
}

[ -r "${INTEL}/vmx_nested_vmread.c" ] || { echo "SKIP: nested sources absent"; exit 0; }

grep -l 'PROCBASED2_VMCS_SHADOWING\|VMCS_LINK_POINTER,' "${INTEL}"/vmx_nested_*.c 2>/dev/null |
	grep -v vmx_nested_layout.c | grep -q . &&
	fail "nested code programs VMCS shadowing / link pointer"

grep -q 'VMCS_EXIT_INSTRUCTION_INFO' "${INTEL}/vmx_nested_vmread.c" ||
	fail "VMREAD/VMWRITE do not decode operands from instruction info"
grep -q 'VMCS_EXIT_INSTRUCTION_INFO' "${INTEL}/vmx_nested_insn.c" ||
	fail "memory operand decoder does not use instruction info"
grep -Eq 'guest_rcx & 0xFFFFFFFF' "${INTEL}/vmx_nested_vmread.c" &&
	fail "VMREAD/VMWRITE still assume RCX/RDX operands"

grep -q 'VMX_INSERR_VMWRITE_READONLY' "${INTEL}/vmx_nested_vmread.c" ||
	fail "VMWRITE to read-only fields is not rejected"
grep -q 'RO32(VMCS_EXIT_REASON)' "${INTEL}/vmx_nested_layout.c" ||
	fail "exit reason is not marked read-only in the VMCS12 layout"

for f in vmx_nested_vmptrld.c vmx_nested_vmclear.c vmx_nested_insn.c; do
	grep -q 'vmx_nested_flush_vmcs12' "${INTEL}/${f}" ||
		fail "${f} does not flush the private VMCS12 copy"
done

echo "PASS: ${PROGRAM%.sh} L1 VMCS never reaches hardware"
exit 0
