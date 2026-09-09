#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# verify_media_nested.sh -- prove a release image can host a nested guest.
#
# The verdict for a release artifact is an L2 booting inside it.  Nothing
# else is evidence: reading hw.vmm.nested.enable inside the image says the
# sysctl exists, which is the same class of proxy that let four releases ship
# a bhyve that could not start any VM at all because only vmm.ko loading was
# ever checked.
#
# This lives in the tree, and ships in the tests package, deliberately.  The
# previous version of this harness was hand-placed on the test hosts, and when
# it was needed it was not on any reachable machine -- a gate that exists only
# on a host is a gate you discover you have lost at the moment you need it.
#
# What it does:
#   1. converts the artifact to raw if bhyve cannot boot it directly
#      (bhyve boots raw disks only; qcow2/vhd/vmdk are converted first, so
#      "it boots all eight formats" is not a claim this makes)
#   2. boots it as L1 with nested virtualisation available
#   3. drives the L1 console to start an inner guest
#   4. greps the console for the marker the inner guest prints
#
# Usage:
#   verify_media_nested.sh <artifact> [workdir]
#
# Exit 0 only if the inner guest printed its marker.

set -eu

PROGRAM="${0##*/}"
ARTIFACT=${1:?usage: $PROGRAM <artifact> [workdir]}
WORKDIR=${2:-/var/tmp/verify-media}
MARKER=NV_L2_BOOTED_OK
# Printed by L1 when the in-guest script is not executable.  Running it
# through sh(1) lets this harness verify images built before that mode was
# fixed, but on its own sh ignores the execute bit, so a regression that
# shipped the script unexecutable again would pass the gate in silence.
NOTEXEC=NV_INGUEST_NOT_EXECUTABLE
# An installer ISO stops at its menu and never reaches a shell, so it needs
# the slower scripted-install path rather than this one.
BOOT_TIMEOUT=${BOOT_TIMEOUT:-900}
# Time allowed for the inner guest once L1 has a shell.
INNER_TIMEOUT=${INNER_TIMEOUT:-900}
# Forwarded to the in-guest script as its own budget. The default suits a
# modern part; the oldest machine in the fleet takes roughly ten times the
# EPT violations for the same guest, so it needs a great deal longer and a
# short budget there reports a guest that was visibly still booting as a
# failure. Raising this for slow hardware is a parameter of the run, not a
# lowered bar -- the marker still has to appear.
L2_TIMEOUT=${L2_TIMEOUT:-600}
# Matched against the console to know the shell is ready.  Kept loose because
# the prompt differs between an installed system and mfsBSD.
SHELL_PROMPT=${SHELL_PROMPT:-'[#$] $'}
# Runs inside L1.  Ships in the same tests package as this script, so media
# built from this tree already carry it -- which is the point of the harness
# living in the tree rather than being hand-placed.
INGUEST=${INGUEST:-/usr/tests/sys/vmm/nested/scripts/nested_l2_inguest.sh}
# The inner guest needs a disk to boot, and that disk is NOT shipped inside the
# release image.  It is ~150MB of mfsBSD, it cannot be produced during a
# release build (it fetches a distribution and clones a third-party
# repository), and putting it in the base tests package would put it on every
# FreeBSD installation that never runs this.  So it lives on the HOST running
# this harness and is handed to L1 as a second disk, read-only -- L1 is the
# artifact under test and must not be able to modify the fixture that the next
# machine in the matrix will use.
L2_FIXTURE=${L2_FIXTURE:-/usr/tests/sys/vmm/nested/fixtures/l2_freebsd.img}
# Where that disk appears inside L1: the artifact's own root is vtbd0, so the
# second virtio-blk device is vtbd1.
L2_FIXTURE_DEV=${L2_FIXTURE_DEV:-/dev/vtbd1}
# The hypervisor this host is actually running.  A gate that does not check
# this will happily test a release image on top of a DIFFERENT build's vmm and
# report PASS, and the verdict column reads the same either way -- which is how
# a whole seven-host round got spent against a stale kernel before anyone
# noticed.  Set EXPECT_VMM_SHA to assert it; leave it unset and the identity is
# still printed, so the result describes itself.
EXPECT_VMM_SHA=${EXPECT_VMM_SHA:-}
VMM_KO=${VMM_KO:-/boot/kernel/vmm.ko}
VMNAME="verifymedia$$"
NMDM=/dev/nmdm${VMNAME}

