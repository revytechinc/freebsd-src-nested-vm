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
# v2.0 regression: assert multiple runs produce stable output (no
# nondeterministic leakage from sysctl timing, kldstat ordering, etc.).

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"
: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
PREFLIGHT="${repo_root}/tools/preflight.sh"

preflight_arch_consistency_unsupported()
{
    if [ ! -r "${PREFLIGHT}" ]; then
        echo "SKIP: tools/preflight.sh not present"
        return 0
    fi
    if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then return 1; fi
    return 1
}

preflight_arch_consistency_main()
{
    if preflight_arch_consistency_unsupported; then exit 0; fi

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/preflight-consistency.XXXXXX") || exit 1
    script_copy="${tmpdir}/preflight.sh"
    cp "${PREFLIGHT}" "${script_copy}"
    chmod +x "${script_copy}"

    if [ -r /var/run/dmesg.boot ] && grep -q '^CPU:' /var/run/dmesg.boot 2>/dev/null; then
        dmesg_path=/var/run/dmesg.boot
    else
        dmesg_path="${tmpdir}/dmesg.boot"
        cat > "${dmesg_path}" <<'DMESG'
CPU: Intel(R) Core(TM) synthetic (Family 6 Model 0x8d)
  Origin="GenuineIntel"  Id=0x806d1  Family=0x6  Model=0x8d  Stepping=1
  Features=0xbfebfbff
  Features2=0x7ffafbff
  Structured Extended Features=0xf3bfa7eb
DMESG
    fi
    sed -i.bak "s|PREFLIGHT_DMESG=/var/run/dmesg.boot|PREFLIGHT_DMESG=${dmesg_path}|" "${script_copy}"

    # Strip volatile lines (boottime, uptime, /dev/vmm mtime, etc.) so
    # we compare only the deterministic identity/capability rows.
    normalize() {
        sed -E \
            -e 's|uptime:.*|uptime: <vol>|' \
            -e 's|boottime.*|boottime <vol>|' \
            -e 's|[0-9]+ bytes \([^)]*\)|<vol>|' \
            -e 's|^  /dev/vmm:.*|  /dev/vmm: <vol>|' \
            -e 's|hw\.vmm\.svm\.features:.*|hw.vmm.svm.features: <vol>|' \
            -e 's|hw\.vmm\.svm\.num_asids:.*|hw.vmm.svm.num_asids: <vol>|'
    }

    out1=$(PREFLIGHT_DMESG="${dmesg_path}" sh "${script_copy}" 2>&1 | normalize)
    out2=$(PREFLIGHT_DMESG="${dmesg_path}" sh "${script_copy}" 2>&1 | normalize)
    out3=$(PREFLIGHT_DMESG="${dmesg_path}" sh "${script_copy}" 2>&1 | normalize)

    if [ "${out1}" != "${out2}" ] || [ "${out2}" != "${out3}" ]; then
        echo "FAIL: nondeterministic output across 3 runs"
        diff <(printf '%s\n' "${out1}") <(printf '%s\n' "${out2}") | head -40
        rm -rf "${tmpdir}"
        exit 1
    fi

    echo "PASS: preflight_arch_consistency stable across 3 runs"
    rm -rf "${tmpdir}"
}

preflight_arch_consistency_main "$@"

atf_test_case "preflight_arch_consistency"
preflight_arch_consistency_head()
{
    atf_set "descr" "v2.0 output is deterministic across repeated runs"
}
preflight_arch_consistency_body()
{
    bash "$0"
}
atf_init_test_cases()
{
    atf_add_test_case "preflight_arch_consistency"
}
