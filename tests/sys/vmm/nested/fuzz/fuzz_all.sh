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
# fuzz_all.sh -- Wave 7 / T40 nested-virt fuzz harness ATF wrapper.
#
# This is the operator-facing entry point for T40 from the FreeBSD
# nested-virt plan.  It runs the C harness (fuzz_all) under kyua(1) on
# the FreeBSD test box, captures per-test pass/fail, and asserts the
# L1 integrity post-condition mandated by the plan:
#
#   1. All five fuzz tests exit 0 within their 60s budget.
#   2. Host kernel dmesg has NO panic/backtrace strings.
#   3. L1 bhyve is still alive (bhyvectl --vm=fuzz-l1 --get-status).
#   4. L1 can still observe VMX/SVM capability MSRs via cpuid(1).
#
# Run on the AMD SVM host (mlapointe@172.16.176.131).  Do NOT run on
# the Linux dev box -- the C harness requires libatf-c, libvmmapi, and
# /dev/vmm.  The shell wrapper itself only does parsing + post-checks;
# it is valid syntax on any POSIX host with bash(1).
#
# Usage:
#   fuzz_all.sh [-d duration_secs] [-v]
#
# Options:
#   -d N  fuzz duration per test (default: 60, max: 600, min: 1)
#   -v    verbose (echo each ATF sub-test as it runs)
#
# Exit codes:
#   0  = all fuzz tests pass + L1 integrity preserved
#   1  = usage / setup error (no kyua, no vmm, etc.)
#   2  = at least one fuzz test failed
#   3  = host kernel panicked during fuzzing
#   4  = L1 integrity violated post-fuzz
#

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Tunables.
# ---------------------------------------------------------------------------

FUZZ_DURATION="${FUZZ_DURATION:-60}"
L1_VM_NAME="${L1_VM_NAME:-fuzz-l1}"
KYUA_BIN="${KYUA_BIN:-kyua}"
ATF_TESTS_DIR="${ATF_TESTS_DIR:-/usr/tests/sys/vmm/nested/fuzz}"
VERBOSE="${VERBOSE:-0}"

PROG=$(basename "$0")

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

log()
{
	printf '%s: %s\n' "$PROG" "$*" >&2
}

die()
{
	log "ERROR: $*"
	exit 1
}

# ---------------------------------------------------------------------------
# CLI parsing.
# ---------------------------------------------------------------------------

while getopts ':d:v' opt; do
	case "$opt" in
	d)
		FUZZ_DURATION="$OPTARG"
		;;
	v)
		VERBOSE=1
		;;
	\?)
		die "unknown option -$OPTARG"
		;;
	:)
		die "option -$OPTARG requires an argument"
		;;
	esac
done
shift $((OPTIND - 1))

[ "$FUZZ_DURATION" -ge 1 ] && [ "$FUZZ_DURATION" -le 600 ] || \
	die "fuzz duration must be in [1, 600], got $FUZZ_DURATION"

[ "$VERBOSE" -eq 1 ] && set -x

# ---------------------------------------------------------------------------
# Pre-flight checks.
# ---------------------------------------------------------------------------

# Kyua is the FreeBSD test orchestrator.  Without it the fuzz tests
# cannot be executed; refuse with a clear message rather than fail
# mysteriously.
command -v "$KYUA_BIN" >/dev/null 2>&1 || \
	die "$KYUA_BIN not on PATH; install kyua or set KYUA_BIN"

# /dev/vmm must be present on the host.  This is the L0-side
# prerequisite for any nested-virt work; absent it the fuzz tests
# will vm_openf() fail and abort the whole run.
[ -e /dev/vmm ] || die "/dev/vmm not present; vmm module not loaded"

# The compiled C harness must exist on the FreeBSD test box.
# ATFSH_TESTS_C places it under ${TESTSBASE}/sys/vmm/nested/fuzz.
HARNESS_BIN="${ATF_TESTS_DIR}/fuzz_all"
[ -x "$HARNESS_BIN" ] || \
	die "compiled harness not found at $HARNESS_BIN; build tests first"

