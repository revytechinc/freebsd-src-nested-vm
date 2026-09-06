#!/bin/sh
#
# Find how wide a nested guest can get on this machine before it stops working.
#
# Runs the automatic demo at 1 vCPU, then 2, then 3, and so on up to every core
# this host has, and records what happened at each width. The interesting
# output is not "it works" -- it is the number where it stops working, and the
# way it stops.
#
# Why this is worth a script rather than a few runs by hand: a wide nested
# guest has already panicked a host outright, and a panicking host takes any
# result held only in a terminal with it. So every width is written to the log
# BEFORE the run starts and updated after it finishes. If the machine goes down
# mid-sweep, the last line of the log names the width that took it down, which
# is the single most useful fact the sweep can produce.
#
# Resuming after that reboot is the normal case, not an edge case:
#
#     sh 4-find-the-core-ceiling.sh          start (or continue) the sweep
#     sh 4-find-the-core-ceiling.sh -r       re-run widths already recorded
#     sh 4-find-the-core-ceiling.sh -m 8     stop at 8 vCPUs
#     sh 4-find-the-core-ceiling.sh -s 4     1, 5, 9, ... instead of 1, 2, 3
#
# On resume, a width left mid-run is recorded as HOST-PANIC and the sweep
# stops there rather than trying it again. Knowing a width brings the machine
# down is the answer; proving it twice is just another reboot.
#
set -u

DEMO=/usr/local/libexec/cloudbsd-demo/run-auto-demo
HOST=$(hostname -s)
LOG=${LOG:-$HOME/nested-demo/core-ceiling-${HOST}.log}
STEP=1
MAX=$(sysctl -n hw.ncpu)
REDO=0
# Two failures in a row is a ceiling, not a fluke. Past that the sweep is only
# repeating a known answer at several minutes a go.
GIVEUP=2

while [ $# -gt 0 ]; do
	case "$1" in
	-s)	[ $# -ge 2 ] || { echo "-s needs a value" >&2; exit 1; }
		STEP=$2; shift ;;
	-m)	[ $# -ge 2 ] || { echo "-m needs a value" >&2; exit 1; }
		MAX=$2; shift ;;
	-r)	REDO=1 ;;
	-h|--help)
		sed -n '2,30p' "$0"; exit 0 ;;
	*)	echo "usage: $0 [-s step] [-m max] [-r]" >&2; exit 1 ;;
	esac
	shift
done

case "$STEP" in ''|*[!0-9]*) echo "-s takes a positive number" >&2; exit 1 ;; esac
case "$MAX"  in ''|*[!0-9]*) echo "-m takes a positive number" >&2; exit 1 ;; esac
[ "$STEP" -ge 1 ] || { echo "-s must be at least 1" >&2; exit 1; }
[ "$MAX" -ge 1 ] || { echo "-m must be at least 1" >&2; exit 1; }

NCPU=$(sysctl -n hw.ncpu)
[ "$MAX" -le "$NCPU" ] || MAX=$NCPU

if ! sysctl -n hw.vmm.nested.enable >/dev/null 2>&1; then
	echo "this kernel has no nested-virt support; nothing to sweep."
	echo "run 0-what-can-this-host-do.sh to see what this machine is."
	exit 1
fi
[ -x "$DEMO" ] || { echo "missing $DEMO -- re-run the installer" >&2; exit 1; }

mkdir -p "$(dirname "$LOG")"
: >> "$LOG"

# Rewrite one record's result and duration.  Done field-wise through awk into a
# temporary file rather than with an in-place regex: the log is the only thing
# that survives a host going down, so an edit that silently matches the wrong
# line, or none, would corrupt the one artifact worth having.
mark_result() {
	_mr_v=$1; _mr_res=$2; _mr_secs=$3
	awk -v host="$HOST" -v sha="$VMMSHA" -v want="$_mr_v" \
	    -v res="$_mr_res" -v secs="$_mr_secs" '
	{
		h = ""; m = ""; v = ""; r = ""
		for (i = 1; i <= NF; i++) {
			split($i, kv, "=")
			if (kv[1] == "host")   h = kv[2]
			if (kv[1] == "vmm")    m = kv[2]
			if (kv[1] == "vcpus")  v = kv[2]
			if (kv[1] == "result") r = kv[2]
		}
		if (h == host && m == sha && v == want && r == "RUNNING") {
			for (i = 1; i <= NF; i++) {
				split($i, kv, "=")
				if (kv[1] == "result") $i = "result=" res
				if (kv[1] == "secs")   $i = "secs=" secs
			}
		}
		print
	}' "$LOG" > "$LOG.new" && mv "$LOG.new" "$LOG"
}

