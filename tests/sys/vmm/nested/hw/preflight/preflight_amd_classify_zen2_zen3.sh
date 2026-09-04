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
# Wave 5 / T1 follow-up: AMD microarch classification for Zen2 and
# Zen3.  Verifies the post-wave-5 family table (which collapsed Zen3
# into the Zen4/Zen5 verdict family) handles 0x17/0x19 correctly.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
PREFLIGHT="${repo_root}/tools/preflight.sh"

preflight_amd_classify_zen2_zen3_unsupported()
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

make_amd_dmesg()
{
	_extfam=$1
	_amdfn2_hex="$2"
	_model=$3

	# Convert hex family suffix to decimal for the Id arithmetic.
	_extfam_dec=$(printf '%d' "0x${_extfam}" 2>/dev/null)
	[ -z "${_extfam_dec}" ] && _extfam_dec=0
	_id_hex=$(printf '%x' "$((_extfam_dec * 256 + _model))")

	cat <<DMESG_EOF
CPU: AuthenticAMD synthetic (family 0x${_extfam})
  Origin="AuthenticAMD"  Id=0x${_id_hex}  Family=0x${_extfam}  Model=0x$(printf '%x' "${_model}")  Stepping=0x0
  Features=0x178bfbff  <FPU,VME,DE,PSE,TSC,MSR,PAE,MCE,CX8,APIC,SEP,MTRR,PGE,MCA,CMOV,PAT,PSE36,CLFLUSH,MMX,FXSR,SSE,SSE2>
  Features2=0x75a237ff  <SSE3,PCLMULQDQ,MONITOR,SSSE3,FMA,CX16,xTPR,AESNI,XSAVE,OSXSAVE,AVX,F16C>
  AMD Features=0x2f03f7ff  <FPU,VME,DE,PSE,TSC,MSR,PAE,MCE,CX8,APIC,SYSCALL,MP,MMX,FXSR,SSE,SSE2,RDTSCP,LM,3DNOWP>
  AMD Features2=0x${_amdfn2_hex}  <LAHF,ABM,SSE4A,BMI1,AVX,XOP,BMI2,F16C,MSRDEADLINE>
  SVM: NP,NRIP,VClean,AFlush,DAssist,NAsids=64
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
	_verdict=${4:-}

	tmp=$(mktemp "${TMPDIR:-/tmp}/preflight-classify-amd.XXXXXX") || return 1
	tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/preflight-bind-amd.XXXXXX") || return 1
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
	if [ -n "${_verdict}" ]; then
		classify_assert "${_label} verdict" "${_verdict}" "${tmp}"
	fi

	rm -rf "${tmp}" "${tmpdir}"
}

preflight_amd_classify_zen2_zen3_main()
{
	if preflight_amd_classify_zen2_zen3_unsupported; then
		exit 0
	fi

	# Zen2 (Family=0x17, Model=0x31).  v2.0 maps 17h:0x30..0xaf to Zen 2.
	# (Models 0x00..0x2f in family 17h are Zen 1.)
	amd_zen2=$(make_amd_dmesg 17 "75a337ff" 0x31)
	preflight_classify_one "AMD Zen2" \
	    "${amd_zen2}" \
	    "Zen 2"

	# Zen3 (Family=0x19, Model=0x01).  v2.0 maps 0x00..0x0f + 0x20..0x5f
	# in family 19h to Zen 3 (Milan / Vermeer / Cezanne / Rembrandt).
	amd_zen3=$(make_amd_dmesg 19 "75a337ff" 0x01)
	preflight_classify_one "AMD Zen3" \
	    "${amd_zen3}" \
	    "Zen 3"

	echo "PASS: preflight_amd_classify_zen2_zen3 2 microarch pairs"
}

preflight_amd_classify_zen2_zen3_main "$@"

atf_test_case "preflight_amd_classify_zen2_zen3"
preflight_amd_classify_zen2_zen3_head()
{
	atf_set "descr" "preflight.sh classifies Zen2 (17h) and Zen3 (19h) without root or vmm.ko"
}
preflight_amd_classify_zen2_zen3_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_amd_classify_zen2_zen3"
}
