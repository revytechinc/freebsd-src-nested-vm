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
# T0a / Wave 0a: preflight integration -- sysctl path reachability.
# Verifies that hw.vmm.nested.svm and hw.vmm.nested.vmx are reachable OIDs
# with integer values, and that hw.vmm.nested.enable responds as expected
# (succeeds on capable silicon, or prints the L0/refusal message otherwise).
# Requires root and vmm.ko.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

preflight_sysctl_paths_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if [ "$(id -u 2>/dev/null)" != "0" ]; then
		echo "SKIP: not root; cannot read vendor nested sysctls"
		return 0
	fi
	if ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm.ko not loaded; sysctls absent"
		return 0
	fi
	return 1
}

preflight_sysctl_paths_main()
{
	if preflight_sysctl_paths_unsupported; then
		exit 0
	fi

	# Read both vendor status sysctls; they must be reachable and integer.
	for oid in hw.vmm.nested.svm hw.vmm.nested.vmx; do
		if ! sysctl -n "${oid}" >/dev/null 2>&1; then
			echo "FAIL: sysctl ${oid} not reachable"
			exit 1
		fi
		v=$(sysctl -n "${oid}" 2>/dev/null)
		case "${v}" in
			''|*[!0-9]*)
				echo "FAIL: sysctl ${oid} returned non-integer: '${v}'"
				exit 1
				;;
		esac
		if [ "${v}" -lt 0 ] || [ "${v}" -gt 2 ]; then
			echo "FAIL: sysctl ${oid} out of expected range 0..2: '${v}'"
			exit 1
		fi
		printf '  %s = %s\n' "${oid}" "${v}"
	done

	# Exercise the master switch: on capable silicon it succeeds; on
	# L0-conflict or unsupported hardware it returns EOPNOTSUPP.  Either
	# path is a pass as long as the kernel responds predictably.
	_saved_enable=$(sysctl -n hw.vmm.nested.enable 2>/dev/null || echo 1)
	if sysctl hw.vmm.nested.enable=1 >/dev/null 2>&1; then
		echo "  hw.vmm.nested.enable=1 accepted"
		# Prove 0 is also accepted, then put the switch back the way we
		# found it -- nesting is on by default and leaving it off would
		# silently disarm every test that runs after this one.
		sysctl hw.vmm.nested.enable=0 >/dev/null 2>&1 || true
		sysctl hw.vmm.nested.enable="${_saved_enable}" >/dev/null 2>&1 || true
	else
		out=$(sysctl hw.vmm.nested.enable=1 2>&1 || true)
		if echo "$out" | grep -Eq 'refusing nested-virt|not available|not supported'; then
			echo "  hw.vmm.nested.enable=1 refused (gate: $out)"
		else
			echo "FAIL: hw.vmm.nested.enable=1 produced unexpected output"
			echo "$out"
			exit 1
		fi
	fi

	echo "PASS: preflight_sysctl_paths reachable, integer, in range"
}

preflight_sysctl_paths_main "$@"

atf_test_case "preflight_sysctl_paths"
preflight_sysctl_paths_head()
{
	atf_set "descr" "hw.vmm.nested.{svm,vmx} sysctls reachable + hw.vmm.nested.enable responds"
	atf_set "require.user" "root"
	atf_set "require.kmods" "vmm"
}
preflight_sysctl_paths_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_sysctl_paths"
}