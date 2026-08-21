#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
#
# Wave 0a / T0a follow-up + Wave 5/6: preflight test driver. Runs
# every preflight_*.sh program in the directory in alphabetical
# order, prints a SUMMARY line, and is itself exposed as a single
# ATF test (preflight_integrity).
#
# Usage: bash run_preflight_tests.sh

set -o errexit
set -o nounset
set -o pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
mapfile -t tests < <(printf '%s\n' "${script_dir}"/preflight_*.sh | sort)
total=${#tests[@]}
passed=0
skipped=0
failed=0

for test_script in "${tests[@]}"; do
    # Strip ATF glue into a sibling file so $0 dirname (repo_root) is preserved.
    run_copy="${test_script}.run"
    sed '/^atf_test_case/,$d' "${test_script}" > "${run_copy}"
    result=$(bash "${run_copy}") || {
        rm -f "${run_copy}"
        failed=$((failed + 1))
        printf 'FAIL: %s\n' "$(basename "${test_script}")"
        continue
    }
    rm -f "${run_copy}"
    printf '%s\n' "${result}"
    if grep -q '^SKIP:' <<<"${result}"; then
        skipped=$((skipped + 1))
    else
        passed=$((passed + 1))
    fi
done

printf 'SUMMARY: %s/%s passed, %s skipped, %s failed\n' \
    "${passed}" "${total}" "${skipped}" "${failed}"
if ((failed != 0)); then
    exit 1
fi

# Kyua/ATF glue — not used for standalone bash runs.
if command -v atf_init_test_cases >/dev/null 2>&1; then
    atf_test_case preflight_integrity
    preflight_integrity_head()
    {
        atf_set "descr" "Wave 0a + Wave 5/6 preflight test matrix"
    }
    preflight_integrity_body()
    {
        bash "$0"
    }
    atf_init_test_cases()
    {
        atf_add_test_case preflight_integrity
    }
fi
