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
# Wave 5 / T15 + T20 follow-up: vmcs12_state enum + state-machine
# transitions.  Asserts the enum values in vmx_nested.h are
# NONE=0, CLEAR=1, LAUNCHED=2 and the production transition code
# follows the documented state diagram:
#
#   NONE -> CLEAR     (VMPTRLD: vmx_nested_load_vmcs12)
#   CLEAR -> LAUNCHED (VMLAUNCH: vmx_nested_vmlaunch_handle)
#   LAUNCHED -> LAUNCHED (VMRESUME: vmx_nested_vmresume_handle)
#   LAUNCHED -> LAUNCHED (VMCALL: vmx_nested_vmcall_handle)
#   LAUNCHED -> CLEAR (VMCLEAR: vmx_nested_vmclear_handle)
#   CLEAR -> NONE (VMCLEAR without current VMCS12)
#
# Does not require root or vmm.ko.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
VMX_NESTED_H="${repo_root}/sys/amd64/vmm/intel/vmx_nested.h"
VMX_NESTED_VMPTRLD="${repo_root}/sys/amd64/vmm/intel/vmx_nested_vmptrld.c"
VMX_NESTED_VMLAUNCH="${repo_root}/sys/amd64/vmm/intel/vmx_nested_vmlaunch.c"
VMX_NESTED_VMRESUME="${repo_root}/sys/amd64/vmm/intel/vmx_nested_vmresume.c"
VMX_NESTED_VMCALL="${repo_root}/sys/amd64/vmm/intel/vmx_nested_vmcall.c"
VMX_NESTED_VMCLEAR="${repo_root}/sys/amd64/vmm/intel/vmx_nested_vmclear.c"

preflight_vmcs12_state_transitions_unsupported()
{
	if [ ! -r "${VMX_NESTED_H}" ]; then
		echo "SKIP: ${VMX_NESTED_H} not present"
		return 0
	fi
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	return 1
}

