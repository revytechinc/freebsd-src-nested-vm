#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
#
# Wave 0a / T0a follow-up: preflight test driver. Runs the four
# preflight test programs in order, prints a SUMMARY line, and is itself
# exposed as a single ATF test (`preflight_integrity`).
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
    result=$(bash "${test_script}") || {
        failed=$((failed + 1))
        printf 'FAIL: %s\n' "$(basename "${test_script}")"
        continue
    }
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

atf_test_case preflight_integrity
preflight_integrity_head()
{
    atf_set "descr" "Wave 0a preflight test matrix (2 unit + 2 integration)"
}
preflight_integrity_body()
{
    bash "$0"
}
atf_init_test_cases()
{
    atf_add_test_case preflight_integrity
}