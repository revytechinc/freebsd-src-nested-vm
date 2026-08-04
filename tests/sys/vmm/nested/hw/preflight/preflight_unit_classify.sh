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
# T0a / Wave 0a: preflight unit classify. Pipes synthetic dmesg.boot
# payloads through tools/preflight.sh and asserts the microarchitecture
# and verdict lines for four representative CPUs (Intel Ivy Bridge +
# Haswell, AMD Bulldozer + Zen1+/Zen4+). No root, no vmm.ko.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../.." && pwd)
PREFLIGHT="${repo_root}/tools/preflight.sh"

preflight_unit_classify_unsupported()
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

make_amd_dmesg()
{
	_extfam=$1
	_svm_line="$2"
	_amdfn2_hex="$3"

	cat <<DMESG_EOF
CPU: AuthenticAMD synthetic (family 0x${_extfam})
  Origin="AuthenticAMD"  Id=0x$(printf '%x' "$((_extfam * 256))")  Family=0x${_extfam}  Model=0x00  Stepping=0x0
  Features=0x178bfbff  <FPU,VME,DE,PSE,TSC,MSR,PAE,MCE,CX8,APIC,SEP,MTRR,PGE,MCA,CMOV,PAT,PSE36,CLFLUSH,MMX,FXSR,SSE,SSE2>
  Features2=0x75a237ff  <SSE3,PCLMULQDQ,MONITOR,SSSE3,FMA,CX16,xTPR,AESNI,XSAVE,OSXSAVE,AVX,F16C>
  AMD Features=0x2f03f7ff  <FPU,VME,DE,PSE,TSC,MSR,PAE,MCE,CX8,APIC,SYSCALL,MP,MMX,FXSR,SSE,SSE2,RDTSCP,LM,3DNOWP>
  AMD Features2=0x${_amdfn2_hex}  <LAHF,ABM,SSE4A,BMI1,AVX,XOP,BMI2,F16C,MSRDEADLINE>
${_svm_line:+${_svm_line}}
DMESG_EOF
}

classify_assert()
{
	_label=$1
	_needle=$2
	_file=$3
	if ! grep -q "${_needle}" "${_file}"; then
		echo "FAIL: ${_label} - expected '${_needle}' in output"
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
	_out_verdict=$4

	tmp=$(mktemp "${TMPDIR:-/tmp}/preflight-classify.XXXXXX") || return 1
	# tools/preflight.sh reads /var/run/dmesg.boot; bind-mount via env is
	# not portable across FreeBSD versions, so instead create a temp copy
	# and execute the script with stdin redirected through sh -c that
	# inlines the DMESG content via a here-doc.  Because the production
	# script hard-codes DMESG=/var/run/dmesg.boot we cannot inject without
	# root, so use a wrapper that creates a temporary directory and
	# bind-mounts it onto /var/run if possible; otherwise we fall back to
	# a perl-style sed that rewrites the path inside a copy of the script.
	tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/preflight-bind.XXXXXX") || return 1
	script_copy="${tmpdir}/preflight.sh"
	cp "${PREFLIGHT}" "${script_copy}"
	chmod +x "${script_copy}"
	dmesg_path="${tmpdir}/dmesg.boot"
	printf '%s\n' "${_dmesg}" > "${dmesg_path}"
	# Patch the DMESG path inside the copy.
	sed -i.bak "s|DMESG=/var/run/dmesg.boot|DMESG=${dmesg_path}|" "${script_copy}"

	sh "${script_copy}" > "${tmp}" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
		echo "FAIL: ${_label} - preflight exited ${rc}"
		sed -e 's/^/    /' "${tmp}"
		rm -rf "${tmp}" "${tmpdir}"
		exit 1
	fi

	classify_assert "${_label}" "${_out_arch}" "${tmp}"
	classify_assert "${_label}" "${_out_verdict}" "${tmp}"

	rm -rf "${tmp}" "${tmpdir}"
}

preflight_unit_classify_main()
{
	if preflight_unit_classify_unsupported; then
		exit 0
	fi

	# Intel Ivy Bridge: family=6 model=0x3a -> model hi=3 lo=10.
	intel_ivy=$(make_intel_dmesg 6 3 10)
	preflight_classify_one "Intel Ivy Bridge" \
	    "${intel_ivy}" \
	    "Ivy Bridge" \
	    "BLOCKED"

	# Intel Haswell: family=6 model=0x3c -> model hi=3 lo=12.
	intel_has=$(make_intel_dmesg 6 3 12)
	preflight_classify_one "Intel Haswell" \
	    "${intel_has}" \
	    "Haswell" \
	    "VIABLE"

	# AMD Bulldozer: family=0x15 with SVM features line.  amdfn2 EDX[2]
	# is the SVM bit; include it for the SVM PRESENT line.
	amd_bulldozer=$(make_amd_dmesg 15 "  SVM: NP,NRIP,VClean" "70010201")
	preflight_classify_one "AMD Bulldozer" \
	    "${amd_bulldozer}" \
	    "Bulldozer" \
	    "VIABLE"

	# AMD Zen1+ (Family 17h): VIABLE/FULLY VIABLE path.
	amd_zen=$(make_amd_dmesg 17 "  SVM: NP,NRIP,VClean,AFlush,DAssist,NAsids=64" "75a337ff")
	preflight_classify_one "AMD Zen1+" \
	    "${amd_zen}" \
	    "Zen1" \
	    "FULLY VIABLE"

	# AMD Zen4+ (Family 18h): VIABLE/FULLY VIABLE path.
	amd_zen4=$(make_amd_dmesg 18 "  SVM: NP,NRIP,VClean,AFlush,DAssist,NAsids=64" "75a337ff")
	preflight_classify_one "AMD Zen4+" \
	    "${amd_zen4}" \
	    "Zen4" \
	    "FULLY VIABLE"

	echo "PASS: preflight_unit_classify 5 CPU microarch/verdict pairs"
}

preflight_unit_classify_main "$@"

atf_test_case "preflight_unit_classify"
preflight_unit_classify_head()
{
	atf_set "descr" "preflight.sh classifies 5 representative CPUs without root or vmm.ko"
}
preflight_unit_classify_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_unit_classify"
}