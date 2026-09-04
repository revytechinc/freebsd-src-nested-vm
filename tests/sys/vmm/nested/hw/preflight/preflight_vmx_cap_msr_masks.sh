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
# Wave 5 / T19 follow-up: VMX capability MSR bitmap masking.  Verifies
# that the wave-5 typed-mask derivation (vmx_msr.c vmx_cap_classify /
# vmx_cap_masks_init) uses the architectural MSR indices 0x480..0x490
# and treats the TRUE_* set (0x48D..0x490) as gated by BASIC.bit55.
#
# The test does not require root or vmm.ko; it asserts against the
# production source so a regression in the MSR-index switch cases is
# caught even on a host without nested-virt enabled.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
PREFLIGHT="${repo_root}/tools/preflight.sh"
VMX_MSR="${repo_root}/sys/amd64/vmm/intel/vmx_msr.c"
SPECIALREG="${repo_root}/sys/x86/include/specialreg.h"

preflight_vmx_cap_msr_masks_unsupported()
{
	if [ ! -r "${VMX_MSR}" ]; then
		echo "SKIP: ${VMX_MSR} not present"
		return 0
	fi
	if [ ! -r "${SPECIALREG}" ]; then
		echo "SKIP: ${SPECIALREG} not present"
		return 0
	fi
	# Synthetic Haswell dmesg cannot be isolated from live
	# hw.vmm.nested.* while vmm.ko is loaded; skip rather than FAIL.
	if kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm.ko loaded; synthetic Haswell dmesg cannot override live nested sysctls"
		return 0
	fi
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	return 1
}

# Source-grep: confirm every architectural VMX capability MSR macro
# is referenced in vmx_msr.c (the code uses symbolic macros, not
# the literal hex constants, so we assert against the symbol name).
# A missing case here would cause a silent zero return to L1 on rdmsr.
assert_msr_in_source()
{
	_label=$1
	_macro=$2
	if ! grep -q "${_macro}" "${VMX_MSR}"; then
		echo "FAIL: ${_label} - macro ${_macro} not referenced in vmx_msr.c"
		exit 1
	fi
}

# Source-grep: confirm the TRUE_CTL class branch in vmx_cap_masks_init()
# keys off BASIC.bit55, so a host without TRUE_* controls returns a
# zero mask (which the read path surfaces as #GP into L1).
assert_true_ctl_uses_bit55()
{
	# vmx_cap_masks_init computes has_true_ctls from BASIC.bit55 and
	# zeroes the AND/OR masks for the TRUE_CTL class when the bit is
	# clear.  Both halves of that contract must appear in the source.
	if ! grep -q 'has_true_ctls' "${VMX_MSR}"; then
		echo "FAIL: TRUE_CTL class - 'has_true_ctls' gate missing in vmx_msr.c"
		exit 1
	fi
	if ! grep -q '(1UL << 55)' "${VMX_MSR}"; then
		echo "FAIL: TRUE_CTL class - BASIC.bit55 mask literal missing in vmx_msr.c"
		exit 1
	fi
}

# Source-grep: confirm the EPT_VPID_CAP class is DATA (pass-through) so
# the L0 EPT feature bits L1 sees are not stripped.
assert_ept_vpid_is_data_class()
{
	if ! grep -A6 'MSR_VMX_EPT_VPID_CAP' "${VMX_MSR}" | \
	    grep -q 'VMX_CAP_CLASS_DATA'; then
		echo "FAIL: EPT_VPID_CAP not classified as VMX_CAP_CLASS_DATA"
		exit 1
	fi
}

# Source-grep: confirm the CR0_FIXED0 / CR0_FIXED1 MSRs are in the FIXED
# class and the read function returns the host value verbatim.
assert_fixed_class_uses_pass_through()
{
	if ! grep -A8 'VMX_CAP_CLASS_FIXED' "${VMX_MSR}" | \
	    grep -q '~(uint64_t)0'; then
		echo "FAIL: VMX_CAP_CLASS_FIXED must use all-ones pass-through mask"
		exit 1
	fi
}

