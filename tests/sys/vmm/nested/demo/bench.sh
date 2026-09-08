#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# One benchmark, run identically at every layer, so the numbers compare. A
# figure from the inner guest means nothing without the same figure from bare
# metal, taken the same way.
#
# Deliberately primitive: it has to run inside a 1 GB nested guest with a 1.4 GB
# disk, no packages and no ports. Only /bin/sh, dd and date.
#
#     sh bench.sh L0-AMD
#     sh bench.sh L2
#
set -u
LAYER=${1:-unknown}
DIR=${BENCHDIR:-/tmp}
SRC="$DIR/.bench-src.$$"
DST="$DIR/.bench-dst.$$"

# Sized for the smallest guest disk, repeated so a whole-second clock can
# resolve the result. Timing a single pass here would be quantised to about
# twenty percent, which is how an earlier attempt produced ten identical
# readings that looked like a clean null result.
MB=${MB:-128}
REPS=${REPS:-8}
WORK=${WORK:-2000000}
CPU_REPS=${CPU_REPS:-5}

cleanup() { rm -f "$SRC" "$DST"; }
trap cleanup EXIT INT TERM

# --- cpu ------------------------------------------------------------------
# A shell arithmetic loop. It measures the interpreter as much as the
# processor, which is fine: the comparison is the same interpreter at every
# layer, and what is being asked is what nesting costs, not what the CPU can do.
t0=$(date +%s)
r=0
while [ "$r" -lt "$CPU_REPS" ]; do
	i=0
	while [ "$i" -lt "$WORK" ]; do i=$((i + 1)); done
	r=$((r + 1))
done
cpu=$(( $(date +%s) - t0 ))
[ "$cpu" -gt 0 ] || cpu=1

# --- disk -----------------------------------------------------------------
# INCOMPRESSIBLE data. The pool has compression on, so dd from /dev/zero writes
# almost nothing and reports double the real throughput. Generate the source
# once, outside the timed section, then write that.
dd if=/dev/random of="$SRC" bs=1m count="$MB" 2>/dev/null

# sync INSIDE the loop, not once at the end. A host with far more RAM than the
# working set absorbs a gigabyte of writes into the cache and returns
# immediately, so a single trailing sync times the cache and reports a write
# that never reached a disk -- which is what "write faster than the clock can
# measure" meant on the first two attempts at this.
# Repeat the whole write measurement and report the spread, because ONE disk
# figure from this benchmark is not trustworthy on its own. On consumer NVMe the
# first writes land in the drive's fast SLC cache and later ones fall back to
# native speed, so the same 8GB write on one idle host measured 16s, 47s and
# 190s in consecutive runs -- a 12x spread that is the drive's cache state, not
# its throughput. Reporting a median with its range makes that visible instead
# of presenting whichever reading came first as the answer.
DISK_REPS=${DISK_REPS:-3}
wr_list=""
dr=0
while [ "$dr" -lt "$DISK_REPS" ]; do
t0=$(date +%s)
r=0
while [ "$r" -lt "$REPS" ]; do
	# conv=fsync flushes THIS file at the end of THIS dd. A bare sync()
	# afterwards commits whatever the pool happens to have queued, so the
	# figure depended on where in the ZFS transaction-group cycle the loop
	# landed -- which produced a 20x spread across readings on an idle host
	# (54, 630, 66, 33, 77 MB/s on the same machine) and made the disk arm
	# unusable for detecting a regression.
	dd if="$SRC" of="$DST" bs=1m conv=fsync 2>/dev/null
	r=$((r + 1))
done
wr=$(( $(date +%s) - t0 ))
	[ "$wr" -le 0 ] && wr=1
	wr_list="$wr_list $(( (MB * REPS) / wr ))"
	dr=$((dr + 1))
done
# median of the sorted readings, plus the extremes
wr_sorted=$(echo $wr_list | tr " " "\n" | grep -v "^$" | sort -n)
# Middle reading of an odd count; for an even count this takes the upper of
# the two middles, which is fine -- the range beside it is what carries the
# uncertainty, not a precise median.
wmb_med=$(echo "$wr_sorted" | head -n $(( (DISK_REPS + 1) / 2 )) | tail -n 1)
wmb_min=$(echo "$wr_sorted" | head -n 1)
wmb_max=$(echo "$wr_sorted" | tail -n 1)

t0=$(date +%s)
r=0
while [ "$r" -lt "$REPS" ]; do
	dd if="$DST" of=/dev/null bs=1m 2>/dev/null
	r=$((r + 1))
done
rd=$(( $(date +%s) - t0 ))

# ---- network -----------------------------------------------------------
# bhyve's virtio-net backend is on the path this project touched, so a guest's
# network throughput is in scope for a regression even though vmm.ko does not
# touch TCP. Measured against a sink the caller names; without one it is
# reported as not measured rather than guessed at, because a plausible number
# for an unmeasured thing is worse than an admitted gap.
#
#   on the sink:   nc -l 5001 > /dev/null
#   here:          NET_TARGET=<ip> NET_PORT=5001 sh bench.sh <layer>
net_MBps="-"
if [ -n "${NET_TARGET:-}" ] && command -v nc >/dev/null 2>&1; then
	NET_PORT=${NET_PORT:-5001}
	NET_MB=${NET_MB:-512}
	# SRC is only MB megabytes, so reading NET_MB from it would stop at
	# end-of-file and then divide the WRONG numerator by the time -- a
	# number roughly NET_MB/MB too high. Send exactly what exists.
	[ "$NET_MB" -gt "$MB" ] && NET_MB=$MB
	t0=$(date +%s)
	if dd if="$SRC" bs=1m count="$NET_MB" 2>/dev/null |
	    nc -w 20 "$NET_TARGET" "$NET_PORT" 2>/dev/null; then
		nt=$(( $(date +%s) - t0 ))
		[ "$nt" -le 0 ] && nt=1
		net_MBps=$(( NET_MB / nt ))
	else
		# A refused connection or a timeout must not yield a plausible
		# throughput; say it failed.
		net_MBps="failed"
	fi
fi



total=$((MB * REPS))
wmb=$([ "$wr" -gt 0 ] && echo $((total / wr)) || echo "-")
rmb=$([ "$rd" -gt 0 ] && echo $((total / rd)) || echo "-")

# read_MBps is reported but is NOT comparable across layers: a host with far
# more RAM than the working set never reaches a disk for it. Write, after sync,
# is the figure to compare.
echo "BENCH layer=$LAYER cpu_secs=$cpu cpu_iter_per_s=$(( (WORK * CPU_REPS) / cpu ))" \
     "write_MBps=$wmb_med write_range=${wmb_min}-${wmb_max} read_MBps=$rmb(cache-warm) net_MBps=$net_MBps total_MB=$(( total * DISK_REPS ))"
