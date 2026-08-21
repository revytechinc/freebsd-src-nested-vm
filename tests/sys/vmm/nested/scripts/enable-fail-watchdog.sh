#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 The FreeBSD Project
#
# enable-fail-watchdog.sh — arm watchdogd so a hang (no panic) still resets.
#
# Panic-reboot / powercycle_on_panic only fire on panic. A nested-virt
# hang that never panics (008: no ARP, no SSH, box not "down") sits
# forever unless the watchdog resets it onto the known-good bootfs.
#
# DEV/TEST ONLY. Idempotent. Requires root.

# shellcheck shell=sh
set -eu

PROGRAM="${0##*/}"
RC_CONF=/etc/rc.conf
LINE='watchdogd_enable="YES"'

log()
{
	printf '%s: %s\n' "$PROGRAM" "$*"
}

die()
{
	log "FAIL: $*"
	exit 1
}

if [ "$(id -u)" -ne 0 ]; then
	die "need root"
fi

if [ ! -f "$RC_CONF" ]; then
	: > "$RC_CONF"
fi

if grep -Eq '^[[:space:]]*watchdogd_enable=' "$RC_CONF"; then
	# Last assignment wins; rewrite if it is not YES.
	if grep -Eq '^[[:space:]]*watchdogd_enable="YES"' "$RC_CONF"; then
		log "$LINE UNCHANGED (already in $RC_CONF)"
	else
		log "replacing existing watchdogd_enable in $RC_CONF"
		# BSD sed -i requires a suffix; keep a .bak then drop it.
		sed -i .nvbak 's/^[[:space:]]*watchdogd_enable=.*/watchdogd_enable="YES"/' "$RC_CONF"
		rm -f "${RC_CONF}.nvbak"
	fi
else
	printf '\n# Nested-virt fail-reboot: reset on hang, not only panic.\n%s\n' "$LINE" >> "$RC_CONF"
	log "$LINE SET (appended to $RC_CONF)"
fi

if command -v service >/dev/null 2>&1; then
	if service watchdogd onestatus >/dev/null 2>&1; then
		log "watchdogd already running"
	else
		service watchdogd onestart || log "watchdogd start failed (no hardware watchdog?)"
	fi
fi

if command -v sysctl >/dev/null 2>&1; then
	sysctl debug.debugger_on_panic kern.powercycle_on_panic 2>/dev/null || true
fi

log "PASS: watchdogd enabled (hang reset). Pair with activate_oneshot_be.sh so bootfs is still the known-good BE."
exit 0