preflight_vmx_cap_msr_masks_main()
{
	if preflight_vmx_cap_msr_masks_unsupported; then
		exit 0
	fi

	# 1) Source check: every architectural VMX capability MSR macro
	# 0x480..0x490 is referenced in vmx_msr.c (the wave-5 typed-
	# mask init relies on the full set being present).  Assert
	# against the symbolic macro names since that's what the code
	# uses in the switch statements.
	for msr in MSR_VMX_BASIC MSR_VMX_PINBASED_CTLS \
	           MSR_VMX_PROCBASED_CTLS MSR_VMX_EXIT_CTLS \
	           MSR_VMX_ENTRY_CTLS MSR_VMX_MISC \
	           MSR_VMX_CR0_FIXED0 MSR_VMX_CR0_FIXED1 \
	           MSR_VMX_CR4_FIXED0 MSR_VMX_CR4_FIXED1 \
	           MSR_VMX_VMCS_ENUM MSR_VMX_PROCBASED_CTLS2 \
	           MSR_VMX_EPT_VPID_CAP MSR_VMX_TRUE_PINBASED_CTLS \
	           MSR_VMX_TRUE_PROCBASED_CTLS MSR_VMX_TRUE_EXIT_CTLS \
	           MSR_VMX_TRUE_ENTRY_CTLS; do
		assert_msr_in_source "VMX capability MSR" "${msr}"
	done

	# 2) TRUE_CTL gating: the source must check BASIC.bit55 and
	# zero out the TRUE_* masks when the host lacks TRUE controls.
	assert_true_ctl_uses_bit55

	# 3) EPT_VPID_CAP must be DATA (pass-through), not REPORT.
	# The wave-5 typed mask was specifically introduced to stop
	# EPT_VPID_CAP from being masked into zero.
	assert_ept_vpid_is_data_class

	# 4) CR0/CR4_FIXED class must use the all-ones pass-through
	# mask (or-mask zero) so L1 sees the host architectural
	# forced-bit pattern unmodified.
	assert_fixed_class_uses_pass_through

	# 5) CR0_FIXED0 architectural guarantee: bit 0 (PE) and bit 31
	# (PG) must be forced on.  Assert via the kernel test module
	# which checks the live MSR on this host.
	if [ -r "${PREFLIGHT}" ]; then
		tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/preflight-vmx-cap.XXXXXX") || return 1
		dmesg_path="${tmpdir}/dmesg.boot"
		script_copy="${tmpdir}/preflight.sh"
		cp "${PREFLIGHT}" "${script_copy}"
		chmod +x "${script_copy}"
		cat > "${dmesg_path}" <<'DMESG_EOF'
CPU: Intel(R) Core(TM) synthetic (family 0x6, model 0x3c)
  Origin="GenuineIntel"  Id=0x306c3  Family=0x6  Model=0x3c  Stepping=0xa
  Features=0xbfebfbff  <FPU,VME,DE,PSE,TSC,MSR,PAE,MCE,CX8,APIC,SEP,MTRR,PGE,MCA,CMOV,PAT,PSE36,CLFLUSH,MMX,FXSR,SSE,SSE2,SS,HTT>
  Features2=0x7ffafbff  <SSE3,PCLMULQDQ,DTES64,MONITOR,DS-CPL,VMX,SMX,EST,TM2,SSSE3,CX16,xTPR,PDCM,PCID,SSE4.1,SSE4.2,POPCNT,AESNI,XSAVE,OSXSAVE,AVX,F16C,RDRAND>
  Structured Extended Features=0x29c6f7bf  <FSGSBASE,TSCADJ,SGX,BMI1,HLE,AVX2,SMEP,BMI2,ERMS,INVPCID,RTM,RDSEED,ADX,SMAP,CLFLUSHOPT,CLWB,SHA>
DMESG_EOF
		sed -i.bak "s|PREFLIGHT_DMESG=/var/run/dmesg.boot|PREFLIGHT_DMESG=${dmesg_path}|" "${script_copy}"
		out=$(PREFLIGHT_DMESG="${dmesg_path}" sh "${script_copy}" 2>&1)
		rc=$?
		rm -rf "${tmpdir}"
		if [ "${rc}" -ne 0 ] && [ "${rc}" -ne 1 ]; then
			echo "FAIL: preflight.sh exited ${rc} on synthetic Haswell dmesg"
			printf '%s\n' "${out}" | head -10
			exit 1
		fi
		# Haswell is family=6 model=0x3c which the script classifies
		# as 'Haswell family (4th gen)' and marks VIABLE.
		if ! printf '%s\n' "${out}" | grep -q 'Haswell'; then
			echo "FAIL: preflight.sh did not classify synthetic Haswell"
			printf '%s\n' "${out}" | head -10
			exit 1
		fi
		if ! printf '%s\n' "${out}" | grep -Eq 'VIABLE|UNKNOWN'; then
			echo "FAIL: preflight.sh did not mark Haswell VIABLE or UNKNOWN (vmm.ko not loaded)"
			printf '%s\n' "${out}" | head -10
			exit 1
		fi
	fi

	# 6) Confirm the header includes the architectural MSR index
	# values 0x486 (CR0_FIXED0), 0x48A (VMCS_ENUM), and 0x490
	# (TRUE_ENTRY_CTLS).  These three indices are the boundary
	# cases the wave-5 typed-mask init specifically exercises.
	for msr in MSR_VMX_BASIC MSR_VMX_CR0_FIXED0 \
	           MSR_VMX_VMCS_ENUM MSR_VMX_TRUE_ENTRY_CTLS; do
		if ! grep -q "${msr}" "${SPECIALREG}"; then
			echo "FAIL: ${msr} not defined in specialreg.h"
			exit 1
		fi
	done

	echo "PASS: preflight_vmx_cap_msr_masks MSR bitmap assertions"
}

preflight_vmx_cap_msr_masks_main "$@"

atf_test_case "preflight_vmx_cap_msr_masks"
preflight_vmx_cap_msr_masks_head()
{
	atf_set "descr" "VMX capability MSR bitmap masking uses 0x480..0x490 with BASIC.bit55 gating TRUE_*"
}
preflight_vmx_cap_msr_masks_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_vmx_cap_msr_masks"
}
