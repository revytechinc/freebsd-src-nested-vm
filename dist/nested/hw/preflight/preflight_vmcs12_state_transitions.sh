#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# preflight_vmcs12_state_transitions: source-level invariants of the
# nested-VMX VMCS12 state machine.
#
#   - the vmcs12_state enum keeps NONE=0 / CLEAR / LAUNCHED;
#   - VMPTRLD derives the state from the VMCS's launch state and never
#     touches the hardware VMCS that runs L1 (no VMPTRLD/VMCLEAR of
#     vcpu->vmcs, no VMCS shadowing);
#   - VMCLEAR of the current VMCS drops it (STATE_NONE);
#   - VMLAUNCH/VMRESUME check CLEAR/LAUNCHED respectively and, as long
#     as no VMCS02 exists, deliver a VM-entry failure to L1 instead of
#     copying VMCS12 fields into the active VMCS;
#   - VMCALL from L1 never changes the launch state.

set -u
PROGRAM="${0##*/}"
: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
INTEL="${repo_root}/sys/amd64/vmm/intel"
VMX_NESTED_H="${INTEL}/vmx_nested.h"
VMPTRLD="${INTEL}/vmx_nested_vmptrld.c"
VMLAUNCH="${INTEL}/vmx_nested_vmlaunch.c"
VMCALL="${INTEL}/vmx_nested_vmcall.c"
VMCLEAR="${INTEL}/vmx_nested_vmclear.c"

fail()
{
	echo "FAIL: $*"
	exit 1
}

if [ ! -r "${VMX_NESTED_H}" ]; then
	echo "SKIP: ${VMX_NESTED_H} not present"
	exit 0
fi

body=$(awk '/enum[[:space:]]+vmcs12_state[[:space:]]*{/ { f=1; next }
	f && /^[[:space:]]*};/ { f=0 } f { print }' "${VMX_NESTED_H}")
[ -n "${body}" ] || fail "vmcs12_state enum body not found"
printf '%s\n' "${body}" | grep -Eq 'VMCS12_STATE_NONE[[:space:]]*=[[:space:]]*0' ||
	fail "VMCS12_STATE_NONE != 0"
printf '%s\n' "${body}" | grep -q 'VMCS12_STATE_CLEAR' || fail "VMCS12_STATE_CLEAR missing"
printf '%s\n' "${body}" | grep -q 'VMCS12_STATE_LAUNCHED' || fail "VMCS12_STATE_LAUNCHED missing"

grep -q 'launch_state == VMCS12_LAUNCHED' "${VMPTRLD}" ||
	fail "VMPTRLD does not derive the state from the VMCS launch state"
grep -Eq 'VMPTRLD\(vcpu->vmcs\)|VMCLEAR\(vcpu->vmcs\)|VMCLEAR\(vmcs\)' "${VMPTRLD}" &&
	fail "VMPTRLD emulation touches the hardware VMCS"
grep -q 'PROCBASED2_VMCS_SHADOWING' "${INTEL}"/vmx_nested_*.c &&
	fail "nested code enables VMCS shadowing"

grep -q 'VMCS12_STATE_NONE' "${VMCLEAR}" || fail "VMCLEAR does not drop the current VMCS"

grep -q 'VMX_INSERR_VMLAUNCH_NOT_CLEAR' "${VMLAUNCH}" ||
	fail "VMLAUNCH does not reject a non-CLEAR VMCS"
grep -q 'VMX_INSERR_VMRESUME_NOT_LAUNCHED' "${VMLAUNCH}" ||
	fail "VMRESUME does not reject a non-LAUNCHED VMCS"
grep -q 'vmx_nested_shadow_apply' "${VMLAUNCH}" &&
	fail "VMLAUNCH still copies VMCS12 into the active VMCS"
grep -q 'vmx_nested_vmexit_to_l1' "${VMLAUNCH}" ||
	fail "VMLAUNCH does not report the entry through the VMCS12 host state"

grep -Eq 'ns->state[[:space:]]*=' "${VMCALL}" && fail "VMCALL changes the launch state"

echo "PASS: ${PROGRAM%.sh} VMCS12 state machine invariants"
exit 0