log() { printf '%s: %s\n' "$PROGRAM" "$*"; }
die() { log "FAIL: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "need root"
[ -f "$ARTIFACT" ] || die "no such artifact: $ARTIFACT"
kldstat -q -m vmm || die "vmm is not loaded on this host"

# Identity of the hypervisor doing the nesting, checked before anything slow.
log "host: $(hostname -s), $(sysctl -n hw.model 2>/dev/null)"
if [ ! -f "$VMM_KO" ]; then
	# kldstat succeeds whether vmm is a module or built into the kernel, so
	# it does not catch this.  Reporting "unknown" and carrying on to a PASS
	# would produce exactly the unidentified result this check exists to
	# prevent.
	log "no module at $VMM_KO -- cannot identify the hypervisor under test"
	die "UNIDENTIFIED BUILD on $(hostname -s): set VMM_KO to the module this host actually runs"
fi
HOST_VMM_SHA=$(sha256 -q "$VMM_KO")
log "L0 vmm.ko: $HOST_VMM_SHA"
if [ -n "$EXPECT_VMM_SHA" ] && [ "$HOST_VMM_SHA" != "$EXPECT_VMM_SHA" ]; then
	# One line per log entry: a round is read by scanning these, and an
	# indented continuation does not match the format everything else uses.
	log "expected:  $EXPECT_VMM_SHA"
	log "this host runs a different hypervisor from the one under test, so any"
	log "verdict from here would describe the wrong build. Deploy the expected"
	log "kernel and re-run, or unset EXPECT_VMM_SHA if this is deliberate."
	die "BUILD MISMATCH on $(hostname -s)"
fi
# nmdm is NOT loaded by default on these hosts.  Without it the reader's open
# fails instantly, the console file stays empty, and the run burns the full
# timeout before reporting "no marker" -- naming the wrong cause.
if ! kldstat -q -m nmdm; then
	kldload nmdm 2>/dev/null ||
	    die "nmdm is not loaded and could not be loaded; no console to drive"
fi

[ -f "$L2_FIXTURE" ] || die "no inner-guest disk at $L2_FIXTURE.
	This is the disk L2 boots from. It is deliberately not shipped inside
	the release image; build one with build_l2_image.sh and put it there,
	or point L2_FIXTURE at an existing one. Failing now rather than after
	copying the artifact and booting a guest that cannot pass."

mkdir -p "$WORKDIR"

cleanup() {
	[ -n "${READER_PID:-}" ] && kill "$READER_PID" 2>/dev/null || true
	bhyvectl --vm="$VMNAME" --destroy >/dev/null 2>&1 || true
	# The console is the artifact worth keeping; the multi-gigabyte working
	# copy is not.  KEEP_RAW=1 preserves it for post-mortem.
	# ${RAW:-} because the trap is installed before RAW is assigned, so an
	# early failure would otherwise trip set -u inside the cleanup itself.
	[ "${KEEP_RAW:-0}" = "1" ] || rm -f "${RAW:-}"
	[ -n "${DECOMPRESSED:-}" ] && rm -f "$DECOMPRESSED"
	return 0
}
trap cleanup EXIT INT TERM

# Unique per run: two verifications of the same artifact would otherwise race
# on one file while using distinct VM names, and multi-gigabyte copies would
# accumulate in WORKDIR for ever.
RAW="$WORKDIR/$(basename "$ARTIFACT").$$.raw"

# bhyve boots raw disks only.  Decompress and convert as needed rather than
# claiming a format is bootable when it is not.
src=$ARTIFACT
case "$src" in
*.xz)
	log "decompressing $(basename "$src")"
	# The uniqueness suffix goes BEFORE the extension. Appending it after
	# produced "...-zfs.raw.4483", which the format check immediately below
	# then rejected as an unrecognised type -- so every compressed artifact
	# failed this gate at the step after the one that created the name.
	_stem=$(basename "${src%.xz}")
	case "$_stem" in
	*.*)	DECOMPRESSED="$WORKDIR/${_stem%.*}.$$.${_stem##*.}" ;;
	*)	# No extension left after stripping .xz. Appending .$$ here would
		# recreate the very bug this fixes -- the format check below would
		# see ".4483" and reject it. There is nothing to detect a format
		# from, so say that instead of failing three steps later with a
		# message about an unrecognised type.
		die "cannot tell what format $(basename "$ARTIFACT") is:" \
		    "it has no extension once .xz is stripped" ;;
	esac
	xz -dc "$src" > "$DECOMPRESSED"
	src=$DECOMPRESSED
	;;
