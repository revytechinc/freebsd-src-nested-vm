#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# nested_l2_inguest.sh -- run INSIDE a release image, to prove it can host a
# nested guest.
#
# verify_media_nested.sh boots a release artifact as L1 and drives its console
# to run this script.  Everything here therefore runs one level down, and the
# only channel back to the harness is what it prints on the console: the
# marker below is the entire verdict.
#
# It deliberately does not report success for anything short of an inner guest
# reaching multi-user.  Checking that hw.vmm.nested.enable exists proves the
# sysctl exists -- the same class of proxy that let four releases ship a bhyve
# that could not start a VM.

set -u

MARKER=NV_L2_BOOTED_OK
FIXTURE=${FIXTURE:-/usr/tests/sys/vmm/nested/fixtures/l2_freebsd.img}
L2NAME=inguest$$
L2LOG=/tmp/${L2NAME}.log
# The inner guest is mfsBSD and reaches a login prompt quickly; if it has not
# by this point it is not going to.
L2_TIMEOUT=${L2_TIMEOUT:-600}

say() { printf 'inguest: %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { say "need root"; exit 1; }

if ! kldstat -q -m vmm; then
	kldload vmm 2>/dev/null || { say "vmm will not load here"; exit 1; }
fi

# Report what this image actually offers, so a failure below can be read.
say "host: $(uname -v | cut -c1-60)"
say "nested sysctl: $(sysctl -n hw.vmm.nested.enable 2>/dev/null || echo absent)"

[ -f "$FIXTURE" ] || {
	say "no L2 fixture at $FIXTURE"
	say "build one with build_l2_image.sh and place it there"
	exit 1
}

WORK=/tmp/${L2NAME}.img
cp "$FIXTURE" "$WORK" || { say "cannot stage the fixture"; exit 1; }

say "booting the inner guest"
# Console to a file rather than a second nmdm: this is already running on a
# serial console driven by the harness, and opening another reader here is how
# console output gets silently swallowed.
bhyve -c 2 -m 1G -A -H -P \
	-s 0,hostbridge \
	-s 2,virtio-blk,"$WORK" \
	-s 31,lpc \
	-l com1,stdio \
	"$L2NAME" > "$L2LOG" 2>&1 &
L2PID=$!

end=$(( $(date +%s) + L2_TIMEOUT ))
ok=0
while [ "$(date +%s)" -lt "$end" ]; do
	# mfsBSD prints a login prompt once it is multi-user; that is the
	# earliest point at which the guest has genuinely executed.
	if grep -qE "login:|Starting devd" "$L2LOG" 2>/dev/null; then
		ok=1
		break
	fi
	kill -0 "$L2PID" 2>/dev/null || break
	sleep 3
done

bhyvectl --vm="$L2NAME" --destroy >/dev/null 2>&1
kill "$L2PID" 2>/dev/null
rm -f "$WORK"

if [ "$ok" = "1" ]; then
	# The harness greps for exactly this.  Printed last, and only here.
	say "inner guest reached multi-user"
	echo "$MARKER"
	exit 0
fi

say "inner guest did not reach multi-user; last console lines:"
tail -20 "$L2LOG" 2>/dev/null
exit 1
