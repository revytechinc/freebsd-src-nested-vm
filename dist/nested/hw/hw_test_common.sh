#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause

set -o errexit
set -o nounset
set -o pipefail

: "${NESTED_L2_SSH:=ssh}"
: "${NESTED_L2_TARGET:=}"
: "${NESTED_L2_TIMEOUT:=120}"

run_l2_device_test() {
    local device="$1"
    local command="$2"
    local output

    if [[ -z "${NESTED_L2_TARGET}" ]]; then
        printf 'SKIP: %s (set NESTED_L2_TARGET to an mfsBSD L2 target)\n' "${device}"
        return 0
    fi

    printf 'BEGIN: %s\n' "${device}"
    output=$(mktemp "${TMPDIR:-/tmp}/nested-${device}.XXXXXX")
    trap 'rm -f "${output}"' RETURN
    if "${NESTED_L2_SSH}" "${NESTED_L2_TARGET}" "${command}" >"${output}" 2>&1; then
        if grep -Eq '(^|[[:space:]])(error|fail(ed)?|panic)([[:space:]]|:|$)' "${output}"; then
            cat "${output}"
            printf 'FAIL: %s (L2 reported an error)\n' "${device}"
            return 1
        fi
        cat "${output}"
        printf 'PASS: %s (L0 -> L1 -> L2 round-trip)\n' "${device}"
        return 0
    fi

    cat "${output}"
    printf 'FAIL: %s (L2 command failed)\n' "${device}"
    return 1
}

run_l2_stress_test() {
    local device="$1"
    local command="$2"
    local workers="${NESTED_STRESS_WORKERS:-4}"
    local worker
    local pids=()
    local status=0

    if [[ -z "${NESTED_L2_TARGET}" ]]; then
        printf 'SKIP: %s stress (set NESTED_L2_TARGET to an mfsBSD L2 target)\n' "${device}"
        return 0
    fi

    printf 'BEGIN: %s stress (%s workers)\n' "${device}" "${workers}"
    for ((worker = 1; worker <= workers; worker++)); do
        "${NESTED_L2_SSH}" "${NESTED_L2_TARGET}" "${command}" &
        pids+=("$!")
    done
    for worker in "${pids[@]}"; do
        if ! wait "${worker}"; then
            status=1
        fi
    done
    if ((status == 0)); then
        printf 'PASS: %s concurrent load (L0 -> L1 -> L2)\n' "${device}"
    else
        printf 'FAIL: %s concurrent load\n' "${device}"
    fi
    return "${status}"
}
