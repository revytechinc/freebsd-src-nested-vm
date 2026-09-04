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
# v2.0 regression: assert each audit-critical bug is gone.  This feeds
# crafted synthetic dmesg payloads through the rewritten preflight and
# asserts the labels/bits/source-fields are correct.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"
: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
PREFLIGHT="${repo_root}/tools/preflight.sh"

preflight_critical_bugfix_unsupported()
{
    if [ ! -r "${PREFLIGHT}" ]; then
        echo "SKIP: tools/preflight.sh not present"
        return 0
    fi
    if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then return 1; fi
    return 1
}

# make_intel_synthetic FAM_MODEL_HEX FEAT1_HEX FEAT2_HEX EXT_HEX
# FAM_MODEL_HEX is the full (family*256+model) CPUID value as a hex string
# (e.g. "0x0608d" for Family 6, Model 0x8d).
make_intel_synthetic()
{
    _id_hex=$1
    _id_dec=$(printf '%d' "$_id_hex")
    _extfam_dec=$(( _id_dec / 256 ))
    _mod_dec=$(( _id_dec % 256 ))
    _fam_hex=$(printf '%x' "$_extfam_dec")
    _mod_hex=$(printf '%02x' "$_mod_dec")
    _feat1=$2
    _feat2=$3
    _extfeat=$4
    cat <<DMESG
CPU: Intel(R) synthetic family=${_fam_hex} model=${_mod_hex}
  Origin="GenuineIntel"  Id=${_id_hex}  Family=0x${_fam_hex}  Model=0x${_mod_hex}  Stepping=0xa
  Features=0x${_feat1}
  Features2=0x${_feat2}
  Structured Extended Features=0x${_extfeat}
DMESG
}

# make_amd_synthetic FAM_MODEL_DEC SVM_LINE AMDFN2_HEX
make_amd_synthetic()
{
    _fam_dec=$(( $1 / 256 ))
    _mod_dec=$(( $1 % 256 ))
    _fam_hex=$(printf '%x' "$_fam_dec")
    _mod_hex=$(printf '%02x' "$_mod_dec")
    _id_hex=$(printf '%x' "$1")
    cat <<DMESG
CPU: AMD synthetic family=${_fam_hex} model=${_mod_hex}
  Origin="AuthenticAMD"  Id=0x${_id_hex}  Family=0x${_fam_hex}  Model=0x${_mod_hex}  Stepping=0x0
  Features=0x178bfbff
  Features2=0x75a237ff
  AMD Features=0x2f03f7ff
  AMD Features2=0x3
${2:+  $2}
DMESG
}

# run_preflight DMESG_TEXT -> prints exit code and full output.
run_preflight()
{
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/preflight-crit.XXXXXX") || return 1
    script_copy="${tmpdir}/preflight.sh"
    cp "${PREFLIGHT}" "${script_copy}"
    chmod +x "${script_copy}"
    dmesg_path="${tmpdir}/dmesg.boot"
    printf '%s\n' "$1" > "${dmesg_path}"
    sed -i.bak "s|PREFLIGHT_DMESG=/var/run/dmesg.boot|PREFLIGHT_DMESG=${dmesg_path}|" "${script_copy}"
    PREFLIGHT_DMESG="${dmesg_path}" sh "${script_copy}" > "${tmpdir}/out" 2> "${tmpdir}/err"
    rc=$?
    cat "${tmpdir}/out"
    printf 'STDERR:\n' >&2
    cat "${tmpdir}/err" >&2
    rm -rf "${tmpdir}"
    return $rc
}

