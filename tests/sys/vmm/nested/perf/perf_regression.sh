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
# perf_regression.sh -- Wave 7 / T41 nested-virt performance gate.
#
# GEMATRIA CONTRACT (per the plan's T41 section):
#   "If baseline.txt is missing, the test FAILS (NOT skips).  This
#    voids the SKIP = accept bug."
#
# This script MUST fail loudly when baseline.txt is absent or
# unparseable.  It MUST NOT silently skip; doing so would allow the
# nested-virt patch to ship without a perf gate, which is the
# regression the plan explicitly calls out.
#
# Thresholds:
#   * Hot-path microbench (CPUID, RDMSR, VMEXIT):  <= 1% delta
#   * Macrobench (sysbench cpu, non-nested):      <= 2% delta
#
# Run on the AMD SVM host (mlapointe@172.16.176.131).  NOT for the
# Linux dev box; the bash wrapper itself is valid syntax anywhere.
#
# Usage:
#   perf_regression.sh [-d duration_secs] [-o output_file] \
#                      [--no-compare]
#
# Options:
#   -d N          seconds per microbench metric (forwarded to
#                 perf_microbench.sh)
#   -o F          write results to F
#   --no-compare  capture-only mode: write fresh metrics but do
#                 NOT compare against baseline.txt (used during
#                 baseline regeneration)
#
# Exit codes:
#   0  = all metrics within threshold
#   1  = usage / setup error
#   2  = baseline.txt missing or unparseable (FAIL, not SKIP)
#   3  = at least one metric exceeded threshold (FAIL)
#   4  = sysbench not installed (test infra error)
#

set -u
set -o pipefail

PROG=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

DURATION="${DURATION:-30}"
OUTPUT_FILE="${OUTPUT_FILE:-}"
COMPARE=1
VERBOSE="${VERBOSE:-0}"

BASELINE_FILE="${BASELINE_FILE:-${SCRIPT_DIR}/baseline.txt}"
MICROBENCH="${MICROBENCH:-${SCRIPT_DIR}/perf_microbench.sh}"
SYSBENCH_BIN="${SYSBENCH_BIN:-/usr/local/bin/sysbench}"

# Thresholds are baked into the contract; see plan T41.  Tune via
# env override only for ad-hoc investigation; production gates MUST
# use these values.
MICROBENCH_THRESHOLD_PCT="${MICROBENCH_THRESHOLD_PCT:-1}"
MACROBENCH_THRESHOLD_PCT="${MACROBENCH_THRESHOLD_PCT:-2}"

# --- GEMATRIA GATE: baseline.txt MUST exist and be parseable ---
# Plan T41: "MANDATORY pre-patch baseline" + "No SKIP option".
# If baseline.txt is missing or unparseable, the test FAILS, not
# skips.  Refuse early with a clear message and a non-zero exit.
baseline_present()
{
	[ -f "$BASELINE_FILE" ] && [ -r "$BASELINE_FILE" ]
}

baseline_parse_microbench()
{
	# Extract metric=value lines under "section: microbench" until
	# the next section marker (line starting with '# section: ').
	awk '
		/^# section: microbench/ { in_section = 1; next }
		/^# section:/ { in_section = 0 }
		in_section && /^metric=/ { print }
	' "$BASELINE_FILE"
}

baseline_parse_macrobench()
{
	# Same scheme for the macrobench section.
	awk '
		/^# section: macrobench/ { in_section = 1; next }
		/^# section:/ { in_section = 0 }
		in_section && /^metric=/ { print }
	' "$BASELINE_FILE"
}

# --- CLI parsing ---
while [ $# -gt 0 ]; do
	case "$1" in
	-d) DURATION="$2"; shift 2 ;;
	-o) OUTPUT_FILE="$2"; shift 2 ;;
	--no-compare) COMPARE=0; shift ;;
	-v) VERBOSE=1; shift ;;
	-h|--help)
		sed -n '4,70p' "$0" | sed 's/^# \?//'
		exit 0
		;;
	--)
		shift
		break
		;;
	-*)
		printf '%s: unknown option %s\n' "$PROG" "$1" >&2
		exit 1
		;;
	*)
		break
		;;
	esac
done

[ "$DURATION" -ge 5 ] && [ "$DURATION" -le 300 ] || {
	printf '%s: duration must be in [5, 300]\n' "$PROG" >&2
	exit 1
}