esac
case "$src" in
*.raw|*.img)
	cp "$src" "$RAW"
	;;
*.qcow2|*.vhd|*.vmdk)
	command -v qemu-img >/dev/null 2>&1 ||
	    die "qemu-img needed to convert $(basename "$src") to raw"
	log "converting $(basename "$src") to raw"
	qemu-img convert -O raw "$src" "$RAW"
	;;
*.iso)
	die "installer media needs the scripted-install path, not this one"
	;;
*)
	die "unrecognised artifact type: $(basename "$src")"
	;;
esac


CONSOLE=$WORKDIR/${VMNAME}.console
: > "$CONSOLE"

# nmdm rules that cost two failed runs before they were written down:
# start the reader FIRST so it captures from byte zero, allow exactly one
# reader on the B side, and set the tty raw only while that reader holds it
# open -- a lone `stty -f` is otherwise the only opener, and the last close
# resets termios and flushes the queue, silently discarding everything the
# guest printed.
# ONE open, held for the whole run, doing both jobs.
#
# The obvious shape -- a backgrounded `cat` plus a separate `stty -f` -- has a
# race that is not fixable with a delay.  Both block in open(2) until the A
# side has carrier, which only appears when bhyve opens it further down, so
# they unblock together and the order is a coin flip.  If stty wins, it sets
# termios and CLOSES, and that last close resets termios straight back to
# cooked with ECHO before the reader ever gets in.  The guest's getty then
# echoes into a line discipline fighting it, login never completes, and getty
# respawns for ever: one run produced 777 login prompts and 1.19MB of console.
#
# Holding a single descriptor removes the race rather than narrowing it. stty
# acts on that descriptor, cat reads from it, and nothing closes until the run
# is over -- so there is no last close to undo the settings.
( exec 3< "${NMDM}B" || exit 1
  stty raw -echo clocal <&3 2>/dev/null || true
  cat <&3 ) > "$CONSOLE" 2>/dev/null &
READER_PID=$!

log "inner-guest disk: $L2_FIXTURE -> $L2_FIXTURE_DEV in L1 (read-only)"
log "booting $(basename "$ARTIFACT") as L1"
bhyve -c 2 -m 4G -A -H -P \
	-s 0,hostbridge \
	-s 2,virtio-blk,"$RAW" \
	-s 3,virtio-blk,"$L2_FIXTURE",ro \
	-s 31,lpc \
	-l com1,"${NMDM}A" \
	-l bootrom,/usr/local/share/uefi-firmware/BHYVE_UEFI.fd \
	"$VMNAME" >/dev/null 2>&1 &
BHYVE_PID=$!

