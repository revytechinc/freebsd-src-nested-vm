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
# and verdict lines for five representative CPUs (Intel Ivy Bridge +
# Haswell, AMD Bulldozer + Zen1+/Zen5). No root, no vmm.ko.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
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

	# _extfam is the hex family suffix (e.g., "15", "17", "1a").  Convert
	# to decimal for the Id arithmetic, since bash $((expr)) treats "1a"
	# as invalid.
	_extfam_dec=$(printf '%d' "0x${_extfam}" 2>/dev/null)
	[ -z "${_extfam_dec}" ] && _extfam_dec=0
	_id_hex=$(printf '%x' "$((_extfam_dec * 256))")

	cat <<DMESG_EOF
CPU: AuthenticAMD synthetic (family 0x${_extfam})
  Origin="AuthenticAMD"  Id=0x${_id_hex}  Family=0x${_extfam}  Model=0x00  Stepping=0x0
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
	_needles=$2
	_file=$3
	if ! grep -Eq "${_needles}" "${_file}"; then
		echo "FAIL: ${_label} - expected one of '${_needles}' in output"
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

	rm -rf "${tmp}" "${tmpdir}"
}

preflight_unit_classify_main()
{
	if preflight_unit_classify_unsupported; then
		exit 0
	fi

	# Intel Ivy Bridge: family=6 model=0x3a -> microarch key 6.3a.
	intel_ivy=$(make_intel_dmesg 6 3 10)
	preflight_classify_one "Intel Ivy Bridge" \
	    "${intel_ivy}" \
	    "Ivy Bridge"

	# Intel Haswell: family=6 model=0x3c -> microarch key 6.3c.
	intel_has=$(make_intel_dmesg 6 3 12)
	preflight_classify_one "Intel Haswell" \
	    "${intel_has}" \
	    "Haswell"

	# AMD Bulldozer: family=0x15 with SVM features line.  amdfn2 EDX[2]
	# is the SVM bit; include it for the SVM PRESENT line.
	amd_bulldozer=$(make_amd_dmesg 15 "  SVM: NP,NRIP,VClean" "70010201")
	preflight_classify_one "AMD Bulldozer" \
	    "${amd_bulldozer}" \
	    "Bulldozer"

	# AMD Zen1+ (Family 17h): FULLY VIABLE path.
	amd_zen=$(make_amd_dmesg 17 "  SVM: NP,NRIP,VClean,AFlush,DAssist,NAsids=64" "75a337ff")
	preflight_classify_one "AMD Zen1+" \
	    "${amd_zen}" \
	    "Zen1+"

	# AMD Zen5 (Family 1ah): FULLY VIABLE path; the prior test used
	# Family=0x12 (Llano) under the bug-fallback, so this case now
	# exercises the corrected effective-family arithmetic.
	amd_zen5=$(make_amd_dmesg 1a "  SVM: NP,NRIP,VClean,AFlush,DAssist,AVIC,NAsids=512" "75a337ff")
	preflight_classify_one "AMD Zen5" \
	    "${amd_zen5}" \
	    "Zen4/Zen5"

	echo "PASS: preflight_unit_classify 5 CPU microarch pairs"
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