MODEL=$(sysctl -n hw.model)
VMMSHA=$(sha256 -q /boot/kernel/vmm.ko 2>/dev/null | cut -c1-16)
[ -n "$VMMSHA" ] || VMMSHA=unknown

# A width left in RUNNING is a width the machine did not survive.  Scope the
# search to this host AND this vmm.ko: a leftover RUNNING line from an earlier
# build says nothing about this one, and letting it stand in would report a
# ceiling for a build that was never measured at that width.
DANGLING=$(awk -v host="$HOST" -v sha="$VMMSHA" '
	{
		h = ""; m = ""; v = ""; r = ""
		for (i = 1; i <= NF; i++) {
			split($i, kv, "=")
			if (kv[1] == "host")   h = kv[2]
			if (kv[1] == "vmm")    m = kv[2]
			if (kv[1] == "vcpus")  v = kv[2]
			if (kv[1] == "result") r = kv[2]
		}
		if (h == host && m == sha && r == "RUNNING") last = v
	}
	END { if (last != "") print last }' "$LOG" 2>/dev/null)
if [ -n "$DANGLING" ]; then
	mark_result "$DANGLING" HOST-PANIC 0
	echo
	echo "This host did not survive its last run at ${DANGLING} vCPUs."
	echo "Recorded as HOST-PANIC. That is the ceiling; the sweep stops here."
	echo "Look in /var/log/messages for the panic, and see $LOG."
	echo
	exit 0
fi

echo "host   : ${HOST}  (${MODEL})"
echo "cores  : ${NCPU}   sweeping 1..${MAX} step ${STEP}"
echo "vmm.ko : ${VMMSHA}"
echo "log    : ${LOG}"
echo
echo "Each width boots an L1 guest that boots an L2 guest inside itself, both"
echo "at that width. Expect a few minutes per width, more as it gets wider."
echo

fails=0
n=1
while [ "$n" -le "$MAX" ]; do
	if [ "$REDO" -eq 0 ] &&
	    grep -q " vmm=${VMMSHA} vcpus=${n} result=" "$LOG" 2>/dev/null; then
		prev=$(grep " vmm=${VMMSHA} vcpus=${n} result=" "$LOG" |
		    tail -1 | sed -n 's/.*result=\([A-Z-]*\).*/\1/p')
		printf '%3d vCPU: %s (already recorded; -r to redo)\n' "$n" "$prev"
		[ "$prev" = PASS ] && fails=0 || fails=$((fails + 1))
	else
		printf '%3d vCPU: running... ' "$n"
		stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
		# Written before the run, so a host that dies mid-run leaves
		# this line behind naming the width that killed it.
		printf '%s host=%s vmm=%s vcpus=%d result=RUNNING secs=0\n' \
		    "$stamp" "$HOST" "$VMMSHA" "$n" >> "$LOG"
		t0=$(date +%s)
		out="$HOME/nested-demo/.ceiling-run-${n}.out"
		if doas "$DEMO" -c "$n" > "$out" 2>&1; then
			res=PASS
		elif grep -q 'invalid guest state' "$out" 2>/dev/null; then
			res=FAIL-VMENTRY
		elif grep -q 'result: timeout' "$out" 2>/dev/null; then
			res=FAIL-TIMEOUT
		else
			res=FAIL
		fi
		t1=$(date +%s)
		mark_result "$n" "$res" "$((t1 - t0))"
		printf '%s  (%ds)\n' "$res" "$((t1 - t0))"
		[ "$res" = PASS ] && fails=0 || fails=$((fails + 1))
	fi

	if [ "$fails" -ge "$GIVEUP" ]; then
		echo
		echo "Stopped: ${fails} widths in a row failed. The ceiling on this"
		echo "host is below ${n} vCPUs; the log has the exact shape of it."
		break
	fi
	n=$((n + STEP))
done

echo
echo "------------------------------------------------------------------"
echo " ${HOST} -- nested guest width, against vmm.ko ${VMMSHA}"
echo "------------------------------------------------------------------"
awk -v sha="$VMMSHA" '$0 ~ "vmm=" sha {
	for (i = 1; i <= NF; i++) {
		if ($i ~ /^vcpus=/)  { split($i, a, "="); v = a[2] }
		if ($i ~ /^result=/) { split($i, b, "="); r = b[2] }
		if ($i ~ /^secs=/)   { split($i, c, "="); s = c[2] }
	}
	printf "  %3d vCPU  %-14s %5ds\n", v, r, s
}' "$LOG"
echo "------------------------------------------------------------------"
echo "full log: $LOG"
