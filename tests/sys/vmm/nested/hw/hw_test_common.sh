# SPDX-License-Identifier: BSD-2-Clause
#
# Shared helpers for the hw/ device tests.
#
# POSIX sh, and NO SHEBANG, deliberately.
#
# This file was bash: `#!/usr/bin/env bash', [[ ]], arrays, `for ((...))',
# ((...)) arithmetic commands and `trap ... RETURN'. That was wrong twice over.
#
# First, bash is NOT in the FreeBSD base system. A test that needs it fails on
# a stock host for a reason that has nothing to do with the hypervisor.
#
# Second, atf-sh runs a test program with /bin/sh whatever the shebang says, so
# every bashism here became a syntax error at the moment kyua tried to list the
# test's cases -- reported as "broken: Test program did not exit cleanly",
# which does not name a shell, a line, or a construct. Two test programs died
# that way and nobody saw it, because the directories holding them were listed
# under SUBDIR rather than TESTS_SUBDIRS and so never appeared in a Kyuafile.
#
# Keep this file POSIX. `local' is the one concession: it is not in POSIX but
# every shell that will ever run this has it, including FreeBSD's /bin/sh.

: "${NESTED_L2_SSH:=ssh}"
: "${NESTED_L2_TARGET:=}"
: "${NESTED_L2_TIMEOUT:=120}"

# AN UNCONFIGURED L2 TARGET IS A SKIP, NOT A PASS.
#
# Both helpers below used to print "SKIP: <device>" and `return 0' when
# NESTED_L2_TARGET was unset. Under atf that is reported as PASSED: a test
# that never contacted an L2 guest, on a host where nothing sets that variable
# -- which is every host, since nothing in the tree sets it -- counted as
# coverage. The word SKIP appeared only in the log, where no one reads it, and
# kyua's summary said the test passed.
#
# atf_skip does not return, so the callers' `return 0' after this is reached
# only outside atf.
nested_l2_unconfigured() {
	local device="$1"

	if command -v atf_skip >/dev/null 2>&1; then
		atf_skip "${device}: set NESTED_L2_TARGET to an mfsBSD L2 target"
	fi
	# Sourced by something that is not an atf test: say so and carry on,
	# because there is no test result to misreport.
	printf 'SKIP: %s (set NESTED_L2_TARGET to an mfsBSD L2 target)\n' "${device}"
}

run_l2_device_test() {
	local device="$1"
	local command="$2"
	local output
	local rc

	if [ -z "${NESTED_L2_TARGET}" ]; then
		nested_l2_unconfigured "${device}"
		return 0
	fi

	printf 'BEGIN: %s\n' "${device}"
	output=$(mktemp "${TMPDIR:-/tmp}/nested-${device}.XXXXXX")
	# `trap ... RETURN' is a bash feature and silently did nothing useful
	# under sh, so the temporary file is removed explicitly on every path
	# out of this function instead.
	if "${NESTED_L2_SSH}" "${NESTED_L2_TARGET}" "${command}" >"${output}" 2>&1; then
		if grep -Eq '(^|[[:space:]])(error|fail(ed)?|panic)([[:space:]]|:|$)' "${output}"; then
			cat "${output}"
			rm -f "${output}"
			printf 'FAIL: %s (L2 reported an error)\n' "${device}"
			return 1
		fi
		cat "${output}"
		rm -f "${output}"
		printf 'PASS: %s (L0 -> L1 -> L2 round-trip)\n' "${device}"
		return 0
	fi

	cat "${output}"
	rm -f "${output}"
	printf 'FAIL: %s (L2 command failed)\n' "${device}"
	return 1
}

run_l2_stress_test() {
	local device="$1"
	local command="$2"
	local workers="${NESTED_STRESS_WORKERS:-4}"
	local worker
	local pids
	local status

	if [ -z "${NESTED_L2_TARGET}" ]; then
		nested_l2_unconfigured "${device} stress"
		return 0
	fi

	printf 'BEGIN: %s stress (%s workers)\n' "${device}" "${workers}"

	# A space-separated list rather than an array, and a while loop rather
	# than `for ((...))'. Both bash-only.
	pids=""
	worker=1
	while [ "${worker}" -le "${workers}" ]; do
		"${NESTED_L2_SSH}" "${NESTED_L2_TARGET}" "${command}" &
		pids="${pids} $!"
		worker=$((worker + 1))
	done

	status=0
	for worker in ${pids}; do
		wait "${worker}" || status=1
	done

	if [ "${status}" -eq 0 ]; then
		printf 'PASS: %s concurrent load (L0 -> L1 -> L2)\n' "${device}"
	else
		printf 'FAIL: %s concurrent load\n' "${device}"
	fi
	return "${status}"
}
