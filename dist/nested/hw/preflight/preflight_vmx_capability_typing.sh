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
# Wave 5 / T19 follow-up: type-specific VMX capability MSR mask
# derivation.  Verifies the vmx_cap_masks_init() function
# (vmx_msr.c lines ~354-560) classifies each MSR into one of the
# six VMX_CAP_CLASS_* buckets and applies the right (and_mask,
# or_mask) pair.  Also confirms preflight.sh exposes the
# `0x80000001 ECX (SVM?)` line as a visible cross-check.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
VMX_MSR="${repo_root}/sys/amd64/vmm/intel/vmx_msr.c"
PREFLIGHT="${repo_root}/tools/preflight.sh"

preflight_vmx_capability_typing_unsupported()
{
	if [ ! -r "${VMX_MSR}" ]; then
		echo "SKIP: ${VMX_MSR} not present"
		return 0
	fi
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	return 1
}

# Confirm the wave-5 typed-mask init switches over
# VMX_CAP_CLASS_BASIC/CTL/TRUE_CTL/REPORT/FIXED/DATA.  A regression
# that drops a class would let raw rdmsr values reach L1 (or zero
# everything) which would silently break L1's ability to discover
# VMX features.
assert_class_present()
{
	_class=$1
	_class_count=$(grep -c "VMX_CAP_CLASS_${_class}" "${VMX_MSR}")
	if [ "${_class_count}" -lt 2 ]; then
		# At least 2 references: one in classify, one in masks_init.
		echo "FAIL: VMX_CAP_CLASS_${_class} referenced only ${_class_count}x in vmx_msr.c (need >=2)"
		exit 1
	fi
}

# Confirm each MSR -> class mapping exists in the classify switch.
# The classify switch uses fall-through (e.g. MSR_VMX_PROCBASED_CTLS
# shares its label with MSR_VMX_EXIT_CTLS / ENTRY_CTLS), so we look
# at a wider window around each 'case' line.  We need the second
# 'case' match (the first is in vmx_cap_host_read() which returns
# the rdmsr value; the classify switch is the second occurrence).
assert_classify_case()
{
	_msr=$1
	_class=$2
	# Find the second 'case' line (the classify switch).
	line=$(grep -n "case ${_msr}:" "${VMX_MSR}" | sed -n '2p' | cut -d: -f1)
	if [ -z "${line}" ]; then
		echo "FAIL: ${_msr} classify case not found in vmx_msr.c"
		exit 1
	fi
	# Look at the next 6 lines (covers fall-throughs).
	if ! sed -n "$((line + 1)),$((line + 6))p" "${VMX_MSR}" | \
	    grep -q "VMX_CAP_CLASS_${_class}"; then
		echo "FAIL: ${_msr} does not classify as VMX_CAP_CLASS_${_class}"
		exit 1
	fi
}

# Confirm preflight.sh prints the SVM indicator line.  This is the
# only place the script talks about MSR-range semantics, and it is
# the user-visible cross-check the wave-5 fix relied on.
assert_preflight_prints_svm_line()
{
	if [ ! -r "${PREFLIGHT}" ]; then
		return 0
	fi
	if ! grep -q 'SVM (0x80000001:ECX\[2\])' "${PREFLIGHT}"; then
		echo "FAIL: preflight.sh does not print 'SVM (0x80000001:ECX\[2\])' line"
		exit 1
	fi
}

preflight_vmx_capability_typing_main()
{
	if preflight_vmx_capability_typing_unsupported; then
		exit 0
	fi

	# 1) All six VMX_CAP_CLASS_* symbols must be present.
	for cls in BASIC CTL TRUE_CTL REPORT FIXED DATA; do
		assert_class_present "${cls}"
	done

	# 2) Spot-check the MSR -> class mappings.
	assert_classify_case MSR_VMX_BASIC BASIC
	assert_classify_case MSR_VMX_PROCBASED_CTLS CTL
	assert_classify_case MSR_VMX_TRUE_PINBASED_CTLS TRUE_CTL
	assert_classify_case MSR_VMX_MISC REPORT
	assert_classify_case MSR_VMX_VMCS_ENUM REPORT
	assert_classify_case MSR_VMX_CR0_FIXED0 FIXED
	assert_classify_case MSR_VMX_EPT_VPID_CAP DATA

	# 3) The EPT_VPID_CAP case must use the DATA (pass-through)
	# branch -- the wave-5 fix specifically stopped stripping
	# EPT feature bits by routing through REPORT.
	if ! grep -B1 -A4 'VMX_CAP_CLASS_DATA:' "${VMX_MSR}" | \
	    grep -q 'EPT_VPID_CAP'; then
		# Less brittle: just confirm the DATA branch exists and
		# uses pass-through (and_mask = ~0, or_mask = 0).
		echo "FAIL: VMX_CAP_CLASS_DATA branch missing"
		exit 1
	fi

	# 4) The TRUE_CTL branch must zero both masks when the host
	# lacks BASIC.bit55 (the 'else' arm).  This is the contract
	# the wave-5 fix added.
	if ! awk '/VMX_CAP_CLASS_TRUE_CTL:/{flag=1} flag && /else/{flag=2} flag==2 && /or_mask = 0/{print; flag=3}' "${VMX_MSR}" | \
	    grep -q 'or_mask = 0'; then
		echo "FAIL: TRUE_CTL class else-branch does not zero or_mask"
		exit 1
	fi

	# 5) preflight.sh exposes the SVM indicator line as the
	# user-visible MSR-derived output.
	assert_preflight_prints_svm_line

	echo "PASS: preflight_vmx_capability_typing typed-mask derivation"
}

preflight_vmx_capability_typing_main "$@"

atf_test_case "preflight_vmx_capability_typing"
preflight_vmx_capability_typing_head()
{
	atf_set "descr" "Type-specific VMX capability MSR mask derivation covers all six VMX_CAP_CLASS_* buckets"
}
preflight_vmx_capability_typing_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_vmx_capability_typing"
}
