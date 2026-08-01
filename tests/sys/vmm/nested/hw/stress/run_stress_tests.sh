#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
mapfile -t tests < <(printf '%s\n' "${script_dir}"/*_stress_test.sh | sort)
passed=0
skipped=0
failed=0
for test_script in "${tests[@]}"; do
    result=$(bash "${test_script}") || {
        failed=$((failed + 1))
        continue
    }
    printf '%s\n' "${result}"
    if grep -q '^SKIP:' <<<"${result}"; then
        skipped=$((skipped + 1))
    else
        passed=$((passed + 1))
    fi
done
printf 'SUMMARY: %s/%s stress classes passed, %s skipped, %s failed\n' "${passed}" "${#tests[@]}" "${skipped}" "${failed}"
if ((failed != 0)); then exit 1; fi
printf 'PASS: multi-device concurrent I/O clean\n'

atf_test_case stress
stress_head() { atf_set "descr" "all virtual hardware stress classes"; }
stress_body() { bash "$0"; }
atf_init_test_cases() { atf_add_test_case stress; }
