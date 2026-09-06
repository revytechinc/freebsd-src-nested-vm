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
#   * hw.vmm.nested.vmx is a boolean: 1 on any Intel part with the VMX
#     features the nested paths need, 0 otherwise.
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

	# 1) Live sysctl: hw.vmm.nested.vmx must be a boolean.
	vmx=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null)
	if [ -z "${vmx}" ]; then
		echo "FAIL: hw.vmm.nested.vmx unreachable"
		exit 1
	fi
	case "${vmx}" in
		0|1) ;;
		*)
			echo "FAIL: hw.vmm.nested.vmx not a boolean: '${vmx}'"
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

	# 4) The nested probe gates on unrestricted guest, so derive the
	# expectation from the capability itself rather than from the CPU
	# family: family 6 spans parts that legitimately lack it (Atom-class
	# cores and pre-Ivy Bridge parts), and those correctly report 0.
	# Hardware VMCS shadowing is not part of the gate, because it is never
	# programmed into a VMCS.
	ug=$(sysctl -n hw.vmm.vmx.cap.unrestricted_guest 2>/dev/null)
	if [ -n "${ug}" ]; then
		if [ "${ug}" = "1" ] && [ "${vmx}" != "1" ]; then
			echo "FAIL: unrestricted guest present but nested.vmx='${vmx}', expected 1"
			exit 1
		fi
		if [ "${ug}" = "0" ] && [ "${vmx}" != "0" ]; then
			echo "FAIL: no unrestricted guest but nested.vmx='${vmx}', expected 0"
			exit 1
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
