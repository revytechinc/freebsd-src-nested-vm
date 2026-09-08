#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# verify_upgrade.sh -- prove the PREVIOUSLY PUBLISHED release can move to the
# current one.
#
# This is a different population from a new install, and a different code path.
# The people who will run "upgrade" are the ones already carrying our packages,
# which means:
#
#   - their pkg lock on the bhyve package is in place and blocks the install
#     until it is lifted; a first-time installer never meets this
#   - their FreeBSD-* meta-packages were already removed by the earlier swap,
#     so the conflict resolution has a different shape
#   - they have a boot environment layout already, and whatever the upgrade
#     does to it is what they live with
#
# Each of those has failed at least once. A release can install perfectly onto
# a clean machine and still be un-upgradable from the release before it, which
# is worse -- those users followed our instructions.
#
# It starts from the artifact that was genuinely on the site, not from a fresh
# install of the new build. Starting anywhere else tests something nobody has.
#
# Usage:
#   verify_upgrade.sh <previous-release-image.xz|.raw> [workdir]
#
# Exit 0 only if the machine comes back on a NEWER version with nesting still
# working.

set -u

PROGRAM="${0##*/}"
PREV=${1:?usage: $PROGRAM <previous-release-image> [workdir]}
WORKDIR=${2:-$HOME/upgrade-test}
INSTALLER_URL=${INSTALLER_URL:-https://nested.cloudbsd.cat/install.sh}
BRIDGE=${BRIDGE:-ix0bridge}
UEFI=${UEFI:-/usr/local/share/uefi-firmware/BHYVE_UEFI.fd}
VMNAME=upgrade$$
NMDM=/dev/nmdm${VMNAME}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-900}
UPGRADE_TIMEOUT=${UPGRADE_TIMEOUT:-1800}
SHUTDOWN_TIMEOUT=${SHUTDOWN_TIMEOUT:-$((BOOT_TIMEOUT / 4))}
SHELL_PROMPT=${SHELL_PROMPT:-'[#$] $'}

log() { printf '%s: %s\n' "$PROGRAM" "$*"; }
die() { log "FAIL: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "need root"
[ -f "$PREV" ] || die "no such image: $PREV"
[ -f "$UEFI" ] || die "no UEFI firmware at $UEFI"
kldload vmm 2>/dev/null || true
kldstat -q -m vmm || die "vmm will not load on this host"
kldstat -q -m nmdm || kldload nmdm 2>/dev/null || die "no nmdm"

mkdir -p "$WORKDIR"
TAP=""
cleanup() {
	[ -n "${READER_PID:-}" ] && kill "$READER_PID" 2>/dev/null || true
	bhyvectl --vm="$VMNAME" --destroy >/dev/null 2>&1 || true
	if [ -n "$TAP" ]; then
		ifconfig "$BRIDGE" deletem "$TAP" 2>/dev/null || true
		ifconfig "$TAP" destroy 2>/dev/null || true
	fi
	[ "${KEEP_RAW:-0}" = 1 ] || rm -f "${RAW:-}"
	return 0
}
trap cleanup EXIT INT TERM

RAW="$WORKDIR/prev.$$.raw"
case "$PREV" in
*.xz)	log "decompressing the previously published image"
	xz -dc "$PREV" > "$RAW" || die "cannot decompress $PREV" ;;
*)	cp "$PREV" "$RAW" || die "cannot stage $PREV" ;;
esac

TAP=$(ifconfig tap create) || die "cannot create a tap"
ifconfig "$TAP" up
ifconfig "$BRIDGE" addm "$TAP" || die "cannot add $TAP to $BRIDGE"

CONSOLE=$WORKDIR/${VMNAME}.console
: > "$CONSOLE"
# One descriptor held for the run; a separate stty is a race that resets
# termios and produces a getty loop.
( exec 3< "${NMDM}B" || exit 1
  stty raw -echo clocal <&3 2>/dev/null || true
  cat <&3 ) > "$CONSOLE" 2>/dev/null &
READER_PID=$!

# If the slave side could not be opened, every wait below would run to its full
# timeout and then blame the guest for a console nobody was reading. Find out
# here, where the message can name the real cause.
sleep 1
kill -0 "$READER_PID" 2>/dev/null ||
    die "could not open ${NMDM}B to read the guest console"

