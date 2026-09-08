#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# verify_stock_install.sh -- prove a STOCK FreeBSD can install the published
# packages and come up able to nest.
#
# This is a different claim from the media gate, and neither covers the other.
# The media gate boots images we built, where every package came from the same
# build and nothing else is installed. This exercises the route the front page
# actually tells people to take:
#
#   - the repository as PUBLISHED, fetched over the network, not a local tree
#   - pkg resolving our packages against a base system we did not build, with
#     its own FreeBSD-* packages to replace
#   - the file conflicts that come from replacing rather than supplementing
#   - a reboot onto a kernel installed by package rather than by an installer
#
# Every one of those has failed at least once. A release can pass the media
# gate completely and still be uninstallable by the documented route.
#
# The image is fetched from FreeBSD's own snapshot mirror and checked against
# FreeBSD's own manifest. That check is what makes the word "stock" mean
# anything: an image we built, or one we cannot verify, tests our build
# against our build.
#
# Usage:
#   verify_stock_install.sh [workdir]
#
# Exit 0 only if a stock system, after following the published instructions,
# reboots onto our kernel with nesting available.

set -u

PROGRAM="${0##*/}"
WORKDIR=${1:-$HOME/stock-test}
MIRROR=${MIRROR:-https://download.freebsd.org/snapshots/VM-IMAGES/16.0-CURRENT/amd64/Latest}
INSTALLER_URL=${INSTALLER_URL:-https://nested.cloudbsd.cat/install.sh}
BRIDGE=${BRIDGE:-ix0bridge}
UEFI=${UEFI:-/usr/local/share/uefi-firmware/BHYVE_UEFI.fd}
VMNAME=stockinst$$
NMDM=/dev/nmdm${VMNAME}
# Installing a kernel package over the network onto a cold guest is not fast.
BOOT_TIMEOUT=${BOOT_TIMEOUT:-600}
# Derived from the boot budget rather than fixed: the machines that needed a
# larger budget to boot need one to shut down too, and a fixed bound would fail
# them for rebooting normally but slowly.
SHUTDOWN_TIMEOUT=${SHUTDOWN_TIMEOUT:-$((BOOT_TIMEOUT / 4))}
INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-1800}
# A prompt, loose enough for the official image's shell.
SHELL_PROMPT=${SHELL_PROMPT:-'[#$] $'}

log() { printf '%s: %s\n' "$PROGRAM" "$*"; }
die() { log "FAIL: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "need root"
[ -f "$UEFI" ] || die "no UEFI firmware at $UEFI"
kldload vmm 2>/dev/null || true
kldstat -q -m vmm || die "vmm will not load on this host"
kldstat -q -m nmdm || kldload nmdm 2>/dev/null || die "no nmdm"

mkdir -p "$WORKDIR"
cd "$WORKDIR" || die "cannot use $WORKDIR"

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

# ---- 1. the stock image, and proof that it is stock ------------------------
log "fetching FreeBSD's own checksum manifest"
fetch -q -o CHECKSUM.SHA256 "$MIRROR/CHECKSUM.SHA256" ||
    die "cannot reach the FreeBSD snapshot mirror"

# Fetch from the DATED snapshot directory, by the exact filename the manifest
# names.
#
# The Latest/ directory also serves each image under a shortened name with the
# date, git hash and build number stripped -- and that shortened file does NOT
# hash to the manifest entry it appears to correspond to. Downloading it and
# checking it against the manifest fails, which looks like a corrupted download
# and is not one. Latest/ also moves, so a run tomorrow would silently test a
# different image. The dated directory is unambiguous and reproducible.
MANIFEST_NAME=$(grep -o 'FreeBSD-16\.0-CURRENT-amd64-zfs-[^)]*\.raw\.xz' CHECKSUM.SHA256 | head -1)
[ -n "$MANIFEST_NAME" ] || die "no ZFS raw image listed in the manifest"
SNAPDATE=$(echo "$MANIFEST_NAME" | sed -n 's/.*-zfs-\([0-9]\{8\}\)-.*/\1/p')
[ -n "$SNAPDATE" ] || die "cannot derive the snapshot date from $MANIFEST_NAME"
SNAPDIR="${MIRROR%/Latest}/$SNAPDATE"
IMG=$MANIFEST_NAME
# ZFS deliberately: the published install takes a boot environment first, and
# bectl needs a ZFS root. A UFS image would fail for a reason that has nothing
# to do with this release.

if [ ! -f "$IMG" ]; then
	log "fetching $IMG (this is large)"
	fetch -q -o "$IMG" "$SNAPDIR/$IMG" || die "cannot fetch $SNAPDIR/$IMG"
fi

WANT=$(sed -n "s/^SHA256 ($MANIFEST_NAME) = //p" CHECKSUM.SHA256)
GOT=$(sha256 -q "$IMG")
[ -n "$WANT" ] || die "manifest has no checksum for $MANIFEST_NAME"
if [ "$WANT" != "$GOT" ]; then
	log "manifest: $WANT"
	log "actual:   $GOT"
	die "the downloaded image is not the one FreeBSD published -- refusing to
call anything tested against it a stock install"
fi
log "stock image verified against FreeBSD's manifest: $MANIFEST_NAME"

RAW="$WORKDIR/stock.$$.raw"
log "decompressing"
xz -dc "$IMG" > "$RAW" || die "cannot decompress $IMG"

# ---- 2. a network, because the whole point is installing from the repo -----
TAP=$(ifconfig tap create) || die "cannot create a tap"
ifconfig "$TAP" up
ifconfig "$BRIDGE" addm "$TAP" || die "cannot add $TAP to $BRIDGE"
log "network: $TAP on $BRIDGE"

# ---- 3. boot it ------------------------------------------------------------
CONSOLE=$WORKDIR/${VMNAME}.console
: > "$CONSOLE"
# One descriptor, held for the run: see verify_media_nested.sh for why a
# separate stty is a race that resets termios and produces a getty loop.
( exec 3< "${NMDM}B" || exit 1
  stty raw -echo clocal <&3 2>/dev/null || true
  cat <&3 ) > "$CONSOLE" 2>/dev/null &
READER_PID=$!

# bhyve EXITS when the guest reboots -- status 0 means "the guest asked for a
# reset", and the supervisor is expected to destroy the VM and start it again.
# It is not a failure and it is not the guest disappearing. Treating that exit
# as "the machine never came back" turned a perfectly good reboot into a
# reported defect in the shipped release, which is why this is a function now
# rather than a single launch.
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

log "booting the stock image"
start_guest

wait_for() {
	_pat=$1
	_end=$(( $(date +%s) + $2 ))
	while [ "$(date +%s)" -lt "$_end" ]; do
		grep -qE "$_pat" "$CONSOLE" 2>/dev/null && return 0
		kill -0 "$BHYVE_PID" 2>/dev/null || return 1
		sleep 3
	done
	return 1
}
send() { printf '%s\r' "$1" > "${NMDM}B"; }

# The console file accumulates for the whole run, so a bare grep finds text
# from before a reboot and every post-reboot wait returns instantly against the
# FIRST boot's output. Match only what was written after a recorded point.
console_size() { wc -c < "$CONSOLE" 2>/dev/null | tr -d ' '; }
wait_for_new() {
	_off=$1
	_pat=$2
	_end=$(( $(date +%s) + $3 ))
	while [ "$(date +%s)" -lt "$_end" ]; do
		tail -c "+$(( _off + 1 ))" "$CONSOLE" 2>/dev/null |
		    grep -qE "$_pat" && return 0
		kill -0 "$BHYVE_PID" 2>/dev/null || return 1
		sleep 3
	done
	return 1
}

# Run a command in the guest and wait for a marker that only its OUTPUT can
# produce.
#
# Two traps, both of which this harness fell into and both of which produce a
# PASS that means nothing:
#
#  - the getty echoes the command line back onto the same console we grep, so
#    a marker written literally in the command matches its own echo. The guest
#    assembles it from a variable instead; the echo shows ${m}_..., only the
#    output carries the whole word.
#  - the console accumulates, so a marker from an earlier step (or from before
#    a reboot) is still sitting there. Every marker carries a per-step serial,
#    so it cannot match anything written earlier.
STEP=0
guest_step() {
	_cmd=$1
	_secs=$2
	STEP=$((STEP + 1))
	_tok="ST${STEP}X$$"
	send "m=$_tok; $_cmd; echo \${m}_DONE_\$?"
	wait_for "${_tok}_DONE_" "$_secs"
}
# Did the last step report success?
step_ok() { grep -q "ST${STEP}X$$_DONE_0" "$CONSOLE"; }
# Did the last step's output contain something?
step_saw() { grep -q "$1" "$CONSOLE"; }

if ! wait_for "login:" "$BOOT_TIMEOUT"; then
	# Distinguish "the guest did not get there" from "we never saw anything".
	if ! kill -0 "$READER_PID" 2>/dev/null; then
		die "the console reader died -- the console was never captured, so
this says nothing about whether the guest booted"
	fi
	[ "$(console_size)" = 0 ] &&
	    die "nothing was ever captured from the console: check the nmdm pair,
not the guest"
	die "the stock image never reached a login prompt"
fi
log "stock system is up; logging in"
send "root"
# A password prompt is not certain on an official image, so answer it only if
# it appears and do not fail when it does not.
if wait_for "Password:" 15; then
	send ""
fi
wait_for "$SHELL_PROMPT" 90 || die "no shell prompt after login"

# Confirm this really is an unmodified system before crediting the install.
# The exit status carries the answer, so nothing has to be pattern-matched
# against text we also typed.
guest_step "sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 30 ||
    die "the guest did not answer whether it has a nested sysctl"
if step_ok; then
	die "this system reports a nested sysctl BEFORE installing anything -- it
is not stock, and a pass here would mean nothing"
fi
log "confirmed stock: no nested support before the install"

# The guest needs to reach the repository. The official images DHCP by default.
guest_step "dhclient vtnet0 >/dev/null 2>&1; fetch -qo /tmp/i.sh $INSTALLER_URL" 240 ||
    die "the guest never answered the fetch of $INSTALLER_URL"
if ! step_ok; then
	log "console tail:"; tail -20 "$CONSOLE" | sed 's/^/  /'
	die "the stock guest could not fetch $INSTALLER_URL -- no route to the
published repository, so the install could not be attempted"
fi
log "guest reached the published site"

# ---- 4. follow the published instructions, exactly -------------------------
log "running the published one-command installer"
guest_step "sh /tmp/i.sh" "$INSTALL_TIMEOUT" || {
	log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
	die "the installer did not finish within ${INSTALL_TIMEOUT}s"
}
if ! step_ok; then
	log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
	die "the published installer exited non-zero on a stock system"
fi
log "installer completed"

# ---- 5. the reboot is part of the instructions, so it is part of the test --
log "rebooting onto the installed kernel"
# Everything after this must be judged on output written AFTER this point --
# the first boot's login prompt and shell prompt are still in the file.
MARK=$(console_size)
send "reboot"

# Wait for bhyve to exit, which is how a guest reboot presents to us -- and
# READ ITS STATUS, because bhyve says which of several very different things
# happened:
#
#   0  the guest asked for a reset. This is the reboot we told it to do.
#   1  the guest powered off instead.
#   2  the guest halted instead.
#   3+ a triple fault or a crash.
#
# Only 0 means "restart it and carry on". Relaunching regardless would make an
# installed kernel that triple-faults come back on its second boot and report
# the whole run as a success -- hiding exactly the failure this test exists to
# find.
#
# The watchdog bounds the wait without polling for a zombie: kill -0 succeeds
# against a child that has exited and not yet been reaped, so it cannot tell
# "still running" from "finished". wait(1) can.
( sleep "$SHUTDOWN_TIMEOUT"; kill -TERM "$BHYVE_PID" 2>/dev/null ) &
_watch=$!
wait "$BHYVE_PID"
_rc=$?
kill "$_watch" 2>/dev/null

case "$_rc" in
0)
	log "guest reset as asked; starting it again"
	;;
1)
	die "after the install the guest POWERED OFF instead of rebooting"
	;;
