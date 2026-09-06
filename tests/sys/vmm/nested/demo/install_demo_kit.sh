#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Install the hands-on nested-virtualization demo kit on this host.
#
# The kit used to be copied onto machines by hand, which meant every host had a
# slightly different vintage of it: one box's boot environment rolled back and
# took an old copy of the driver with it, and the stale copy then failed a
# perfectly good kernel and read as a hypervisor regression.  Installing from
# the source tree removes that class of confusion -- the scripts on a host are
# the scripts in the commit, and re-running this is how a host is brought back
# into line.
#
# Usage: doas sh install_demo_kit.sh [-u user] [-n]
#     -u user   whose home directory gets the wrappers (default: the user who
#               invoked doas/sudo, else root)
#     -n        say what would be done, change nothing
#
# The two disk images are deliberately NOT fetched here.  They are several
# gigabytes each and are distributed separately; this script reports whether
# they are present so a host that cannot run a demo says so before you try.
set -eu

SRCDIR=$(cd "$(dirname "$0")" && pwd)
LIBEXEC=/usr/local/libexec/cloudbsd-demo
SHARE=/usr/local/share/cloudbsd-demo
AUTOIMG="${SHARE}/auto/nested-demo.raw"
STEPIMG="${SHARE}/stepthrough/images/layer1.raw"

USERNAME=${SUDO_USER:-${DOAS_USER:-root}}
DRYRUN=0

while getopts "u:n" opt; do
	case "$opt" in
	u)	USERNAME=$OPTARG ;;
	n)	DRYRUN=1 ;;
	*)	echo "usage: install_demo_kit.sh [-u user] [-n]" >&2; exit 1 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root: doas sh $0" >&2; exit 1; }

HOMEDIR=$(getent passwd "$USERNAME" 2>/dev/null | cut -d: -f6)
[ -n "${HOMEDIR:-}" ] || { echo "no such user: $USERNAME" >&2; exit 1; }
[ -d "$HOMEDIR" ] || { echo "no home directory for $USERNAME: $HOMEDIR" >&2; exit 1; }

run() {
	if [ "$DRYRUN" -eq 1 ]; then
		echo "would: $*"
	else
		"$@"
	fi
}

echo "installing the demo kit for ${USERNAME} (${HOMEDIR})"

# --- privileged launchers --------------------------------------------------
run mkdir -p "$LIBEXEC" "${SHARE}/auto" "${SHARE}/stepthrough/images"
for f in "$SRCDIR"/libexec/*; do
	run install -o root -g wheel -m 0755 "$f" "$LIBEXEC/"
done

# --- the user's wrappers ---------------------------------------------------
run mkdir -p "${HOMEDIR}/nested-demo"
for f in "$SRCDIR"/home/*.sh; do
	run install -o "$USERNAME" -m 0755 "$f" "${HOMEDIR}/nested-demo/"
done
run install -o "$USERNAME" -m 0644 "$SRCDIR/home/README" "${HOMEDIR}/nested-demo/"

# --- make the L2 guest's width settable ------------------------------------
# Safe to repeat: the patch script is a no-op on an image that already has it.
if [ -f "$AUTOIMG" ]; then
	run sh "$SRCDIR/patch_demo_image.sh" "$AUTOIMG"
fi

# --- report, rather than pretend -------------------------------------------
echo
if [ -f "$AUTOIMG" ]; then
	echo "demo 1/3 : ready"
else
	echo "demo 1/3 : image missing (${AUTOIMG}) - demos 1 and 3 will not run here"
fi
if [ -f "$STEPIMG" ]; then
	echo "demo 2   : ready"
else
	echo "demo 2   : image missing (${STEPIMG}) - demo 2 will not run here"
fi
if sysctl -n hw.vmm.nested.enable >/dev/null 2>&1; then
	v=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null || echo 0)
	s=$(sysctl -n hw.vmm.nested.svm 2>/dev/null || echo 0)
	if [ "${v:-0}" -ne 0 ] || [ "${s:-0}" -ne 0 ]; then
		echo "kernel   : nested build, hardware preflight passed"
	else
		echo "kernel   : nested build, but this machine's hardware did not qualify"
	fi
else
	echo "kernel   : no nested support - the kit installs, the demos will not run"
fi
echo
echo "start here:  sh ${HOMEDIR}/nested-demo/0-what-can-this-host-do.sh"
