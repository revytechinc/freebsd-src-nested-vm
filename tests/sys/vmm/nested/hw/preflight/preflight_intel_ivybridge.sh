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
# T0a / Wave 0a: preflight integration -- Intel Ivy Bridge detection.
# Verifies the wave-0a patch correctly maps Ivy Bridge (family=6 model=0x3a)
# to hw.vmm.nested.vmx == 0, since Ivy Bridge lacks VMCS-shadowing.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

preflight_intel_ivybridge_unsupported()
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

preflight_intel_ivybridge_main()
{
	if preflight_intel_ivybridge_unsupported; then
		exit 0
	fi

	# Detect Ivy Bridge: Intel family=6 model=0x3a.
	origin=$(sysctl -n hw.model 2>/dev/null)
	cpu_vendor=$( (grep -m1 'Origin=' /var/run/dmesg.boot 2>/dev/null || echo '') | \
	    sed -n 's|.*Origin="\([^"]*\)".*|\1|p')
	if [ "${cpu_vendor}" != "GenuineIntel" ]; then
		echo "SKIP: host is not GenuineIntel ('${cpu_vendor}')"
		exit 0
	fi

	# hw.model encodes Family/Model for Intel.  FreeBSD prints Family=0x6
	# Model=0x3a for Ivy Bridge.  Parse it conservatively from dmesg.boot
	# since hw.model is the marketing string.
	fam=$(grep -m1 'Origin=' /var/run/dmesg.boot 2>/dev/null | \
	    sed -n 's|.*Family=0x\([0-9a-f]*\).*|\1|p')
	mod=$(grep -m1 'Origin=' /var/run/dmesg.boot 2>/dev/null | \
	    sed -n 's|.*Model=0x\([0-9a-f]*\).*|\1|p')
	if [ "${fam}" != "6" ] || [ "${mod}" != "3a" ]; then
		echo "SKIP: not Ivy Bridge (family=${fam} model=${mod}, model-string='${origin}')"
		exit 0
	fi

	v=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null)
	if [ -z "${v}" ]; then
		echo "FAIL: hw.vmm.nested.vmx unreachable on Ivy Bridge host"
		exit 1
	fi
	if [ "${v}" != "0" ]; then
		echo "FAIL: Ivy Bridge expected hw.vmm.nested.vmx=0, got '${v}'"
		exit 1
	fi

	echo "PASS: preflight_intel_ivybridge mapped Ivy Bridge to vmx=0"
}

preflight_intel_ivybridge_main "$@"

atf_test_case "preflight_intel_ivybridge"
preflight_intel_ivybridge_head()
{
	atf_set "descr" "Ivy Bridge detection -> hw.vmm.nested.vmx == 0"
	atf_set "require.user" "root"
	atf_set "require.kmods" "vmm"
}
preflight_intel_ivybridge_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_intel_ivybridge"
}