2)
	die "after the install the guest HALTED instead of rebooting"
	;;
143|137)
	die "the guest did not shut down within ${SHUTDOWN_TIMEOUT}s of being told to reboot"
	;;
*)
	die "bhyve exited $_rc after the reboot: that is a crash or triple fault,
not a reset, and the installed kernel is the thing that changed"
	;;
esac
start_guest

wait_for_new "$MARK" "login:" "$BOOT_TIMEOUT" ||
    die "the installed system did not reach a login prompt after the reboot"
log "came back up on the installed kernel"
send "root"
if wait_for_new "$MARK" "Password:" 15; then
	send ""
fi
wait_for_new "$MARK" "$SHELL_PROMPT" 120 || die "no shell prompt after the reboot"

# Per-step marker again: unique, so it cannot match the pre-reboot half of the
# file, and assembled in the guest, so it cannot match its own echo.
# Exactly what the install page tells a reader to do after rebooting. If this
# fails the instructions are wrong, whatever the cause turns out to be.
guest_step "sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 60 ||
    die "could not read the nested sysctl after the reboot"
AS_DOCUMENTED=no
step_ok && AS_DOCUMENTED=yes

# If it failed, find out WHICH failure it is before reporting one. The sysctl
# only exists once vmm(4) is loaded, so "nesting is broken" and "the module is
# not loaded" look identical from the outside and have completely different
# fixes.
if [ "$AS_DOCUMENTED" = no ]; then
	log "the documented check found no nested sysctl; loading vmm and retrying"
	guest_step "kldload vmm >/dev/null 2>&1; sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 90 ||
	    die "the guest stopped answering while loading vmm"
	if step_ok; then
		log "FAIL: nesting works, but only after loading vmm by hand."
		log "      The published instructions say to reboot and read"
		log "      hw.vmm.nested.enable, and on a fresh install that sysctl"
		log "      does not exist yet -- nothing arranges for vmm to load."
		log "      The kernel is right; the instructions are incomplete."
		log "console: $CONSOLE"
		exit 1
	fi
	log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
	die "installed and rebooted, and nesting is unavailable even with vmm
loaded by hand -- this is the kernel, not the instructions"
fi

if step_ok; then
	log "PASS: a stock FreeBSD installed the published packages and came back
with nesting available"
	log "console: $CONSOLE"
	exit 0
fi

log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
die "installed and rebooted, but nesting is not available -- the documented
route does not produce a working nested host"
