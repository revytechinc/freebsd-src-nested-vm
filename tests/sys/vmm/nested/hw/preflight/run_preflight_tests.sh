
#!/bin/sh
#
# Wave 0a / T0a follow-up + Wave 5/6: preflight test driver. Runs every
# preflight_*.sh program in this directory in alphabetical order and prints a
# SUMMARY line.
#
# Usage: sh run_preflight_tests.sh
#
# POSIX sh. This was bash -- mapfile, <<<, (( )) and `set -o pipefail' -- and
# bash is NOT in the FreeBSD base system, so on a stock host it could not run
# at all. Nothing reported that, because this directory installs its scripts
# as files rather than registering them as tests.
#
# The vestigial ATF glue that used to sit at the end is gone with it. It was
# guarded by `command -v atf_init_test_cases', which is false under atf-sh
# (the framework does not predefine that function), so it could never have
# taken effect -- and the driver loop above it ran at top level regardless,
# which is what breaks a test program at case-listing time. This file is a
# hand-run driver and is now only that.

set -o errexit
set -o nounset

script_dir=$(cd "$(dirname "$0")" && pwd)

# `mapfile -t tests < <(...)' is bash. A newline-separated list works in any
# shell; these paths are generated from a glob in a directory we control and
# contain no whitespace.
tests=$(printf '%s\n' "${script_dir}"/preflight_*.sh | sort)
total=$(printf '%s\n' "${tests}" | grep -c .)
passed=0
skipped=0
failed=0

for test_script in ${tests}; do
    # Strip ATF glue into a sibling file so $0 dirname (repo_root) is preserved.
    run_copy="${test_script}.run"
    sed '/^atf_test_case/,$d' "${test_script}" > "${run_copy}"
    result=$(sh "${run_copy}") || {
        rm -f "${run_copy}"
        failed=$((failed + 1))
        printf 'FAIL: %s\n' "$(basename "${test_script}")"
        continue
    }
    rm -f "${run_copy}"
    printf '%s\n' "${result}"
    if printf '%s\n' "${result}" | grep -q '^SKIP:'; then
        skipped=$((skipped + 1))
    else
        passed=$((passed + 1))
    fi
done

printf 'SUMMARY: %s/%s passed, %s skipped, %s failed\n' \
    "${passed}" "${total}" "${skipped}" "${failed}"
if [ "${failed}" -ne 0 ]; then
    exit 1
fi
