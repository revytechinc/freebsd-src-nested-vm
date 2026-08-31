#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 The FreeBSD Project
#
# activate_oneshot_be.sh — bectl activate -t WITHOUT changing zpool bootfs.
#
# This is the failure-reboot contract:
#   * bootfs stays on the known-good BE
#   * candidate is ZFS bootonce (next boot only)
#   * loader consumes bootonce; the following boot (panic power-cycle,
#     watchdog reset, or IPMI) returns to bootfs
#
# Flipping bootfs to the candidate is what stuck nested installs: a
# panic reboot then comes back into the same kernel. 008 did not
# recover because a hang is not a panic, and/or bootfs was pinned.
#
# Usage: activate_oneshot_be.sh <candidate-be>
#    env ONESHOT_POOL=zroot  (default zroot)

# shellcheck shell=sh
set -eu

PROGRAM="${0##*/}"
POOL="${ONESHOT_POOL:-zroot}"
CANDIDATE=${1:-}

log()
{
	printf '%s: %s\n' "$PROGRAM" "$*"
}

die()
{
	log "FAIL: $*"
	exit 1
}

if [ -z "$CANDIDATE" ]; then
	die "usage: $PROGRAM <candidate-be>"
fi
if ! command -v bectl >/dev/null 2>&1; then
	die "bectl not in PATH"
fi
if [ "$(id -u)" -ne 0 ]; then
	die "need root"
fi

case "$CANDIDATE" in
*/*)
	die "pass the BE name only (e.g. wave7-preflight), not a dataset path"
	;;
esac

bootfs=$(zpool get -H -o value bootfs "$POOL") || die "zpool get bootfs $POOL"
[ -n "$bootfs" ] && [ "$bootfs" != "-" ] || die "$POOL has no bootfs"

log "pool=$POOL"
log "bootfs(before)=$bootfs"
log "candidate=$CANDIDATE (activate -t only)"

# bectl list ignores a name argument, so scan the first column.
if ! bectl list -H | awk '{print $1}' | grep -qx "$CANDIDATE"; then
	die "BE $CANDIDATE does not exist"
fi

good=${bootfs##*/}
if [ "$good" = "$CANDIDATE" ]; then
	die "bootfs already is $CANDIDATE; oneshot would not revert. Set bootfs back to the known-good BE first"
fi

bectl activate -t "$CANDIDATE" || die "bectl activate -t $CANDIDATE failed"

bootfs_after=$(zpool get -H -o value bootfs "$POOL")
log "bootfs(after)=$bootfs_after"

if [ "$bootfs_after" != "$bootfs" ]; then
	die "bootfs changed from $bootfs to $bootfs_after — abort. Restore with: zpool set bootfs=$bootfs $POOL"
fi

log "PASS: next boot is $CANDIDATE (bootonce); later boots stay $bootfs"
log "on panic/watchdog/IPMI reset the loader has consumed bootonce and $good comes back"
exit 0