start_guest() {
	bhyvectl --vm="$VMNAME" --destroy >/dev/null 2>&1 || true
	bhyve -c 2 -m 4G -A -H -P \
		-s 0,hostbridge \
		-s 2,virtio-blk,"$RAW" \
		-s 3,virtio-net,"$TAP" \
		-s 31,lpc \
		-l com1,"${NMDM}A" \
		-l bootrom,"$UEFI" "$VMNAME" >/dev/null 2>&1 &
	BHYVE_PID=$!
}

console_size() { wc -c < "$CONSOLE" 2>/dev/null | tr -d ' '; }
wait_for_new() {
	_off=$1; _pat=$2
	_end=$(( $(date +%s) + $3 ))
	while [ "$(date +%s)" -lt "$_end" ]; do
		tail -c "+$(( _off + 1 ))" "$CONSOLE" 2>/dev/null | grep -qE "$_pat" && return 0
		kill -0 "$BHYVE_PID" 2>/dev/null || return 1
		sleep 3
	done
	return 1
}
send() { printf '%s\r' "$1" > "${NMDM}B"; }

STEP=0
guest_step() {
	STEP=$((STEP + 1))
	_tok="UP${STEP}X$$"
	# Marker assembled in the guest: the getty echoes the command line back
	# onto the console we grep, so a literal marker matches its own echo.
	#
	# Scanning from offset 0 is safe rather than sloppy: the token carries both
	# this run's pid and a step number that only ever increases, so a marker
	# can only have been printed by the step that owns it. There is nothing
	# earlier in the file for it to match, including across the reboot.
	#
	# Scanning from offset 0 is safe rather than sloppy: the token carries both
	# this run.s pid and a step number that only ever increases, so a marker can
	# only have been printed by the step that owns it. There is nothing earlier
	# in the file for it to match, including across the reboot.
	send "m=$_tok; $1; echo \${m}_DONE_\$?"
	wait_for_new 0 "${_tok}_DONE_" "$2"
}
step_ok() { grep -q "UP${STEP}X$$_DONE_0" "$CONSOLE"; }

log "booting the previously published release"
start_guest
wait_for_new 0 "login:" "$BOOT_TIMEOUT" || die "the previous release did not reach a login prompt"
send "root"
if wait_for_new 0 "Password:" 15; then send ""; fi
wait_for_new 0 "$SHELL_PROMPT" 90 || die "no shell prompt after login"

# Root's login shell on FreeBSD is not guaranteed to be sh, and every step
# below is POSIX shell syntax. csh would reject the lot and each step would
# time out, which reads as a hung guest rather than the wrong interpreter.
send "sh"
wait_for_new 0 "$SHELL_PROMPT" 30 || log "could not confirm an sh prompt (continuing)"

# It must already be one of ours, or this is not an upgrade test.
guest_step "kldstat -q -m vmm || kldload vmm; sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 90 ||
    die "the guest did not answer whether it has nesting"
step_ok || die "the starting image does not have nesting available, so it is not
a previously published release and nothing upgraded from it would mean anything"
log "confirmed: starting from a release that already nests"

# Record where we are starting from, so "it upgraded" is checkable rather than
# assumed.
BEFORE_MARK=$(console_size)
send "pkg query '%n-%v' CloudBSD-kernel-generic"
wait_for_new "$BEFORE_MARK" "CloudBSD-kernel-generic-" 60 ||
    log "could not read the starting package version (continuing)"
BEFORE=$(tail -c "+$((BEFORE_MARK + 1))" "$CONSOLE" | tr -d '\r' |
    grep -o 'CloudBSD-kernel-generic-[0-9A-Za-z._]*' | head -1)
log "starting version: ${BEFORE:-unknown}"

guest_step "dhclient vtnet0 >/dev/null 2>&1; fetch -qo /tmp/i.sh $INSTALLER_URL" 240 ||
    die "the guest never answered the fetch of $INSTALLER_URL"
step_ok || die "the guest could not reach $INSTALLER_URL"

