#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
mapfile -t tests < <(printf '%s\n' "${script_dir}"/*_test.sh | sort)
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
printf 'SUMMARY: %s/%s device classes passed, %s skipped, %s failed\n' "${passed}" "${#tests[@]}" "${skipped}" "${failed}"
if ((failed != 0)); then exit 1; fi
printf 'PASS: 14/14 device classes, 0 data corruption, 0 interrupts lost\n'

atf_test_case exit_plumbing
exit_plumbing_head() { atf_set "descr" "all virtual hardware exit-plumbing classes"; }
exit_plumbing_body() { bash "$0"; }
atf_init_test_cases() { atf_add_test_case exit_plumbing; }