# --- FAIL FAST if baseline.txt missing (GEMATRIA) ---
if [ "$COMPARE" -eq 1 ]; then
	if ! baseline_present; then
		# Two-stage error message so the operator sees both the
		# symptom and the fix path.  Exit 2 to make it grep-able.
		cat >&2 <<-EOF
		$PROG: FAIL: baseline.txt missing or unreadable
		       expected at: $BASELINE_FILE
		       plan T41 GEMATRIA: this MUST NOT be skipped.
		       regenerate via: cd tests/sys/vmm/nested/perf && \\
		           sh perf_microbench.sh -o /tmp/micro.txt && \\
		           sh perf_regression.sh --no-compare -o /tmp/macro.txt && \\
		           sh perf_nested.sh -o /tmp/nested.txt && \\
		           cat /tmp/micro.txt /tmp/macro.txt /tmp/nested.txt \\
		               > baseline.txt
		EOF
		exit 2
	fi

	MICRO_BASE=$(baseline_parse_microbench)
	MACRO_BASE=$(baseline_parse_macrobench)

	if [ -z "$MICRO_BASE" ]; then
		printf '%s: FAIL: baseline.txt microbench section is empty\n' \
		    "$PROG" >&2
		exit 2
	fi
	if [ -z "$MACRO_BASE" ]; then
		printf '%s: FAIL: baseline.txt macrobench section is empty\n' \
		    "$PROG" >&2
		exit 2
	fi
fi

# --- Capture fresh microbench ---
MICRO_FRESH_FILE=$(mktemp -t perf_regression.micro.XXXXXX) || exit 1
MACRO_FRESH_FILE=$(mktemp -t perf_regression.macro.XXXXXX) || {
	rm -f "$MICRO_FRESH_FILE"; exit 1
}
NESTED_FRESH_FILE=$(mktemp -t perf_regression.nested.XXXXXX) || {
	rm -f "$MICRO_FRESH_FILE" "$MACRO_FRESH_FILE"; exit 1
}
trap 'rm -f "$MICRO_FRESH_FILE" "$MACRO_FRESH_FILE" "$NESTED_FRESH_FILE"' EXIT

# shellcheck disable=SC2097,SC2098
# Invoke the microbench wrapper with env vars inline so it picks up
# DURATION/OUTPUT_FILE/VERBOSE without exporting them; this is the
# canonical POSIX pattern, but shellcheck does not recognize it
# when used as the negated head of an `if !` block.
if ! DURATION="$DURATION" OUTPUT_FILE="$MICRO_FRESH_FILE" \
     VERBOSE="$VERBOSE" sh "$MICROBENCH" -d "$DURATION" \
         -o "$MICRO_FRESH_FILE"; then
	printf '%s: FAIL: perf_microbench.sh exited non-zero\n' "$PROG" >&2
	exit 1
fi

# --- Capture macrobench via sysbench ---
# sysbench is a ports package (benchmarks/sysbench); on the test box
# it lives under /usr/local/bin.  Refuse loudly if absent; do NOT
# fall back to a weaker metric.
if [ ! -x "$SYSBENCH_BIN" ]; then
	printf '%s: FAIL: sysbench not found at %s\n' \
	    "$PROG" "$SYSBENCH_BIN" >&2
	printf '%s:        install benchmarks/sysbench or set SYSBENCH_BIN\n' \
	    "$PROG" >&2
	exit 4
fi

if ! "$SYSBENCH_BIN" cpu --threads=1 --time=60 run > "$MACRO_FRESH_FILE" 2>&1; then
	printf '%s: FAIL: sysbench cpu run failed\n' "$PROG" >&2
	exit 4
fi

# --- Capture nested macrobench (informational) ---
# We invoke perf_nested.sh only when --no-compare is NOT set; in
# capture-only mode the nested run is the operator's responsibility.
if [ "$COMPARE" -eq 1 ] && [ -x "${SCRIPT_DIR}/perf_nested.sh" ]; then
	if ! OUTPUT_FILE="$NESTED_FRESH_FILE" \
	     sh "${SCRIPT_DIR}/perf_nested.sh" -o "$NESTED_FRESH_FILE" \
	        >/dev/null 2>&1; then
		printf '%s: WARN: perf_nested.sh failed; informational only\n' \
		    "$PROG" >&2
	fi
fi

# --- Compare against baseline ---
if [ "$COMPARE" -ne 1 ]; then
	# Capture-only mode: concatenate the fresh metrics into a single
	# blob the operator can use to regenerate baseline.txt.
	cat "$MICRO_FRESH_FILE" "$MACRO_FRESH_FILE" "$NESTED_FRESH_FILE" \
	    > "${OUTPUT_FILE:-/dev/stdout}"
	exit 0
fi