# Wall-clock deadline, not `kill -0` on a wrapper: doas and timeout fork away
# from the process being watched, so watching the wrapper reported every run
# as finishing in exactly one second.
# Wall-clock deadlines throughout, not `kill -0` on a wrapper: doas and
# timeout fork away from the process being watched, so watching the wrapper
# reported every run as finishing in exactly one second.
#
# wait_for <pattern> <seconds> -- returns 0 when the console shows it
wait_for() {
	_pat=$1
	_end=$(( $(date +%s) + $2 ))
	while [ "$(date +%s)" -lt "$_end" ]; do
		grep -q "$_pat" "$CONSOLE" 2>/dev/null && return 0
		kill -0 "$BHYVE_PID" 2>/dev/null || return 1
		sleep 3
	done
	return 1
}

# CR, not LF: this is a serial console, and a bare newline leaves the getty
# waiting for the rest of the line.
send() { printf '%s\r' "$1" > "${NMDM}B"; }

found=0
if ! wait_for "login:" "$BOOT_TIMEOUT"; then
	log "L1 never reached a login prompt"
else
	log "L1 is up; logging in and starting the inner guest"
	send "root"
	# A password prompt is not certain -- release media may have an empty
	# root password -- so answer it only if it appears, and do not fail if
	# it does not.
	if wait_for "Password:" 15; then
		send ""
	fi
	if wait_for "$SHELL_PROMPT" 60; then
		# The getty echoes the command line back onto the same console we
		# grep, so a marker written literally here would match its own
		# echo and report every image as broken.  Build it in the guest
		# from a variable instead: the echoed command shows ${x}_..., only
		# the output carries the whole word.  Expansion is load-bearing
		# and cannot be tidied away, where quote-splitting looks cosmetic
		# and would silently become a permanent false warning.
		send "x=NV_INGUEST; test -x $INGUEST || echo \${x}_NOT_EXECUTABLE"
		# Through sh, not directly, so images predating the mode fix can
		# still be verified.  The test above is what keeps that from
		# hiding a fresh regression.
		# Hand over the device itself.  Staging it to a file inside L1
		# first would mean the ~150MB fixture is copied twice in a 4G
		# guest -- once by us, once by the in-guest script, which copies
		# it anyway because the inner guest writes to its disk.  An
		# image built before the in-guest script learned to accept a
		# device will refuse this and say so plainly, which is the right
		# answer: that image cannot run this gate.
		send "FIXTURE=$L2_FIXTURE_DEV L2_TIMEOUT=$L2_TIMEOUT sh $INGUEST"
		wait_for "$MARKER" "$INNER_TIMEOUT" && found=1
	else
		log "no shell prompt after login"
	fi
fi

# Reported whichever way the run ends.  Inside the pass branch it would be
# lost exactly when it is most useful: on a FAIL, the wrong mode is the first
# thing worth ruling out, and it is the one clue the console tail may not show.
if grep -q "$NOTEXEC" "$CONSOLE" 2>/dev/null; then
	log "WARNING: $INGUEST is not executable inside this image."
	log "         It was run through sh, so this is not on its own a"
	log "         failure, but the image ships its tests package with the"
	log "         wrong mode and anything exec'ing that script will fail."
fi

if [ "$found" = "1" ]; then
	log "PASS: inner guest printed $MARKER"
	log "console: $CONSOLE"
	exit 0
fi

log "console tail:"
tail -30 "$CONSOLE" | sed 's/^/  /'
# Report the budget that was actually applied. This said BOOT_TIMEOUT while
# waiting for INNER_TIMEOUT, so a run that had been given 45 minutes reported
# failing after 20 -- and the number is the first thing anyone reasons from.
die "no $MARKER: L1 booted within ${BOOT_TIMEOUT}s but the inner guest did not
reach multi-user within ${INNER_TIMEOUT}s (inner budget ${L2_TIMEOUT}s).
Console kept at $CONSOLE"
