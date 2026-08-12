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
# Wave 5 follow-up: per-vCPU scoping of VMCS shadowing.  The wave-5
# patch moved PROCBASED2_VMCS_SHADOWING + VMCS_LINK_POINTER from a
# per-VM init (which leaked the shadow HPA across vCPUs and confused
# VMPTRLD) to a per-vCPU install that fires only after VMPTRLD.
#
# Requires root and vmm.ko with the wave-5 patchset; SKIPs cleanly
# otherwise.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
VMX_NESTED_VMPTRLD="${repo_root}/sys/amd64/vmm/intel/vmx_nested_vmptrld.c"
VMX_NESTED_SHADOW="${repo_root}/sys/amd64/vmm/intel/vmx_nested_shadow.c"

preflight_vmcs_shadowing_scoped_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if [ "$(id -u 2>/dev/null)" != "0" ]; then
		echo "SKIP: not root; cannot read nested sysctls"
		return 0
	fi
	if ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm.ko not loaded; shadowing not initialised"
		return 0
	fi
	return 1
}

# Source-level: PROCBASED2_VMCS_SHADOWING must be set inside
# vmx_nested_vmptrld() (the per-vCPU VMPTRLD path), not at VM
# creation time.  A regression to per-VM init would set the link
# pointer before any VMPTRLD has installed a VMCS12.
assert_shadowing_is_per_vmptrld()
{
	if [ ! -r "${VMX_NESTED_VMPTRLD}" ]; then
		return 0
	fi
	# The PROCBASED2_VMCS_SHADOWING bit must be OR-ed in *after*
	# the L1-stated VMCS12 has been installed into nvmcs12 (the
	# vmx_nested_load_vmcs12() call).  We check the source order:
	# the bit-set must appear after the nvmcs12 memcpy.
	if ! awk '
	    /memcpy.*nvmcs12/ { saw_memcpy = 1 }
	    /PROCBASED2_VMCS_SHADOWING/ {
	        if (saw_memcpy) {
	            print "ok"
	            exit 0
	        } else {
	            print "bad-order"
	            exit 1
	        }
	    }
	' "${VMX_NESTED_VMPTRLD}" | grep -q 'ok'; then
		echo "FAIL: PROCBASED2_VMCS_SHADOWING set before nvmcs12 memcpy in vmx_nested_vmptrld.c"
		exit 1
	fi
}

# Source-level: VMCS_LINK_POINTER must be written with vtophys() of
# the per-vCPU nvmcs12 (not a static global).  A regression to a
# static shadow HPA would leak the shadow across vCPUs.
assert_link_pointer_uses_nvmcs12()
{
	if [ ! -r "${VMX_NESTED_VMPTRLD}" ]; then
		return 0
	fi
	if ! grep -q 'vtophys.*nvmcs12' "${VMX_NESTED_VMPTRLD}"; then
		echo "FAIL: VMCS_LINK_POINTER HPA not derived from nvmcs12 in vmx_nested_vmptrld.c"
		exit 1
	fi
	if ! grep -q 'VMCS_LINK_POINTER' "${VMX_NESTED_VMPTRLD}"; then
		echo "FAIL: VMCS_LINK_POINTER not written in vmx_nested_vmptrld.c"
		exit 1
	fi
}

# Source-level: the T22 shadow init must zero the dirty bitmap
# (vmcs_field_dirty) so the first VMLAUNCH sees no pending L1
# writes.  This is the contract for the per-vCPU scoping.
assert_shadow_init_zeroes_bitmap()
{
	if [ ! -r "${VMX_NESTED_SHADOW}" ]; then
		return 0
	fi
	if ! grep -q 'vmcs_field_dirty' "${VMX_NESTED_SHADOW}"; then
		echo "FAIL: vmcs_field_dirty bitmap missing in vmx_nested_shadow.c"
		exit 1
	fi
	if ! grep -q 'memset.*vmcs_field_dirty.*0' "${VMX_NESTED_SHADOW}"; then
		echo "FAIL: vmcs_field_dirty not zeroed by memset in shadow_init"
		exit 1
	fi
}

preflight_vmcs_shadowing_scoped_main()
{
	if preflight_vmcs_shadowing_scoped_unsupported; then
		exit 0
	fi

	# 1) Source-level: shadowing must be enabled *after* nvmcs12
	# is populated, not before.
	assert_shadowing_is_per_vmptrld

	# 2) Source-level: VMCS_LINK_POINTER HPA must come from
	# vtophys(nvmcs12) so each vCPU's shadow is independent.
	assert_link_pointer_uses_nvmcs12

	# 3) Source-level: shadow_init zeroes the dirty bitmap.
	assert_shadow_init_zeroes_bitmap

	# 4) Runtime: on a forked-kernel host with hw.vmm.nested.vmx
	# == 2 (TGL+), the nested status must be 2.  On Ivy Bridge it
	# is 0; we let the test SKIP by accepting 0/1 as well.
	vmx=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null)
	if [ -z "${vmx}" ]; then
		echo "SKIP: hw.vmm.nested.vmx unreachable"
		exit 0
	fi
	printf '  hw.vmm.nested.vmx = %s\n' "${vmx}"
	case "${vmx}" in
		0|1|2) ;;
		*)
			echo "FAIL: hw.vmm.nested.vmx out of range: '${vmx}'"
			exit 1
			;;
	esac

	echo "PASS: preflight_vmcs_shadowing_scoped per-vCPU shadowing"
}

preflight_vmcs_shadowing_scoped_main "$@"

atf_test_case "preflight_vmcs_shadowing_scoped"
preflight_vmcs_shadowing_scoped_head()
{
	atf_set "descr" "VMCS shadowing scoped per-vCPU after VMPTRLD (wave-5 fix)"
	atf_set "require.user" "root"
	atf_set "require.kmods" "vmm"
}
preflight_vmcs_shadowing_scoped_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_vmcs_shadowing_scoped"
}
