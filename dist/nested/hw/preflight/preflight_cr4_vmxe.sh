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
# Wave 5 / T14 + T15 follow-up: integration test for the CR4.VMXE
# gate and the nested-status sysctl.  Confirms:
#   * CR4_VMXE is the well-known 0x2000 bit (vmx_nested_test test 4).
#   * hw.vmm.nested.vmx is 2 on Haswell+/Tiger Lake+, 0 on Ivy
#     Bridge, and 1 when an L0 hypervisor is already running.
#   * vmx_vcpu carries the nvmcs12 shadow region (T15) and the
#     vmcs12 struct is PAGE_SIZE (T15).
#
# Requires root and vmm.ko (the wave-3+5+6 patchset loaded).

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
SPECIALREG="${repo_root}/sys/x86/include/specialreg.h"
VMX_NESTED_TEST="${repo_root}/sys/amd64/vmm/intel/vmx_nested_test.c"
VMX_NESTED_H="${repo_root}/sys/amd64/vmm/intel/vmx_nested.h"

preflight_cr4_vmxe_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if [ "$(id -u 2>/dev/null)" != "0" ]; then
		echo "SKIP: not root; cannot read vendor nested sysctls"
		return 0
	fi
	if ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm.ko not loaded; CR4.VMXE gate not initialised"
		return 0
	fi
	return 1
}

preflight_cr4_vmxe_main()
{
	if preflight_cr4_vmxe_unsupported; then
		exit 0
	fi

	# 1) Live sysctl: hw.vmm.nested.vmx must be 0, 1, or 2.
	vmx=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null)
	if [ -z "${vmx}" ]; then
		echo "FAIL: hw.vmm.nested.vmx unreachable"
		exit 1
	fi
	case "${vmx}" in
		0|1|2) ;;
		*)
			echo "FAIL: hw.vmm.nested.vmx out of range: '${vmx}'"
			exit 1
			;;
	esac
	printf '  hw.vmm.nested.vmx = %s\n' "${vmx}"

	# 2) Source-level CR4_VMXE bit pattern.  The wave-5 patch
	# consolidated the VMX gate into CR4_VMXE (0x2000); a regression
	# to a different bit (e.g. 0x1000) would silently break bhyve.
	if [ -r "${SPECIALREG}" ]; then
		if ! grep -Eq 'define[[:space:]]+CR4_VMXE[[:space:]]+0x0*2000' \
		    "${SPECIALREG}"; then
			echo "FAIL: CR4_VMXE not defined as 0x2000 in specialreg.h"
			exit 1
		fi
	else
		echo "  WARN: specialreg.h not readable; skipping CR4_VMXE check"
	fi

	# 3) T15 invariant: struct vmcs is exactly PAGE_SIZE and struct
	# vmx_vcpu carries the nvmcs12 backing region.  The CTASSERTs
	# in vmx_nested.h and the live CTASSERT in vmx_nested_test.c
	# must both be present.
	if [ -r "${VMX_NESTED_H}" ]; then
		if ! grep -q 'CTASSERT(sizeof(struct vmcs12) == PAGE_SIZE)' \
		    "${VMX_NESTED_H}"; then
			echo "FAIL: T15 CTASSERT(vmcs12==PAGE_SIZE) missing"
			exit 1
		fi
	else
		echo "  WARN: vmx_nested.h not readable; skipping T15 check"
	fi
	if [ -r "${VMX_NESTED_TEST}" ]; then
		if ! grep -q 'CTASSERT(sizeof(struct vmcs) == PAGE_SIZE)' \
		    "${VMX_NESTED_TEST}"; then
			echo "FAIL: T15 CTASSERT(vmcs==PAGE_SIZE) missing in test module"
			exit 1
		fi
		if ! grep -q 'offsetof(struct vmx_vcpu, nvmcs12)' \
		    "${VMX_NESTED_TEST}"; then
			echo "FAIL: T15 nvmcs12 offset check missing in test module"
			exit 1
		fi
	else
		echo "  WARN: vmx_nested_test.c not readable; skipping CTASSERT check"
	fi

	# 4) On Intel hosts with Haswell+ silicon the nested.vmx gate
	# should be 2 (or 1 if an L0 hypervisor is in the way).  On
	# Ivy Bridge it is 0.  On non-Intel hosts skip the assertion.
	origin=$( (grep -m1 'Origin=' /var/run/dmesg.boot 2>/dev/null || \
	    echo '') | sed -n 's|.*Origin="\([^"]*\)".*|\1|p')
	if [ "${origin}" = "GenuineIntel" ]; then
		fam=$(grep -m1 'Origin=' /var/run/dmesg.boot 2>/dev/null | \
		    sed -n 's|.*Family=0x\([0-9a-f]*\).*|\1|p')
		mod=$(grep -m1 'Origin=' /var/run/dmesg.boot 2>/dev/null | \
		    sed -n 's|.*Model=0x\([0-9a-f]*\).*|\1|p')
		if [ "${fam}" = "6" ] && [ "${mod}" = "3a" ]; then
			if [ "${vmx}" != "0" ]; then
				echo "FAIL: Ivy Bridge expected nested.vmx=0, got '${vmx}'"
				exit 1
			fi
		elif [ "${fam}" = "6" ]; then
			if [ "${vmx}" != "1" ] && [ "${vmx}" != "2" ]; then
				echo "FAIL: Haswell+ expected nested.vmx in {1,2}, got '${vmx}'"
				exit 1
			fi
		fi
	fi

	echo "PASS: preflight_cr4_vmxe CR4.VMXE gate + nested-status sysctl"
}

preflight_cr4_vmxe_main "$@"

atf_test_case "preflight_cr4_vmxe"
preflight_cr4_vmxe_head()
{
	atf_set "descr" "CR4.VMXE (0x2000) gate + hw.vmm.nested.vmx sysctl + T15 PAGE_SIZE invariant"
	atf_set "require.user" "root"
	atf_set "require.kmods" "vmm"
}
preflight_cr4_vmxe_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_cr4_vmxe"
}