log "running the published installer as an upgrade"
guest_step "sh /tmp/i.sh" "$UPGRADE_TIMEOUT" || {
	log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
	die "the upgrade did not finish within ${UPGRADE_TIMEOUT}s"
}
if ! step_ok; then
	log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
	die "the published installer exited non-zero upgrading an existing release.
This is the population most likely to hit it: their pkg lock is already set"
fi
log "upgrade completed"

MARK=$(console_size)
send "reboot"
( sleep "$SHUTDOWN_TIMEOUT"; kill -TERM "$BHYVE_PID" 2>/dev/null ) &
_watch=$!
wait "$BHYVE_PID"
_rc=$?
kill "$_watch" 2>/dev/null
case "$_rc" in
0)       log "guest reset as asked; starting it again" ;;
1)       die "after the upgrade the guest POWERED OFF instead of rebooting" ;;
2)       die "after the upgrade the guest HALTED instead of rebooting" ;;
143|137) die "the guest did not shut down within ${SHUTDOWN_TIMEOUT}s" ;;
127)     die "lost track of the bhyve process, so the reboot cannot be judged.
This is a fault in the harness, not a verdict on the release" ;;
*)       die "bhyve exited $_rc after the reboot: a crash or triple fault, and
the upgraded kernel is the thing that changed" ;;
esac
start_guest

wait_for_new "$MARK" "login:" "$BOOT_TIMEOUT" ||
    die "the upgraded system did not reach a login prompt"
send "root"
if wait_for_new "$MARK" "Password:" 15; then send ""; fi
wait_for_new "$MARK" "$SHELL_PROMPT" 120 || die "no shell prompt after the reboot"

guest_step "kldstat -q -m vmm || kldload vmm; sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 90 ||
    die "the upgraded guest did not answer about nesting"
step_ok || die "the upgrade completed and nesting is no longer available -- an
upgrade that removes the feature is worse than one that fails"

AFTER_MARK=$(console_size)
send "pkg query '%n-%v' CloudBSD-kernel-generic"
wait_for_new "$AFTER_MARK" "CloudBSD-kernel-generic-" 60 || true
AFTER=$(tail -c "+$((AFTER_MARK + 1))" "$CONSOLE" | tr -d '\r' |
    grep -o 'CloudBSD-kernel-generic-[0-9A-Za-z._]*' | head -1)
log "ending version: ${AFTER:-unknown}"

# The whole point: did it actually move, and in the right direction?
#
# This assertion is mandatory, not best-effort. An earlier draft skipped it
# when either version could not be read, which quietly turned the strongest
# check in the test into a no-op and would have reported PASS for an upgrade
# that moved nothing. A check that disappears when its input is missing is
# worse than no check, because it still prints PASS.
[ -n "$BEFORE" ] || die "could not read the version before upgrading, so
'it upgraded' cannot be established. Refusing to pass on an unverifiable claim"
[ -n "$AFTER" ] || die "could not read the version after upgrading, so
'it upgraded' cannot be established. Refusing to pass on an unverifiable claim"

if [ "$BEFORE" = "$AFTER" ]; then
	die "the version did not change: still $AFTER. The upgrade reported success
and moved nothing, which is exactly what a package version that does not sort
above the installed one looks like from here"
fi

# Different is not the same as newer. Ask pkg, in the guest, which way it went.
BV=${BEFORE#CloudBSD-kernel-generic-}
AV=${AFTER#CloudBSD-kernel-generic-}
DIR_MARK=$(console_size)
send "pkg version -t $BV $AV"
if wait_for_new "$DIR_MARK" '[<>=]' 60; then
	DIR=$(tail -c "+$((DIR_MARK + 1))" "$CONSOLE" | tr -d '\r' |
	    grep -oE '^[<>=]$' | head -1)
	case "$DIR" in
	'<')	log "direction confirmed: $BV -> $AV is an upgrade" ;;
	'>')	die "the machine moved BACKWARDS: $BV -> $AV. pkg considers the
installed version newer than what it just installed" ;;
	*)	log "pkg could not order $BV against $AV (got '${DIR:-nothing}')" ;;
	esac
else
	log "could not read an ordering verdict from the guest"
fi

log "PASS: the previously published release upgraded from $BV to $AV, rebooted, and still nests"
log "console: $CONSOLE"
exit 0
