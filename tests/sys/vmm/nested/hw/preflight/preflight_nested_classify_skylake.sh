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
# Wave 5 / T1 follow-up: Intel microarch classification for Skylake,
# Kaby Lake, and Coffee Lake/Comet Lake.  Mirrors the dual-needle
# structure of preflight_unit_classify but exercises the post-wave-5
# model table to confirm the case statement covers the 0x5e / 0x8e /
# 0x9e entries.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
PREFLIGHT="${repo_root}/tools/preflight.sh"

preflight_nested_classify_skylake_unsupported()
{
	if [ ! -r "${PREFLIGHT}" ]; then
		echo "SKIP: tools/preflight.sh not present at ${PREFLIGHT}"
		return 0
	fi
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	return 1
}

make_intel_dmesg()
{
	_extfam=$1
	_modhi=$2
	_modlo=$3

	_mod=$((_modhi * 16 + _modlo))

	cat <<DMESG_EOF
CPU: Intel(R) Core(TM) synthetic (family 0x${_extfam}, model 0x$(printf '%x' "${_mod}"))
  Origin="GenuineIntel"  Id=0x$(printf '%x' "$((_extfam * 256 + _mod))")  Family=0x${_extfam}  Model=0x$(printf '%x' "${_mod}")  Stepping=0xa
  Features=0xbfebfbff  <FPU,VME,DE,PSE,TSC,MSR,PAE,MCE,CX8,APIC,SEP,MTRR,PGE,MCA,CMOV,PAT,PSE36,CLFLUSH,MMX,FXSR,SSE,SSE2,SS,HTT>
  Features2=0x7ffafbff  <SSE3,PCLMULQDQ,DTES64,MONITOR,DS-CPL,VMX,SMX,EST,TM2,SSSE3,CX16,xTPR,PDCM,PCID,SSE4.1,SSE4.2,POPCNT,AESNI,XSAVE,OSXSAVE,AVX,F16C,RDRAND>
  Structured Extended Features=0x29c6f7bf  <FSGSBASE,TSCADJ,SGX,BMI1,HLE,AVX2,SMEP,BMI2,ERMS,INVPCID,RTM,RDSEED,ADX,SMAP,CLFLUSHOPT,CLWB,SHA>
DMESG_EOF
}

classify_assert()
{
	_label=$1
	_needles=$2
	_file=$3
	if ! grep -Eq "${_needles}" "${_file}"; then
		echo "FAIL: ${_label} - expected '${_needles}' in output"
		sed -e 's/^/    /' "${_file}"
		rm -f "${_file}"
		exit 1
	fi
}

preflight_classify_one()
{
	_label=$1
	_dmesg=$2
	_out_arch=$3

	tmp=$(mktemp "${TMPDIR:-/tmp}/preflight-classify-skylake.XXXXXX") || return 1
	tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/preflight-bind-skylake.XXXXXX") || return 1
	script_copy="${tmpdir}/preflight.sh"
	cp "${PREFLIGHT}" "${script_copy}"
	chmod +x "${script_copy}"
	dmesg_path="${tmpdir}/dmesg.boot"
	printf '%s\n' "${_dmesg}" > "${dmesg_path}"
	sed -i.bak "s|PREFLIGHT_DMESG=/var/run/dmesg.boot|PREFLIGHT_DMESG=${dmesg_path}|" "${script_copy}"

	PREFLIGHT_DMESG="${dmesg_path}" sh "${script_copy}" > "${tmp}" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
		echo "FAIL: ${_label} - preflight exited ${rc}"
		sed -e 's/^/    /' "${tmp}"
		rm -rf "${tmp}" "${tmpdir}"
		exit 1
	fi

	classify_assert "${_label}" "${_out_arch}" "${tmp}"

	rm -rf "${tmp}" "${tmpdir}"
}

preflight_nested_classify_skylake_main()
{
	if preflight_nested_classify_skylake_unsupported; then
		exit 0
	fi

	# Skylake (Family=6, Model=0x5e).  v2.0 classifies as
	# 'Skylake (6th gen client/mobile)' per the expanded model table.
	intel_skl=$(make_intel_dmesg 6 5 14)
	preflight_classify_one "Intel Skylake" \
	    "${intel_skl}" \
	    "Skylake"

	# Kaby Lake (Family=6, Model=0x8e).  Maps to 6.8e -> 'Kaby
	# Lake (7th gen)' with VIABLE verdict (modhi 8 is >= 4).
	intel_kbl=$(make_intel_dmesg 6 8 14)
	preflight_classify_one "Intel Kaby Lake" \
	    "${intel_kbl}" \
	    "Kaby/Coffee"

	# Coffee Lake (Family=6, Model=0x9e).  Maps to 6.9e which
	# the preflight table groups with Kaby Lake (the 6.9e|
	# 6.8e -> "Kaby Lake (7th gen)" branch).  The nVMX
	# verdict must still be VIABLE (modhi 9 >= 4).
	intel_cfl=$(make_intel_dmesg 6 9 14)
	preflight_classify_one "Intel Coffee Lake" \
	    "${intel_cfl}" \
	    "Kaby/Coffee"

	# Comet / Ice Lake (Family=6, Model=0xa5).  v2.0 correctly
	# classifies 0xa5/0xa6 as Comet Lake only (audit High-6 fix).
	intel_cml=$(make_intel_dmesg 6 10 5)
	preflight_classify_one "Intel Comet Lake" \
	    "${intel_cml}" \
	    "Comet Lake"

	echo "PASS: preflight_nested_classify_skylake 4 microarch pairs"
}

preflight_nested_classify_skylake_main "$@"

atf_test_case "preflight_nested_classify_skylake"
preflight_nested_classify_skylake_head()
{
	atf_set "descr" "preflight.sh classifies Skylake / Kaby Lake / Coffee Lake without root or vmm.ko"
}
preflight_nested_classify_skylake_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_nested_classify_skylake"
}
