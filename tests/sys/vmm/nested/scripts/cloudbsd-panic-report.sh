#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# cloudbsd-panic-report.sh — offer a kernel panic to the nested-virt project.
#
# This runs when YOU run it. There is no daemon and nothing is sent in the
# background: a panic on your machine is yours, and the only way anything
# leaves is if you read the report and say yes.
#
# What it sends: the panic line, the backtrace, the kernel and vmm.ko
# identity, the CPU model, the nested-virt sysctl values, and which
# virtualization layer the crash happened on.
#
# What it does not send: hostname, usernames, IP or MAC addresses, VM names,
# file paths outside the kernel, and no memory contents -- it reads FreeBSD's
# *textdump* (a formatted crash summary), never a raw core.
#
# Usage:
#   cloudbsd-panic-report.sh            show the report, then ask before sending
#   cloudbsd-panic-report.sh --print    show it and send nothing
#   cloudbsd-panic-report.sh --yes      send without asking (for scripted runs)

# shellcheck shell=sh
set -u
LC_ALL=C; export LC_ALL

PROGRAM="${0##*/}"
ENDPOINT=${PANIC_ENDPOINT:-https://nested.cloudbsd.cat/panic}
CRASHDIR=${CRASHDIR:-/var/crash}

die() { echo "${PROGRAM}: $*" >&2; exit 1; }

# --- which layer are we on? -------------------------------------------
#
# Getting this wrong is expensive: a panic reported as "the host crashed"
# when it was really the guest sends everyone looking in the wrong kernel.
# Ask in order of authority and say which answer was used, rather than
# presenting a guess as a fact.
detect_layer() {
	_marker=$(kenv -q cloudbsd.layer 2>/dev/null)
	if [ -n "${_marker}" ]; then
		echo "L${_marker} (declared by the image, kenv cloudbsd.layer)"
		return
	fi
	_guest=$(sysctl -n kern.vm_guest 2>/dev/null)
	case "${_guest}" in
	none|"")
		echo "L0 — bare metal (kern.vm_guest=none)" ;;
	*)
		# We know we are inside something, but not how deep: a guest
		# cannot see its own nesting depth unless the image says so.
		echo "L1 or deeper — inside a ${_guest} guest (kern.vm_guest=${_guest}); exact depth unknown, no kenv marker" ;;
	esac
}

# --- the newest textdump ----------------------------------------------
newest_textdump() {
	# core.txt.N, highest N first; .last is a symlink FreeBSD keeps.
	ls -t "${CRASHDIR}"/core.txt.* 2>/dev/null | head -1
}

TD=$(newest_textdump)
[ -n "${TD}" ] || die "no textdump in ${CRASHDIR}.
A panic only leaves one behind if crash dumps are enabled:
    dumpdev=\"AUTO\"     in /etc/rc.conf
    options TEXTDUMP    (GENERIC has it)
and 'sysctl debug.ddb.textdump.pending=1' before the dump is taken."

REPORT=$(mktemp -t panicrep) || die "mktemp failed"
trap 'rm -f "${REPORT}"' EXIT INT TERM

{
	echo "cloudbsd-nested panic report v1"
	echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "layer: $(detect_layer)"
	echo
	echo "== identity =="
	# uname -v ends with the build stamp -- user@host:/path -- which is
	# exactly the hostname, username and paths this report promises not to
	# carry. Keep the version and the source revision, drop the rest.
	echo "kernel: $(uname -v | sed -e 's/[[:alnum:]._-]*@[[:alnum:]._-]*:.*$//' -e 's/  */ /g' -e 's/ *$//')"
	echo "arch:   $(uname -m)"
	echo "cpu:    $(sysctl -n hw.model 2>/dev/null)"
	echo "vmm.ko: $(sha256 -q /boot/kernel/vmm.ko 2>/dev/null || echo 'not present')"
	echo "kernel-sha256: $(sha256 -q /boot/kernel/kernel 2>/dev/null || echo unknown)"
	echo
	echo "== nested-virt state =="
	sysctl hw.vmm.nested 2>/dev/null | sed 's/^/  /' || echo "  (no hw.vmm.nested — vmm not loaded or not this build)"
	echo
	echo "== panic =="
	# The panic line and the backtrace are what matter. Everything else in
	# a textdump (config, ps, msgbuf) can carry hostnames and process
	# names, so it is deliberately left out.
	grep -aE '^panic:|^KDB: |^Fatal trap|^cpuid = |^time = ' "${TD}" | head -8
	echo
	echo "-- backtrace --"
	sed -n '/KDB: stack backtrace:/,/^--- /p' "${TD}" | head -40
} > "${REPORT}"

echo
echo "=============== the report, in full ==============="
cat "${REPORT}"
echo "==================================================="
echo
echo "Destination: ${ENDPOINT}"
echo "Nothing else from this machine is included."
echo

case "${1:-}" in
--print) echo "${PROGRAM}: --print given, nothing sent."; exit 0 ;;
--yes)   ans=y ;;
*)       printf 'Send this report? [y/N] '; read -r ans ;;
esac

case "${ans}" in
y|Y|yes|YES) ;;
*) echo "${PROGRAM}: not sent."; exit 0 ;;
esac

NAME="panic-$(date -u +%Y%m%dT%H%M%SZ)-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n').txt"
CODE=$(curl -s -m 60 -o /dev/null -w '%{http_code}' -X PUT \
    --data-binary @"${REPORT}" "${ENDPOINT}/${NAME}" 2>/dev/null)
case "${CODE}" in
201|204) echo "${PROGRAM}: sent (${NAME}). Thank you — this is how the awkward ones get found." ;;
429)     echo "${PROGRAM}: rate limited; try again in a minute." ;;
*)       echo "${PROGRAM}: send failed (HTTP ${CODE:-none}). The report is yours; nothing was kept here." ;;
esac
