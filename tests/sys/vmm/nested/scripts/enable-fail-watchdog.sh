#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# enable-fail-watchdog.sh — reboot a host that is up but unreachable.
#
# Panic-reboot and powercycle_on_panic only fire on a panic.  A host that
# wedges, or comes up with no working network, never panics and sits there
# until someone walks to it.  This arms a recovery for that case.
#
# It does NOT use watchdogd's -e probe to do it, and the reason is worth
# stating because the previous version of this script did, and it took five
# machines off the fleet at once.
#
#   1. watchdogd -e stops patting when the probe fails, which hands the
#      decision to the KERNEL watchdog.  On a kernel built with KDB -- which
#      ours is, deliberately, for WITNESS and INVARIANTS -- the timeout in
#      hardclock() calls kdb_enter(), not a reset.  So the machine halts at a
#      db> prompt: unreachable, not rebooting, waiting for a human.  The
#      "still resets" this script used to promise was never possible.
#
#   2. The probe address was resolved once, here, and baked into rc.conf as a
#      literal -- the default gateway, identical on every host.  One address
#      every machine depended on, that could not follow a gateway change even
#      in principle.  When that gateway went away during scheduled power work,
#      every host failed its probe within the same 120 seconds.
#
# So: the reachability check runs in USERLAND and calls reboot(8) itself,
# which works whatever the kernel is built with; it resolves its targets at
# check time; it needs EVERY target to fail before it acts; and it tolerates a
# long outage first, because planned maintenance is not a wedged host.
#
# DEV/TEST ONLY. Idempotent. Requires root.

# shellcheck shell=sh
set -eu

PROGRAM="${0##*/}"
# ROOT=/mnt/be edits a mounted boot environment instead of the live root.
ROOT=${ROOT:-}
RC_CONF=${ROOT}/etc/rc.conf
WATCHDOG_BIN=${ROOT}/usr/local/sbin/nested-net-watchdog
CRON_D=${ROOT}/etc/cron.d
CRON_FILE=${CRON_D}/nested-net-watchdog

# Minutes of TOTAL unreachability before rebooting.  Deliberately long: a
# switch reboot, a DHCP renewal or someone recabling a rack must not be able
# to reboot the fleet.  The failure this catches -- a host up with a dead
# NIC -- does not resolve itself, so waiting costs nothing.
WATCHDOG_FAIL_MINUTES=${WATCHDOG_FAIL_MINUTES:-15}

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

# A mistyped or unmounted ROOT would silently arm the LIVE machine instead of
# the boot environment, which is how a host gets an auto-reboot it was never
# meant to have.  Insist it looks like a root filesystem.
if [ -n "$ROOT" ]; then
	[ -d "${ROOT}/etc" ] ||
	    die "ROOT=${ROOT} has no /etc -- not a mounted root filesystem"
	[ -d "${ROOT}/boot" ] ||
	    die "ROOT=${ROOT} has no /boot -- not a mounted root filesystem"
	# /usr is frequently its own dataset.  If it is not mounted we would
	# happily create ${ROOT}/usr/local/sbin, install into it, and report
	# success for a host that has no watchdog at all once it boots.
	[ -d "${ROOT}/usr/bin" ] && [ -n "$(ls -A "${ROOT}/usr/bin" 2>/dev/null)" ] ||
	    die "ROOT=${ROOT} has an empty /usr -- is that dataset mounted?"
fi

# The reachability check itself.  Installed as a file rather than embedded in
# a crontab line so it can be read, tested and run by hand on the host.
mkdir -p "$(dirname "${WATCHDOG_BIN}")"
cat > "${WATCHDOG_BIN}" <<'WATCHDOG'
#!/bin/sh
# Reboot this host if it has been unable to reach ANY of its network
# neighbours for a sustained period.  Installed by enable-fail-watchdog.sh.
#
# Runs from cron once a minute and keeps its count in a state file, so a
# single failed probe does nothing; only an unbroken run of them acts.
set -u

# The consecutive-failure count is per-boot, so /var/run is right for it.
STATE=/var/run/nested-net-watchdog.count
# The reboot count must NOT be, because /var/run is cleared on boot: a host
# whose network is genuinely dead -- a failed NIC, a pulled cable -- would
# come back, count up, and reboot again every FAIL_MINUTES for ever.  Keep it
# somewhere that survives, and give up after MAX_REBOOTS.  A host sitting up
# and unreachable needs a person either way; rebooting it hourly for days
# only destroys the evidence of why.
REBOOTS=/var/db/nested-net-watchdog.reboots
MAX_REBOOTS=3
FAIL_MINUTES=__FAIL_MINUTES__

# Resolved on every run, never cached: a host that legitimately changed
# gateway must not keep probing the old one.
targets=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')
# Any other host on the local segment counts as a second opinion, so the
# gateway alone cannot condemn the machine.
targets="$targets $(arp -an 2>/dev/null |
    awk '{gsub(/[()]/, "", $2); print $2}' | grep -v '^$' | head -4)"

reachable=0
for t in $targets; do
	[ -n "$t" ] || continue
	if ping -c 1 -t 3 "$t" >/dev/null 2>&1; then
		reachable=1
		break
	fi
done