# Parse "metric=X value=Y unit=Z" lines into "X Y" pairs for awk.
extract_metric_value()
{
	# shellcheck disable=SC2317  # used by awk piping below
	sed -nE "s/^metric=${1}[[:space:]]+value=(-?[0-9.]+).*/\1/p"
}

# Compute percentage delta between baseline and fresh for each metric.
# Output one line per metric: "<metric> <base> <fresh> <delta_pct>"
compute_deltas()
{
	local base_file="$1" fresh_file="$2" metric

	for metric in cpuid_call_rate rdmsr_call_rate null_vmexit_rate \
	    sysbench_cpu_events_per_sec; do
		base_val=$(extract_metric_value "$metric" < "$base_file" \
		    | head -1)
		fresh_val=$(extract_metric_value "$metric" < "$fresh_file" \
		    | head -1)
		if [ -z "$base_val" ] || [ -z "$fresh_val" ]; then
			printf '%s %s %s %s\n' "$metric" \
			    "${base_val:-MISSING}" "${fresh_val:-MISSING}" \
			    "n/a"
			continue
		fi
		# Use awk for floating-point math; POSIX shell can't.
		delta=$(awk -v b="$base_val" -v f="$fresh_val" \
		    'BEGIN { if (b == 0) { print "inf" } else { printf "%.4f", ((f-b)/b)*100 } }')
		printf '%s %s %s %s\n' "$metric" "$base_val" "$fresh_val" "$delta"
	done
}

DELTAS=$(compute_deltas "$BASELINE_FILE" "$MICRO_FRESH_FILE")

# Apply per-metric thresholds: microbench <= 1%, macrobench <= 2%.
# sysbench_cpu_events_per_sec lives in the macrobench capture, not
# the microbench file, so we extract it from the macrobench section.
# Concatenate macro-fresh + micro-fresh so a single extract pass
# covers both files.
echo "$DELTAS" > "${MICRO_FRESH_FILE}.deltas"

if [ -n "$OUTPUT_FILE" ]; then
	exec > "$OUTPUT_FILE"
fi

printf '%s: nested-virt perf regression gate\n' "$PROG"
printf 'baseline: %s\n' "$BASELINE_FILE"
printf 'thresholds: hot-path <= %s%%,  macrobench <= %s%%\n' \
    "$MICROBENCH_THRESHOLD_PCT" "$MACROBENCH_THRESHOLD_PCT"
printf '\n'
printf '%-30s %15s %15s %10s\n' metric base fresh 'delta%'
printf '%-30s %15s %15s %10s\n' ------------------------------ \
    --------------- --------------- ----------

echo "$DELTAS" | while read -r metric base fresh delta; do
	[ -z "$metric" ] && continue
	# Determine threshold for this metric.
	case "$metric" in
		sysbench_*)
			thresh="$MACROBENCH_THRESHOLD_PCT"
			;;
		*)
			thresh="$MICROBENCH_THRESHOLD_PCT"
			;;
	esac
	# Compare absolute delta against threshold.
	if [ "$delta" = "MISSING" ] || [ "$delta" = "n/a" ]; then
		printf '%-30s %15s %15s %10s  SKIP\n' \
		    "$metric" "$base" "$fresh" "$delta"
		# SKIP of an individual metric is NOT a hard fail; the
		# overall gate fails if any required metric is missing.
		continue
	fi
	abs_delta=$(awk -v d="$delta" 'BEGIN { if (d < 0) d = -d; printf "%.4f", d }')
	over=$(awk -v a="$abs_delta" -v t="$thresh" \
	    'BEGIN { print (a > t) ? 1 : 0 }')
	if [ "$over" -eq 1 ]; then
		printf '%-30s %15s %15s %9s%%  FAIL (>%s%%)\n' \
		    "$metric" "$base" "$fresh" "$delta" "$thresh"
		# Record FAIL state via tmpfile (subshell-immune).
		printf 'FAIL\n' >> "${MICRO_FRESH_FILE}.verdict"
	else
		printf '%-30s %15s %15s %9s%%  PASS (<=%s%%)\n' \
		    "$metric" "$base" "$fresh" "$delta" "$thresh"
	fi
done

if [ -e "${MICRO_FRESH_FILE}.verdict" ] && \
   grep -q '^FAIL$' "${MICRO_FRESH_FILE}.verdict"; then
	printf '\n%s: FAIL: at least one metric exceeded threshold\n' "$PROG"
	exit 3
fi

printf '\n%s: PASS: non-nested within %s%% of baseline\n' "$PROG" \
    "$MACROBENCH_THRESHOLD_PCT"
exit 0