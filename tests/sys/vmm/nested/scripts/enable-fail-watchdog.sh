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
# ROOT=/mnt/be edits a mounted boot environment instead of the live root.
ROOT=${ROOT:-}
RC_CONF=${ROOT}/etc/rc.conf
LINE='watchdogd_enable="YES"'
# A hung box with a dead NIC keeps patting the watchdog from userland, so
# the default watchdogd never fires for the failure mode we care about.
# Have watchdogd run a reachability probe (-e) and reset when it fails
# for WATCHDOG_TIMEOUT seconds. WATCHDOG_PROBE_HOST defaults to the
# default gateway.
WATCHDOG_TIMEOUT=${WATCHDOG_TIMEOUT:-120}
WATCHDOG_PROBE_HOST=${WATCHDOG_PROBE_HOST:-$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')}
if [ -n "$WATCHDOG_PROBE_HOST" ]; then
	FLAGS_LINE="watchdogd_flags=\"-e 'ping -c 1 -t 5 $WATCHDOG_PROBE_HOST >/dev/null' -t $WATCHDOG_TIMEOUT -s 10\""
else
	FLAGS_LINE="watchdogd_flags=\"-t $WATCHDOG_TIMEOUT\""
fi

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

if grep -Eq '^[[:space:]]*watchdogd_flags=' "$RC_CONF"; then
	sed -i .nvbak "s|^[[:space:]]*watchdogd_flags=.*|$FLAGS_LINE|" "$RC_CONF"
	rm -f "${RC_CONF}.nvbak"
	log "$FLAGS_LINE SET (replaced in $RC_CONF)"
else
	printf '%s\n' "$FLAGS_LINE" >> "$RC_CONF"
	log "$FLAGS_LINE SET (appended to $RC_CONF)"
fi

if [ -n "$ROOT" ]; then
	log "PASS: watchdogd configured in ${ROOT} (not started: ROOT set)"
	exit 0
fi

if command -v service >/dev/null 2>&1; then
	service watchdogd onerestart || die "watchdogd failed to start: no hardware watchdog driver? (check 'sysctl kern.watchdog' / dmesg for ichwd/wbwd/ipmi)"
	service watchdogd onestatus >/dev/null 2>&1 || die "watchdogd not running after start"
fi

if command -v sysctl >/dev/null 2>&1; then
	sysctl debug.debugger_on_panic kern.powercycle_on_panic 2>/dev/null || true
fi

log "PASS: watchdogd enabled (hang reset). Pair with activate_oneshot_be.sh so bootfs is still the known-good BE."
exit 0
