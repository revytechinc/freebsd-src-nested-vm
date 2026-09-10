#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# upgrade_to_published.sh -- move this machine to a published release, by the
# same route the public install.sh takes.
#
# A test host that is upgraded by some private sequence is not testing the
# thing a reader receives. This is that sequence, written down, so the fleet
# and a stranger following the site take the same path.
#
# Usage:
#   upgrade_to_published.sh <version>
#
#   e.g. upgrade_to_published.sh 16.0.20260909.deepnest15
#
# Reboots on success. Exits non-zero, without rebooting, on anything else.
set -eu

PROGRAM="${0##*/}"

# Private, unpredictable, and cleaned up. These files hold pkg's output on
# failure, and a fixed name under a world-writable /tmp is a path any local
# user can pre-plant a symlink at -- so the shell here, which is NOT running
# under doas, would truncate whatever that link points at, and the diagnosis
# an operator reads would be attacker-chosen.
LOGD=$(mktemp -d "${TMPDIR:-/tmp}/upgpub.XXXXXX") || {
	echo "$PROGRAM: cannot make a working directory" >&2; exit 1; }
trap 'rm -rf "$LOGD"' EXIT

WANT=${1:-}
if [ -z "$WANT" ]; then
	echo "usage: $PROGRAM <version>" >&2
	exit 2
fi
# The version reaches pkg query comparisons and nothing else, but a value with
# a space or a shell character in it would still make the failure message lie
# about which version was wanted.
case "$WANT" in
*[!0-9A-Za-z._-]*)
	echo "$PROGRAM: $WANT is not a package version" >&2
	exit 2 ;;
esac

# The published packages declare a newer __FreeBSD_version than a host running
# the previous release, and pkg REFUSES the whole repository over it rather than
# warning. install.sh sets this for the same reason; the mismatch disappears
# once the host has rebooted onto the new world.
IGNORE_OSVERSION=yes; export IGNORE_OSVERSION

echo "== $(hostname -s): $(uname -v | sed 's/:.*//')"

# Refuse to upgrade a boot environment the machine is about to leave.
#
# A one-shot activation (`bectl activate -t') boots a BE ONCE: the machine is
# running it now and is set to return to a different one on the next reboot.
# Upgrading in that state installs the new release into a filesystem that the
# reboot discards -- and every check passes on the way, because pkg really did
# install the packages and really does report the new version. The host then
# comes back on the OLD release having reported success, which is the worst
# shape a failure can take. Measured on a fleet host: it reported deepnest15
# installed, rebooted, and returned running deepnest13.
#
# bectl marks the running BE `N' and the one active on reboot `R'; a permanent
# activation is `NR'. So the two letters have to be on the same row.
#
# FAILS CLOSED. Under doas, like every other privileged query here, and any
# output this cannot parse refuses. "I could not tell" and "it is safe" lead to
# different actions, and conflating them is the whole defect this guards.
check_be() {
	# "This system has no boot environments" and "bectl is not on PATH right
	# now" are different facts, and only the first is a reason to skip. Boot
	# environments need a ZFS root, so that is what decides it: on UFS there
	# is nothing to guard, and on ZFS a missing bectl is a stripped or
	# half-upgraded environment where the guard should refuse rather than
	# wave the upgrade through -- everything else in this function fails
	# closed and this path would have been the exception.
	if ! command -v bectl >/dev/null 2>&1; then
		if mount -p 2>/dev/null | awk '$2 == "/" {print $3}' |
		    grep -q '^zfs$'; then
			echo "  this machine has a ZFS root but no bectl, so which boot"
			echo "  environment survives a reboot cannot be established."
			echo "  Refusing rather than upgrading one that might be discarded."
			return 1
		fi
		return 0
	fi
	_bl=$(doas bectl list -H 2>/dev/null) || _bl=""
	if [ -z "$_bl" ]; then
		echo "  bectl is present but listed nothing, so which boot environment"
		echo "  survives a reboot cannot be established. Refusing rather than"
		echo "  upgrading one that might be discarded."
		return 1
	fi
	_nn=$(printf '%s\n' "$_bl" | awk '$2 ~ /N/' | grep -c .) || _nn=0
	_nr=$(printf '%s\n' "$_bl" | awk '$2 ~ /R/' | grep -c .) || _nr=0
	if [ "$_nn" != 1 ] || [ "$_nr" != 1 ]; then
		echo "  bectl reports $_nn running and $_nr active-on-reboot boot"
		echo "  environments; exactly one of each is expected. Refusing rather"
		echo "  than guessing which one an upgrade would land in."
		return 1
	fi
	_now=$(printf '%s\n' "$_bl" | awk '$2 ~ /N/ {print $1; exit}')
	_next=$(printf '%s\n' "$_bl" | awk '$2 ~ /R/ {print $1; exit}')
	if [ "$_now" != "$_next" ]; then
		echo "  running boot environment $_now, but $_next is active on reboot."
		echo "  This is a one-shot activation: an upgrade here would be thrown"
		echo "  away by the reboot while reporting success. Activate the boot"
		echo "  environment you mean to keep first (bectl activate <be>)."
		return 1
	fi
	return 0
}

check_be || exit 1

