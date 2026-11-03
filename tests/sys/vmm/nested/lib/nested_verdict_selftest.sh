#!/bin/sh
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
# Self-test for the verdict contract.
#
# This exists because the defect it guards against is not hypothetical.
# Before this test, tests/sys/vmm/nested/hw/stress/run_stress_tests.sh did:
#
#	kyua test -k "${DIR_PARENT}/Kyuafile" "${script}" || \
#	    echo "${PROGRAM}: kyua failed on ${script}"
#	...
#	return 0
#
# so a failing test was caught, printed, and discarded -- and the runner
# then printed "PASS (all stress scripts enumerated)" and exited 0.  A
# planted `exit 1` test was demonstrated not to change the runner's exit
# code.  Worse, no Kyuafile exists anywhere in this tree, so the kyua
# invocation could never have succeeded on any host, ever.
#
# The contract under test:
#
#	0   PASS   ran, assertion met
#	1   FAIL   ran, assertion not met
#	2   ERROR  COULD NOT RUN -- never green, never silent
#	77  NA     inapplicable to this silicon, with a measured reason
#	78  GAP    surface knowingly not covered yet, declared not inferred
#
# A test that never fails proves nothing, so every case below is asserted
# in BOTH directions: the state must be produced when it should be, and
# must NOT be produced when it should not.

set -u

SELF="${0##*/}"
LIBDIR="${LIBDIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"

failures=0
checks=0

check()
{
	_desc="$1"
	_want="$2"
	_got="$3"

	checks=$((checks + 1))
	if [ "${_want}" = "${_got}" ]; then
		printf 'ok   %s (got %s)\n' "${_desc}" "${_got}"
	else
		printf 'FAIL %s: wanted %s, got %s\n' "${_desc}" "${_want}" "${_got}"
		failures=$((failures + 1))
	fi
}

if [ ! -r "${LIBDIR}/nested_verdict.subr" ]; then
	printf '%s: %s/nested_verdict.subr does not exist\n' "${SELF}" "${LIBDIR}" >&2
	printf '%s: this is the red state -- the contract is not implemented yet\n' "${SELF}" >&2
	exit 1
fi

# shellcheck source=/dev/null
. "${LIBDIR}/nested_verdict.subr"

# --- the exit codes are what the contract says they are ------------------
check "NV_PASS is 0"   0  "${NV_PASS}"
check "NV_FAIL is 1"   1  "${NV_FAIL}"
check "NV_ERROR is 2"  2  "${NV_ERROR}"
check "NV_NA is 77"   77  "${NV_NA}"
check "NV_GAP is 78"  78  "${NV_GAP}"

# --- a command that fails must produce FAIL, not PASS --------------------
nv_reset
nv_case "planted failure" sh -c 'exit 1'
check "failing command -> FAIL"  1  "$(nv_last_state_code)"

# --- a command that cannot be run must produce ERROR, not PASS and not
#     FAIL.  This is the whole point: "I could not look" is its own answer.
nv_reset
nv_case "absent command" /nonexistent/definitely/not/here
check "missing binary -> ERROR"  2  "$(nv_last_state_code)"

# --- a command that succeeds must produce PASS ---------------------------
nv_reset
nv_case "planted success" sh -c 'exit 0'
check "succeeding command -> PASS"  0  "$(nv_last_state_code)"

# --- a command that exits 0 having written to stderr and produced no
#     evidence must NOT be trusted as PASS when evidence was demanded.
nv_reset
nv_case_expect_output "silent liar" 'NESTED_OK' sh -c 'echo "boom" >&2; exit 0'
check "exit 0 without required evidence -> FAIL"  1  "$(nv_last_state_code)"

# --- N/A must be reachable only with a stated reason ---------------------
nv_reset
nv_na "SVM test on an Intel part" "cpu_vendor=GenuineIntel"
check "declared N/A -> NA"  77  "$(nv_last_state_code)"

nv_reset
if nv_na "" "" 2>/dev/null; then
	check "N/A with no reason is refused"  refused  accepted
else
	check "N/A with no reason is refused"  refused  refused
fi

# --- AGGREGATION: the defect that actually shipped.  A run containing one
#     ERROR must not exit 0, and a run containing one FAIL must not exit 0.
nv_reset
nv_case "ok one"   sh -c 'exit 0'
nv_case "ok two"   sh -c 'exit 0'
nv_case "broken"   /nonexistent/definitely/not/here
nv_summary >/dev/null
check "run with one ERROR does not exit 0"  2  "$(nv_exit_code)"

nv_reset
nv_case "ok one"   sh -c 'exit 0'
nv_case "bad one"  sh -c 'exit 1'
nv_summary >/dev/null
check "run with one FAIL does not exit 0"  1  "$(nv_exit_code)"

nv_reset
nv_case "ok one"   sh -c 'exit 0'
nv_case "ok two"   sh -c 'exit 0'
nv_summary >/dev/null
check "run with all PASS exits 0"  0  "$(nv_exit_code)"

# --- the empty run.  A run that selected zero cases has not passed; it
#     has failed to run.  This is how a broken probe becomes a green CI
#     result, so it is asserted explicitly.
nv_reset
nv_summary >/dev/null
check "run with zero cases does not exit 0"  2  "$(nv_exit_code)"

# --- a case that hangs must become ERROR on timeout, not hang the run ----
nv_reset
NV_TIMEOUT=1 nv_case "hangs forever" sh -c 'sleep 30'
check "timed-out case -> ERROR"  2  "$(nv_last_state_code)"


# --- A CRASH IS NOT A FAILING ASSERTION.  Raised by Fable in review:
#     classifying every non-zero status as FAIL sends someone to debug
#     the kernel when the test process itself died.  0 is the only PASS,
#     1 the only FAIL; anything else means we did not get an answer.
nv_reset
nv_case "killed by SIGSEGV" sh -c 'kill -SEGV $$'
check "signal death -> ERROR"  2  "$(nv_last_state_code)"

nv_reset
nv_case "killed by SIGKILL" sh -c 'kill -KILL $$'
check "SIGKILL -> ERROR"  2  "$(nv_last_state_code)"

nv_reset
nv_case "exit 3 (not a test verdict)" sh -c 'exit 3'
check "unexpected status 3 -> ERROR"  2  "$(nv_last_state_code)"

nv_reset
nv_case "exit 1 is the only FAIL" sh -c 'exit 1'
check "exit 1 -> FAIL"  1  "$(nv_last_state_code)"

# --- A RUN WHERE NOTHING PASSED PROVED NOTHING.  A host on which every
#     case came back N/A must not report success: that is exactly what an
#     AMD host looks like when the AMD tests were never installed.
nv_reset
nv_na "SVM case on Intel" "cpu_vendor=GenuineIntel"
nv_na "SVM case on Intel" "cpu_vendor=GenuineIntel"
nv_summary >/dev/null
check "run with zero PASS does not exit 0"  2  "$(nv_exit_code)"

printf '\n%s: %d checks, %d failures\n' "${SELF}" "${checks}" "${failures}"
[ "${failures}" -eq 0 ] || exit 1
exit 0