# No targets at all means nothing to conclude from -- an empty ARP table on a
# freshly booted host is not evidence that the network is gone.
if [ -z "$(echo "$targets" | tr -d ' ')" ]; then
	rm -f "$STATE"
	exit 0
fi

if [ "$reachable" = "1" ]; then
	# Network is fine, so any past reboots did their job: start afresh.
	rm -f "$STATE" "$REBOOTS"
	exit 0
fi

count=$(cat "$STATE" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$STATE"
logger -t nested-net-watchdog "no network neighbour reachable ($count/$FAIL_MINUTES)"

if [ "$count" -ge "$FAIL_MINUTES" ]; then
	tries=$(cat "$REBOOTS" 2>/dev/null || echo 0)
	if [ "$tries" -ge "$MAX_REBOOTS" ]; then
		logger -t nested-net-watchdog \
		    "unreachable, but already rebooted ${tries} times: giving up"
		rm -f "$STATE"
		exit 0
	fi
	echo $((tries + 1)) > "$REBOOTS"
	logger -t nested-net-watchdog \
	    "unreachable for ${FAIL_MINUTES}m, rebooting (attempt $((tries + 1))/${MAX_REBOOTS})"
	rm -f "$STATE"
	# Userland reboot: works regardless of how the kernel is built, unlike
	# the kernel watchdog, which enters the debugger on a KDB kernel.
	reboot -q
fi
exit 0
WATCHDOG

sed -i .nvbak "s|__FAIL_MINUTES__|${WATCHDOG_FAIL_MINUTES}|" "${WATCHDOG_BIN}"
rm -f "${WATCHDOG_BIN}.nvbak"
chmod 755 "${WATCHDOG_BIN}"
log "installed ${WATCHDOG_BIN} (reboot after ${WATCHDOG_FAIL_MINUTES}m unreachable)"

mkdir -p "${CRON_D}"
cat > "${CRON_FILE}" <<CRON
# Nested-virt: reboot a host that is up but has lost the network entirely.
# Installed by enable-fail-watchdog.sh; see that script for why this is not
# watchdogd.
*/1 * * * * root /usr/local/sbin/nested-net-watchdog
CRON
log "installed ${CRON_FILE}"

# The kernel watchdog guards a genuinely wedged kernel, which a userland cron
# job cannot.  But it is only worth arming if its timeout actually resets the
# machine, and with KDB compiled in it does not -- it stops at a debugger
# prompt.
#
# Decide this FAIL-CLOSED: arm watchdogd only when we have positively
# established that this kernel has no KDB.  Anything we could not determine --
# a mounted boot environment whose kernel we cannot interrogate, a sysctl we
# could not read -- refuses to arm.  Guessing "probably fine" here is exactly
# how five hosts ended up halted at db>; the cost of refusing is that a wedge
# needs a human, and the cost of guessing wrong is that everything else does.
NEW_WD=NO
if [ -n "$ROOT" ]; then
	log "NOT arming watchdogd: cannot read the kernel of a mounted boot"
	log "  environment from the running one, and arming it blind is how"
	log "  hosts were lost. The userland check above still applies."
elif ! kdb=$(sysctl -n debug.kdb.available 2>/dev/null); then
	log "NOT arming watchdogd: could not read debug.kdb.available, so"
	log "  whether a timeout would reset or halt this host is unknown."
elif [ -n "$kdb" ]; then
	log "NOT arming watchdogd: this kernel has KDB (${kdb}), so a watchdog"
	log "  timeout enters the debugger instead of resetting -- it would halt"
	log "  the host, not recover it. Userland check installed instead."
else
	# Our GENERIC is built with KDB, so on this fleet the refusals above
	# are the normal outcome and this branch is not expected to be taken.
	log "no KDB in this kernel: watchdogd may safely reset on a wedge"
	NEW_WD=YES
fi

if [ ! -f "$RC_CONF" ]; then
	: > "$RC_CONF"
fi

# Remove any probe-based flags a previous version of this script left behind.
# Leaving them is not harmless: they are what halts the host.
if grep -Eq '^[[:space:]]*watchdogd_flags=' "$RC_CONF"; then
	sed -i .nvbak '/^[[:space:]]*watchdogd_flags=/d' "$RC_CONF"
	rm -f "${RC_CONF}.nvbak"
	log "removed stale watchdogd_flags (network probe) from $RC_CONF"
fi

if grep -Eq '^[[:space:]]*watchdogd_enable=' "$RC_CONF"; then
	sed -i .nvbak "s/^[[:space:]]*watchdogd_enable=.*/watchdogd_enable=\"${NEW_WD}\"/" "$RC_CONF"
	rm -f "${RC_CONF}.nvbak"
else
	printf '\nwatchdogd_enable="%s"\n' "${NEW_WD}" >> "$RC_CONF"
fi
log "watchdogd_enable=\"${NEW_WD}\" SET in $RC_CONF"

if [ -n "$ROOT" ]; then
	log "PASS: configured in ${ROOT} (not started: ROOT set)"
	exit 0
fi

if [ "${NEW_WD}" = "NO" ] && command -v service >/dev/null 2>&1; then
	service watchdogd stop >/dev/null 2>&1 || true
fi

log "PASS: unreachable-host recovery armed in userland. Pair with"
log "  activate_oneshot_be.sh so a reboot lands on the known-good BE."
exit 0