# `doas env VAR=...', not an exported variable and a bare `doas'. doas does not
# pass the environment through unless the host's doas.conf says keepenv, so an
# export here reaches pkg on some fleet hosts and not others -- and the one it
# does not reach fails on the version mismatch while its neighbours succeed,
# which reads as a broken host rather than a missing word.
if ! doas env IGNORE_OSVERSION=yes pkg update -f -r CloudBSD >"$LOGD/update.log" 2>&1; then
	echo "  pkg update failed:"
	# The reason, not just the fact. This used to discard pkg's output, so a
	# refusal over a version mismatch and a refusal over an untrusted
	# signature looked identical from here.
	sed 's/^/    /' "$LOGD/update.log" | tail -15
	exit 1
fi

# CloudBSD-bhyve is locked so a base upgrade cannot revert the nested work.
# Unlock, upgrade, lock again -- and lock again even if the upgrade fails,
# because leaving it unlocked is the state the lock exists to prevent.
# What the repository is OFFERING, before anything is changed. `pkg upgrade -y'
# moves every CloudBSD package on this machine, so checking the version
# afterwards can only refuse the reboot -- the upgrade has already happened. A
# mistyped version, or a repository that has moved on, should cost nothing.
_offer=$(doas env IGNORE_OSVERSION=yes pkg rquery -r CloudBSD %v \
    CloudBSD-kernel-generic 2>/dev/null) || _offer=""
if [ "$_offer" != "$WANT" ]; then
	echo "  the CloudBSD repository offers ${_offer:-nothing} for"
	echo "  CloudBSD-kernel-generic, not $WANT. Nothing has been changed."
	exit 1
fi

doas pkg unlock -yq CloudBSD-bhyve >/dev/null 2>&1 || true

# Relock on every exit from here, including an interrupt. The window between
# the unlock and the lock is the only time a base upgrade could revert the
# nested bhyve, and a script that leaves the machine unlocked on its way out
# has removed the protection it exists to preserve.
#
# This REPLACES the earlier EXIT trap rather than adding to it -- a second
# `trap ... EXIT' does not chain -- so it repeats the working-directory
# removal. Deliberate, and worth saying: the same construct written by
# accident is how a cleanup silently stops running.
trap 'doas pkg lock -yq CloudBSD-bhyve >/dev/null 2>&1 || true; rm -rf "$LOGD"' EXIT

_rc=0
doas env IGNORE_OSVERSION=yes pkg upgrade -y -r CloudBSD >"$LOGD/upgrade.log" 2>&1 || _rc=$?
if [ "$_rc" -ne 0 ]; then
	echo "  pkg upgrade exited $_rc"; tail -15 "$LOGD/upgrade.log"; exit 1
fi

# And check that the lock actually took, rather than discarding its status.
# Rebooting having reported success with CloudBSD-bhyve unlocked leaves the
# machine in exactly the state the lock is there to prevent, and nothing
# afterwards would say so.
#
# The query runs under doas, like the lock itself. These hosts set
# security.bsd.see_other_uids=0 and the package database is root's, so an
# unprivileged `pkg lock -l' can come back empty on a machine that is locked
# correctly -- and this would then abort a good upgrade insisting the lock is
# missing.
doas pkg lock -yq CloudBSD-bhyve >/dev/null 2>&1 || true
if ! doas pkg lock -l 2>/dev/null | grep -q '^CloudBSD-bhyve'; then
	echo "  CloudBSD-bhyve is NOT locked after the upgrade."
	echo "  A later base upgrade could revert the nested hypervisor, so this"
	echo "  machine is not in a state to reboot into. Lock it and re-run."
	exit 1
fi

# What is installed, not what pkg said it did.
#
# Under doas, for the reason given above the lock check: the package database
# is root's and these hosts set security.bsd.see_other_uids=0, so an
# unprivileged query can return EMPTY on a machine that is perfectly upgraded.
# Empty is not a non-zero exit, so `|| echo absent' would not catch it and the
# comparison would fail against the empty string -- aborting a good upgrade one
# line before the reboot.
for p in CloudBSD-kernel-generic CloudBSD-bhyve CloudBSD-lib9p; do
	_v=$(doas pkg query %v "$p" 2>/dev/null) || _v=""
	[ -n "$_v" ] || _v=absent
	if [ "$_v" != "$WANT" ]; then
		echo "  $p is $_v, wanted $WANT"; exit 1
	fi
done
# Again, immediately before the reboot. The state could have changed while the
# upgrade ran, and this is the moment the answer actually matters.
if ! check_be; then
	echo "  the upgrade is installed, but this machine must not reboot into it."
	exit 1
fi

# The message AFTER the reboot is scheduled, and shutdown's own error kept.
# Printing "rebooting" first and discarding the failure leaves a transcript
# claiming a reboot that never happened, with nothing to say why.
if ! _sd=$(doas shutdown -r +1 "upgrading to $WANT" 2>&1); then
	echo "  packages are at $WANT, but the reboot was refused:"
	printf '%s\n' "$_sd" | sed 's/^/    /'
	echo "  The machine is still running the old kernel."
	exit 1
fi
echo "  packages at $WANT; rebooting onto the new kernel"
