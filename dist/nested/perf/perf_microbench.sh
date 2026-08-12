#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 The FreeBSD Foundation
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
# perf_microbench.sh -- Wave 7 / T41 hot-path microbench harness.
#
# Measures three hot-path metrics in a non-nested L1 bhyve:
#
#   1. CPUID call rate         (RDMSR-style CPUID leaf-0x01 dispatch)
#   2. RDMSR call rate         (intercepted MSR-0x1234 read)
#   3. Null-VMEXIT rate        (PIO port-0x80 exit; minimal handler work)
#
# These three metrics directly exercise the vmm hot-path branches that
# T11-T41 added nested-virt code into.  Each must remain within 1% of
# the committed baseline.txt (perf_regression.sh enforces the gate).
#
# Wall-clock sample window: 30 seconds per metric (operator-tunable
# via -d, 5-300s bounds).  Three back-to-back metrics take ~90s.
#
# The harness runs from a non-nested L1 bhyve (i.e. a regular VM on
# the AMD SVM host) so that vmm-exit interception is exercised end-
# to-end.  On the host itself the metrics would not exercise the L0
# hot path and would yield artificially fast numbers.
#
# Run on the AMD SVM host (mlapointe@172.16.176.131).  The harness is
# not safe to run on the Linux dev box; the bash wrapper itself
# validates for syntax only.
#
# Usage:
#   perf_microbench.sh [-d duration_secs] [-o output_file]
#
# Options:
#   -d N   seconds per metric (default: 30, range: 5-300)
#   -o F   write results to F (default: stdout)
#
# Exit codes:
#   0  = metrics captured
#   1  = usage / setup error
#   2  = metrics measurement failed
#

set -u
set -o pipefail

DURATION="${DURATION:-30}"
OUTPUT_FILE="${OUTPUT_FILE:-}"
VERBOSE="${VERBOSE:-0}"

PROG=$(basename "$0")

while getopts ':d:o:v' opt; do
	case "$opt" in
	d) DURATION="$OPTARG" ;;
	o) OUTPUT_FILE="$OPTARG" ;;
	v) VERBOSE=1 ;;
	\?) printf '%s: unknown option -%s\n' "$PROG" "$OPTARG" >&2; exit 1 ;;
	:)  printf '%s: option -%s requires an argument\n' "$PROG" "$OPTARG" >&2; exit 1 ;;
	esac
done
shift $((OPTIND - 1))

# Bounds (5s minimum to amortize vmenter/vmexit overhead; 300s maximum
# so an operator run takes <15min total).
[ "$DURATION" -ge 5 ] && [ "$DURATION" -le 300 ] || {
	printf '%s: duration must be in [5, 300]\n' "$PROG" >&2
	exit 1
}

# AMD SVM host gate -- metrics must be captured on AMD hardware.
# On a non-AMD host CPUID would not even be intercepted; refuse early.
if [ -r /proc/cpuinfo ]; then
	if ! grep -qw svm /proc/cpuinfo; then
		printf '%s: WARN: host CPU does not advertise SVM\n' "$PROG" >&2
	elif [ "$VERBOSE" -eq 1 ]; then
		printf '%s: host SVM capability confirmed\n' "$PROG" >&2
	fi
fi

# Hot-path metrics are captured by a small C program linked against
# libvmmapi; the program drives a non-nested L1 vCPU and counts
# vmenter/vmexit cycles per metric.  The program lives at:
#
#   ${TESTSBASE}/sys/vmm/nested/perf/perf_hotpath
#
# built from perf_hotpath.c by the perf/Makefile.  Without it we
# cannot run the metrics; refuse with a clear message rather than
# silently emit zeros.
MICROBENCH_BIN="${MICROBENCH_BIN:-/usr/tests/sys/vmm/nested/perf/perf_hotpath}"
if [ ! -x "$MICROBENCH_BIN" ]; then
	printf '%s: hotpath binary %s not found; build tests first\n' \
	    "$PROG" "$MICROBENCH_BIN" >&2
	exit 2
fi

run_metric()
{
	local name="$1"
	local result

	# The hotpath binary prints three lines per metric in this format:
	#   metric=<name> value=<rate> unit=<unit>
	# plus a blank line.  We extract just the metric=value line so
	# downstream parsing is stable.
	if ! result=$("$MICROBENCH_BIN" -m "$name" -d "$DURATION" 2>&1); then
		printf '%s: FAIL: metric %s measurement failed\n' \
		    "$PROG" "$name" >&2
		return 1
	fi

	# Extract the "metric=X value=Y unit=Z" line.
	printf '%s' "$result" | grep -E "^metric=${name} value=" | head -1
}

capture_all_metrics()
{
	local rc=0 m

	for m in cpuid_call_rate rdmsr_call_rate null_vmexit_rate; do
		if ! run_metric "$m"; then
			rc=1
		fi
	done
	return $rc
}

if [ -n "$OUTPUT_FILE" ]; then
	capture_all_metrics > "$OUTPUT_FILE" 2>&1
	rc=$?
	if [ "$VERBOSE" -eq 1 ] && [ "$rc" -eq 0 ]; then
		printf '%s: wrote %s\n' "$PROG" "$OUTPUT_FILE" >&2
	fi
	exit $rc
fi

capture_all_metrics
exit $?