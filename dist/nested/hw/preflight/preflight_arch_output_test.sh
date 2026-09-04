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
# v2.0 regression: assert the runtime architecture output contract.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"
: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
PREFLIGHT="${repo_root}/tools/preflight.sh"

preflight_arch_output_unsupported()
{
    if [ ! -r "${PREFLIGHT}" ]; then
        echo "SKIP: tools/preflight.sh not present"
        return 0
    fi
    if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then return 1; fi
    return 1
}

preflight_arch_output_main()
{
    if preflight_arch_output_unsupported; then exit 0; fi

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/preflight-arch.XXXXXX") || exit 1
    script_copy="${tmpdir}/preflight.sh"
    cp "${PREFLIGHT}" "${script_copy}"
    chmod +x "${script_copy}"

    # Use the host's real dmesg.boot if available, otherwise fall back to a
    # synthetic Tiger Lake fixture so the assertion set exercises a known
    # rich output.  The synthetic fixture includes a VT-x rich line so the
    # EPT/VPID/APICv/posted-interrupt sub-rows are exercised.
    if [ -r /var/run/dmesg.boot ] && grep -q '^CPU:' /var/run/dmesg.boot 2>/dev/null; then
        dmesg_path=/var/run/dmesg.boot
    else
        dmesg_path="${tmpdir}/dmesg.boot"
        cat > "${dmesg_path}" <<'DMESG'
CPU: Intel(R) Core(TM) i9-11950H
  Origin="GenuineIntel"  Id=0x806d1  Family=0x6  Model=0x8d  Stepping=1
  Features=0xbfebfbff
  Features2=0x7ffafbff
  Structured Extended Features=0xf3bfa7eb
  VT-x: PAT,HLT,MTF,PAUSE,EPT,UG,VPID,VID,PostIntr
DMESG
    fi
    sed -i.bak "s|PREFLIGHT_DMESG=/var/run/dmesg.boot|PREFLIGHT_DMESG=${dmesg_path}|" "${script_copy}"

    out=$(PREFLIGHT_DMESG="${dmesg_path}" sh "${script_copy}" 2>&1) || rc=$?
    rc=${rc:-0}

    # Required structural sections.
    for needle in 'vmm.preflight  v2.0' 'silicon' 'microarch:' 'verdict'; do
        if ! printf '%s\n' "${out}" | grep -q "${needle}"; then
            echo "FAIL: missing '${needle}' in output"
            printf '%s\n' "${out}" | head -40
            rm -rf "${tmpdir}"
            exit 1
        fi
    done

    # Vendor-specific sections must appear.
    if printf '%s\n' "${out}" | grep -q 'GenuineIntel'; then
        for needle in 'VMX' 'EPT' 'microarch'; do
            printf '%s\n' "${out}" | grep -q "${needle}" || {
                echo "FAIL: Intel output missing '${needle}'"
                printf '%s\n' "${out}"
                rm -rf "${tmpdir}"
                exit 1
            }
        done
        # Tiger Lake fixture must classify correctly.
        if printf '%s\n' "${dmesg_path}" | grep -q '0x8d' 2>/dev/null \
           || grep -q 'Model=0x8d' "${dmesg_path}" 2>/dev/null; then
            if ! printf '%s\n' "${out}" | grep -qE 'Tiger Lake|11th gen'; then
                echo "FAIL: Tiger Lake (Family 6 / Model 0x8d) not classified"
                printf '%s\n' "${out}" | grep -E 'microarch|verdict'
                rm -rf "${tmpdir}"
                exit 1
            fi
        fi
    elif printf '%s\n' "${out}" | grep -q 'AuthenticAMD'; then
        for needle in 'SVM' 'NPT' 'microarch'; do
            printf '%s\n' "${out}" | grep -q "${needle}" || {
                echo "FAIL: AMD output missing '${needle}'"
                printf '%s\n' "${out}"
                rm -rf "${tmpdir}"
                exit 1
            }
        done
    fi

    echo "PASS: preflight_arch_output structure verified"
    rm -rf "${tmpdir}"
}

preflight_arch_output_main "$@"

atf_test_case "preflight_arch_output"
preflight_arch_output_head()
{
    atf_set "descr" "v2.0 output contains silicon/microarch/verdict and vendor-specific sections"
}
preflight_arch_output_body()
{
    bash "$0"
}
atf_init_test_cases()
{
    atf_add_test_case "preflight_arch_output"
}