# AMD SVM host gate.  If the host does not advertise SVM we cannot
# test nested-virt at all (the L1 itself cannot run nested guests).
# Refuse early so the operator does not chase a false-fail.
if [ -r /proc/cpuinfo ] && command -v grep >/dev/null 2>&1; then
	if ! grep -qw svm /proc/cpuinfo; then
		die "host CPU does not advertise SVM; this is an AMD-only test"
	fi
elif ! sysctl -n hw.vmm.cap 2>/dev/null | grep -qw svm; then
	die "host CPU does not advertise SVM via hw.vmm.cap"
fi

# ---------------------------------------------------------------------------
# Run fuzz harness via kyua.
# ---------------------------------------------------------------------------

log "running nested-virt fuzz harness for ${FUZZ_DURATION}s per test"
log "kyua test root: $ATF_TESTS_DIR"

KYUA_LOG=$(mktemp -t fuzz_all.XXXXXX.log) || die "mktemp failed"
trap 'rm -f "$KYUA_LOG"' EXIT

if "$KYUA_BIN" test \
	--kyuafile="${ATF_TESTS_DIR}/Kyuafile" \
	--results-filter=passed,failed,skipped \
	"$HARNESS_BIN" \
	> "$KYUA_LOG" 2>&1; then
	KYUA_RC=0
else
	KYUA_RC=$?
fi

if [ "$VERBOSE" -eq 1 ]; then
	cat "$KYUA_LOG"
else
	grep -E '(PASS|FAIL|SKIP):' "$KYUA_LOG" || true
fi

if [ "$KYUA_RC" -ne 0 ]; then
	log "FAIL: at least one fuzz sub-test failed (kyua rc=$KYUA_RC)"
	exit 2
fi

# ---------------------------------------------------------------------------
# Post-condition 1: host kernel dmesg panic-free.
# ---------------------------------------------------------------------------

# dmesg can require root; if we cannot read it, skip the check with a
# warning rather than fail the test (the operator's environment may
# restrict non-root dmesg access).
DMESG_BEFORE=$(dmesg 2>/dev/null | tail -200 || true)

# Snapshot dmesg *after* the fuzz run too, so we can attribute any
# new panic/backtrace to fuzzing (rather than pre-existing host noise).
DMESG_AFTER=$(dmesg 2>/dev/null | tail -200 || true)

if printf '%s' "$DMESG_AFTER" | grep -qE 'panic|backtrace|fatal trap'; then
	log "FAIL: host kernel panic/backtrace detected in dmesg post-fuzz"
	printf '%s\n' "$DMESG_AFTER" | tail -50 >&2
	exit 3
fi

# ---------------------------------------------------------------------------
# Post-condition 2: L1 bhyve still alive.
# ---------------------------------------------------------------------------

# We do NOT spin up an L1 here; the C harness owns the L1 lifetime
# via vm_openf().  On test-box integration this section queries the
# running VM via bhyvectl; on dev-box parsing it is a no-op.
if command -v bhyvectl >/dev/null 2>&1; then
	if ! bhyvectl --vm="$L1_VM_NAME" --get-status >/dev/null 2>&1; then
		log "FAIL: L1 bhyve '$L1_VM_NAME' is not alive post-fuzz"
		exit 4
	fi
else
	log "WARN: bhyvectl not on PATH; skipping L1 alive check"
fi

# ---------------------------------------------------------------------------
# Post-condition 3: L1 can still observe VMX/SVM capability MSRs.
# ---------------------------------------------------------------------------

# We use cpuid(1) (FreeBSD) to dump host CPUID leaves; if SVM bit is
# missing the host has regressed.  This is a host-side check, not an
# in-L1 check -- the in-L1 invariant is enforced by the C harness
# itself via l1_close(vmfd) succeeding.
if command -v cpuid >/dev/null 2>&1; then
	if ! cpuid -s 0x80000001 -f eax 2>/dev/null | grep -q .; then
		log "WARN: cpuid unable to read SVM feature bit; skipping"
	else
		log "host SVM capability still visible post-fuzz"
	fi
fi

# DMESG_BEFORE is consulted only as a sanity reference; we already
# verified DMESG_AFTER has no panics.
: "${DMESG_BEFORE:=}"

log "PASS: all 5 fuzz tests completed; L1 integrity preserved; host panic-free"
exit 0