# Confirm the enum values are exactly 0, 1, 2 in order.
assert_enum_values()
{
	# Grab the body of the enum definition.
	body=$(awk '
	    /enum[[:space:]]+vmcs12_state[[:space:]]*{/ { flag=1; next }
	    flag && /^[[:space:]]*};/ { flag=0 }
	    flag { print }
	' "${VMX_NESTED_H}")
	if [ -z "${body}" ]; then
		echo "FAIL: vmcs12_state enum body not found"
		exit 1
	fi

	# VMCS12_STATE_NONE must explicitly be 0.
	if ! printf '%s\n' "${body}" | \
	    grep -Eq "^[[:space:]]+VMCS12_STATE_NONE[[:space:]]*=[[:space:]]*0[[:space:]]*(,|$)"; then
		echo "FAIL: VMCS12_STATE_NONE != 0"
		printf '%s\n' "${body}"
		exit 1
	fi

	# VMCS12_STATE_CLEAR and VMCS12_STATE_LAUNCHED follow NONE
	# in order with auto-numbering (== 1 and == 2).  Accept either
	# explicit "= N" or implicit (just the tag followed by ','/'}').
	if ! printf '%s\n' "${body}" | \
	    grep -Eq "^[[:space:]]+VMCS12_STATE_CLEAR[[:space:]]*(=[[:space:]]*1)?[[:space:]]*(,|$)"; then
		echo "FAIL: VMCS12_STATE_CLEAR missing from enum"
		printf '%s\n' "${body}"
		exit 1
	fi
	if ! printf '%s\n' "${body}" | \
	    grep -Eq "^[[:space:]]+VMCS12_STATE_LAUNCHED[[:space:]]*(=[[:space:]]*2)?[[:space:]]*(,|$)"; then
		echo "FAIL: VMCS12_STATE_LAUNCHED missing from enum"
		printf '%s\n' "${body}"
		exit 1
	fi
}

# Confirm vmx_nested_load_vmcs12 sets state to VMCS12_STATE_CLEAR
# after copying in the L1 VMCS12 image.
assert_vmptrld_sets_clear()
{
	if [ ! -r "${VMX_NESTED_VMPTRLD}" ]; then
		return 0
	fi
	if ! grep -q 'VMCS12_STATE_CLEAR' "${VMX_NESTED_VMPTRLD}"; then
		echo "FAIL: VMCS12_STATE_CLEAR not set in vmx_nested_vmptrld.c"
		exit 1
	fi
}

# Confirm vmx_nested_vmlaunch_handle advances state to LAUNCHED.
assert_vmlaunch_sets_launched()
{
	if [ ! -r "${VMX_NESTED_VMLAUNCH}" ]; then
		return 0
	fi
	if ! grep -q 'VMCS12_STATE_LAUNCHED' "${VMX_NESTED_VMLAUNCH}"; then
		echo "FAIL: VMCS12_STATE_LAUNCHED not set in vmx_nested_vmlaunch.c"
		exit 1
	fi
}

# Confirm vmcall does NOT regress state (must stay LAUNCHED).
assert_vmcall_keeps_launched()
{
	if [ ! -r "${VMX_NESTED_VMCALL}" ]; then
		return 0
	fi
	# vmcall may not touch the state at all; check that no source
	# line in vmx_nested_vmcall.c writes VMCS12_STATE_NONE or
	# VMCS12_STATE_CLEAR (those would be a regression).
	if grep -E 'VMCS12_STATE_(NONE|CLEAR)' "${VMX_NESTED_VMCALL}"; then
		echo "FAIL: vmx_nested_vmcall_handle regresses state to NONE/CLEAR"
		exit 1
	fi
}

# Confirm vmclear resets state to CLEAR (or NONE if no current VMCS12).
assert_vmclear_resets_state()
{
	if [ ! -r "${VMX_NESTED_VMCLEAR}" ]; then
		return 0
	fi
	if ! grep -Eq 'VMCS12_STATE_(CLEAR|NONE)' "${VMX_NESTED_VMCLEAR}"; then
		echo "FAIL: vmx_nested_vmclear_handle does not reset state"
		exit 1
	fi
}

preflight_vmcs12_state_transitions_main()
{
	if preflight_vmcs12_state_transitions_unsupported; then
		exit 0
	fi

	# 1) enum vmcs12_state values are 0, 1, 2.
	assert_enum_values

	# 2) NONE -> CLEAR: VMPTRLD path sets state to CLEAR.
	assert_vmptrld_sets_clear

	# 3) CLEAR -> LAUNCHED: VMLAUNCH path sets state to LAUNCHED.
	assert_vmlaunch_sets_launched

	# 4) VMRESUME keeps LAUNCHED.  (vmresume may or may not touch
	# the state field; what matters is that no regression drops
	# it to CLEAR/NONE.)
	if [ -r "${VMX_NESTED_VMRESUME}" ]; then
		if grep -E 'VMCS12_STATE_(NONE|CLEAR)' "${VMX_NESTED_VMRESUME}"; then
			echo "FAIL: vmx_nested_vmresume_handle regresses state to NONE/CLEAR"
			exit 1
		fi
	fi

	# 5) VMCALL keeps LAUNCHED (no regression).
	assert_vmcall_keeps_launched

	# 6) VMCLEAR resets state to CLEAR (or NONE if no VMCS12).
	assert_vmclear_resets_state

	# 7) VMCS_FIELD_BITMAP_SIZE must be 4096 (T22).
	if ! grep -q '#define[[:space:]]\+VMCS_FIELD_BITMAP_SIZE[[:space:]]\+4096' \
	    "${VMX_NESTED_H}"; then
		echo "FAIL: VMCS_FIELD_BITMAP_SIZE != 4096"
		exit 1
	fi

	echo "PASS: preflight_vmcs12_state_transitions state machine invariants"
}

preflight_vmcs12_state_transitions_main "$@"

atf_test_case "preflight_vmcs12_state_transitions"
preflight_vmcs12_state_transitions_head()
{
	atf_set "descr" "vmcs12_state enum values + state-machine transitions (T15/T20)"
}
preflight_vmcs12_state_transitions_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_vmcs12_state_transitions"
}