preflight_critical_bugfix_main()
{
    if preflight_critical_bugfix_unsupported; then exit 0; fi

    # ----- Crit-1: AMD SVM register labels ------------------------------
    # SVM is 0x80000001:ECX[2] (not EDX[2]).
    amd_dmesg=$(make_amd_synthetic $((0x1a * 256 + 0x24)) \
        "SVM: NP,NRIP,VClean,AFlush,DAssist,NAsids=64" "c003ff")
    out=$(run_preflight "${amd_dmesg}")
    if ! printf '%s\n' "${out}" | grep -q 'SVM (0x80000001:ECX\[2\]):'; then
        echo "FAIL: AMD SVM label still mislabeled (Crit-1 not fixed)"
        printf '%s\n' "${out}" | grep SVM
        exit 1
    fi
    if printf '%s\n' "${out}" | grep -q 'SVM (0x80000001:EDX'; then
        echo "FAIL: AMD SVM label still says EDX (Crit-1 not fixed)"
        printf '%s\n' "${out}" | grep SVM
        exit 1
    fi

    # ----- Crit-2: AMD NPT comes from 0x8000000A:EDX[0] -----------------
    if ! printf '%s\n' "${out}" | grep -q 'NPT (0x8000000A:EDX\[0\]):'; then
        echo "FAIL: AMD NPT not from 0x8000000A:EDX[0] (Crit-2 not fixed)"
        printf '%s\n' "${out}" | grep -E 'NPT|0x80000001'
        exit 1
    fi
    if printf '%s\n' "${out}" | grep -q 'NPT (0x80000001:EDX'; then
        echo "FAIL: AMD NPT label still references 0x80000001 (Crit-2 not fixed)"
        exit 1
    fi
    # ECX[1] (CMP) must NOT be reported as NPT.
    if printf '%s\n' "${out}" | grep -E 'NPT.*ECX\[1\]|0x80000001:ECX\[1\].*NPT'; then
        echo "FAIL: NPT still reads from CMP bit (Crit-2 not fixed)"
        exit 1
    fi

    # ----- Crit-4: no 'L0: not found' shell error -----------------------
    err=$(PREFLIGHT_DMESG=/dev/null sh "${PREFLIGHT}" 2>&1 >/dev/null)
    if printf '%s\n' "${err}" | grep -q 'L0: not found'; then
        echo "FAIL: shell parse error at line 291 still present (Crit-4 not fixed)"
        printf '%s\n' "${err}" | grep 'L0'
        exit 1
    fi

    # ----- High-5: SMEP bit is leaf 7 EBX bit 7, not bit 6 -------------
    # Build a fixture where bit 6 is set but bit 7 is clear; the script
    # must report SMEP as absent.
    # Feature field bits: ...0x40=FDP, 0x80=SMEP.
    # extfeat = 0x00000040 -> only FDP, no SMEP.
    intel_synthetic=$(make_intel_synthetic 0x608d bfebfbff 7ffafbff 00000040)
    out=$(run_preflight "${intel_synthetic}")
    if ! printf '%s\n' "${out}" | grep -q 'SMEP (7:EBX\[7\]):'; then
        echo "FAIL: SMEP label not updated to EBX[7] (High-5 not fixed)"
        printf '%s\n' "${out}" | grep SMEP
        exit 1
    fi
    if printf '%s\n' "${out}" | grep -q 'SMEP (7:EBX\[6\]):'; then
        echo "FAIL: SMEP label still says EBX[6] (High-5 not fixed)"
        exit 1
    fi
    # With extfeat=0x40 (bit 6 only) SMEP must be reported absent.
    if ! printf '%s\n' "${out}" | grep -E 'SMEP.*absent'; then
        echo "FAIL: SMEP not flagged absent when only bit 6 set (High-5 not fixed)"
        printf '%s\n' "${out}" | grep SMEP
        exit 1
    fi
    # With extfeat=0x80 (bit 7 only) SMEP must be reported PRESENT.
    intel_synthetic=$(make_intel_synthetic 0x608d bfebfbff 7ffafbff 00000080)
    out=$(run_preflight "${intel_synthetic}")
    if ! printf '%s\n' "${out}" | grep -E 'SMEP.*PRESENT'; then
        echo "FAIL: SMEP not flagged PRESENT when only bit 7 set (High-5 not fixed)"
        printf '%s\n' "${out}" | grep SMEP
        exit 1
    fi

    # ----- High-6: Intel Tiger Lake model 0x8d is classified -----------
    intel_tigerlake=$(make_intel_synthetic 0x608d bfebfbff 7ffafbff 00000080)
    out=$(run_preflight "${intel_tigerlake}")
    if ! printf '%s\n' "${out}" | grep -qE 'Tiger Lake'; then
        echo "FAIL: Tiger Lake (0x8d) not classified (High-6 not fixed)"
        printf '%s\n' "${out}" | grep microarch
        exit 1
    fi

    # ----- High-7: AMD Zen 5 model 0x24 (HX 370) classified ------------
    if ! printf '%s\n' "${out}" > /dev/null; then :; fi
    amd_zen5=$(make_amd_synthetic $((0x1a * 256 + 0x24)) \
        "SVM: NP,NRIP,VClean,AFlush,DAssist,AVIC,NAsids=512" "75a337ff")
    out=$(run_preflight "${amd_zen5}")
    if ! printf '%s\n' "${out}" | grep -q 'Zen 5'; then
        echo "FAIL: AMD Family 1A Model 0x24 not classified as Zen 5 (High-7 not fixed)"
        printf '%s\n' "${out}" | grep microarch
        exit 1
    fi

    # ----- AVIC must NOT be falsely claimed when SVM leaf omits it -----
    # Reuse the AMD fixture without AVIC in the SVM line.
    amd_no_avic=$(make_amd_synthetic $((0x1a * 256 + 0x24)) \
        "SVM: NP,NRIP,VClean,AFlush,DAssist,NAsids=64" "75a337ff")
    out=$(run_preflight "${amd_no_avic}")
    if ! printf '%s\n' "${out}" | grep -qE 'AVIC.*absent'; then
        echo "FAIL: AVIC falsely claimed when SVM leaf lacks AVIC"
        printf '%s\n' "${out}" | grep -E 'AVIC|verdict'
        exit 1
    fi
    if printf '%s\n' "${out}" | grep -qE 'AVIC.*PRESENT'; then
        echo "FAIL: AVIC PRESENT in output when SVM leaf lacks AVIC"
        exit 1
    fi

    echo "PASS: preflight_critical_bugfix audit-checks all pass"
}

preflight_critical_bugfix_main "$@"

atf_test_case "preflight_critical_bugfix"
preflight_critical_bugfix_head()
{
    atf_set "descr" "v2.0 fixes the audit's critical bugs (SVM labels, NPT source, SMEP bit, L0 parse error)"
}
preflight_critical_bugfix_body()
{
    bash "$0"
}
atf_init_test_cases()
{
    atf_add_test_case "preflight_critical_bugfix"
}
