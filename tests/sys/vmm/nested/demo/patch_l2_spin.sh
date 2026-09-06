#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Give the INNER guest a compute-bound stretch.
#
# The nested demo is dominated by EPT violations: the inner guest exits
# constantly while faulting its pages in, so it never executes long enough for
# the VMX-preemption timer to reach zero. Measuring whether that timer bounds
# L2's slice needs an L2 that runs without exiting -- a pure shell arithmetic
# loop, touching no new pages and doing no I/O.
#
# The loop must run in L2, not L1. The two are different rc.local files: L1's
# lives in the demo image and boots L2; L2's lives in /nesteddemo/l2.raw INSIDE
# that image, and is where the NESTED_DEMO_L2_OK marker is printed. Patching
# the outer one would have measured L1, which is not bounded by this timer at
# all.
#
# Off unless asked for, through the kernel environment, so an image carrying
# this behaves exactly as before for every existing run.
set -eu
IMG=${1:-/usr/local/share/cloudbsd-demo/auto/nested-demo.raw}
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }

MNT1=$(mktemp -d /tmp/l1.XXXXXX); MNT2=$(mktemp -d /tmp/l2.XXXXXX)
MD1=""; MD2=""
cleanup() {
	umount "$MNT2" 2>/dev/null || true
	if [ -n "$MD2" ]; then
		mdconfig -d -u "${MD2#md}" 2>/dev/null ||
		    echo "warning: could not detach ${MD2}" >&2
	fi
	umount "$MNT1" 2>/dev/null || true
	if [ -n "$MD1" ]; then
		mdconfig -d -u "${MD1#md}" 2>/dev/null ||
		    echo "warning: could not detach ${MD1}" >&2
	fi
	rmdir "$MNT2" "$MNT1" 2>/dev/null || true
	# Never let cleanup decide the exit status.
	:
}
trap cleanup EXIT INT TERM

MD1=$(mdconfig -a -t vnode -f "$IMG")
mount "/dev/${MD1}p1" "$MNT1"
[ -f "$MNT1/nesteddemo/l2.raw" ] || { echo "no inner image in $IMG" >&2; exit 1; }
MD2=$(mdconfig -a -t vnode -f "$MNT1/nesteddemo/l2.raw")
mount "/dev/${MD2}p1" "$MNT2"

RC="$MNT2/etc/rc.local"
[ -f "$RC" ] || { echo "inner image has no /etc/rc.local" >&2; exit 1; }
grep -q NESTED_DEMO_L2_OK "$RC" || { echo "this is not the inner guest's rc.local" >&2; exit 1; }

if grep -q nested_demo_l2_spin "$RC"; then
	echo "already patched: inner guest of $IMG"
	exit 0
fi
cp -p "$RC" "$RC.pre-spin"

# Before the marker. The driver stops capturing the console once the marker
# appears, so a spin printed after it is invisible even when it runs -- which
# reads as "the workload made no difference" rather than "look further up".
awk '
/NESTED_DEMO_L2_OK/ && !done {
	print "# Optional compute-bound stretch, off unless the host asks for it."
	print "SPIN=$(kenv -q nested_demo_l2_spin 2>/dev/null || echo 0)"
	print "case \"$SPIN\" in \x27\x27|*[!0-9]*) SPIN=0 ;; esac"
	print "if [ \"$SPIN\" -gt 0 ]; then"
	print "  echo \"L2: spinning ${SPIN}s (no I/O, no new pages)\""
	print "  _end=$(( $(date +%s) + SPIN ))"
	print "  while [ $(date +%s) -lt $_end ]; do"
	print "    _i=0; while [ $_i -lt 20000 ]; do _i=$((_i+1)); done"
	print "  done"
	print "  echo \"L2: spin done\""
	print "fi"
	print
	done = 1
	next
}
{ print }
' "$RC" > "$RC.new"

fail() { echo "$1" >&2; rm -f "$RC.new"; exit 1; }
sh -n "$RC.new" || fail "patched rc.local does not parse; not installing"
grep -q nested_demo_l2_spin "$RC.new" || fail "spin block not inserted"
grep -q NESTED_DEMO_L2_OK "$RC.new" || fail "marker lost; not installing"
mv "$RC.new" "$RC"
chmod 755 "$RC"
echo "patched inner guest of: $IMG"
