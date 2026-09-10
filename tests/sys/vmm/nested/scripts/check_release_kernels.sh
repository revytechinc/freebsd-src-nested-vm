#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Assert that every artifact of a release carries the SAME kernel.
#
# The kernel binary is not reproducible: newvers.sh embeds a build counter and
# a timestamp, so two runs over identical source produce different bytes. A
# release assembled from two build runs therefore carries two different kernels
# while its manifest names one commit -- and nothing downstream notices. The
# packages install one kernel, the VM images boot another, and both report the
# version string they were told to.
#
# That shipped once. deepnest14 went out with VM images from one run and
# packages from another, and it was found by comparing binaries after
# publication rather than by any check before it.
#
# This is that comparison, in the tree and runnable, rather than a thing
# somebody remembers to do:
#
#   check_release_kernels.sh -r <release objdir> -v <package version> [-p prefix]
#
# Exit 0 when every artifact holds one kernel, 1 otherwise. Needs root: it
# attaches the images with mdconfig(8) to read them.

set -eu

PROGRAM="${0##*/}"
RELOBJ=""
VERSION=""
PREFIX=CloudBSD

usage() {
	echo "usage: $PROGRAM -r <release-objdir> -v <version> [-p prefix]" >&2
	exit 2
}

while getopts r:v:p: o; do
	case "$o" in
	r)	RELOBJ=$OPTARG ;;
	v)	VERSION=$OPTARG ;;
	p)	PREFIX=$OPTARG ;;
	*)	usage ;;
	esac
done
[ -n "$RELOBJ" ] && [ -n "$VERSION" ] || usage
[ -d "$RELOBJ" ] || { echo "$PROGRAM: no release directory at $RELOBJ" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "$PROGRAM: must be root to attach the images" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/relkern.XXXXXX")
MD=""
MNT=""
# Every exit path, including an interrupt: a leaked memory disk or mount holds
# the release objdir open and the next run fails on something unrelated.
cleanup() {
	[ -n "$MNT" ] && umount "$MNT" 2>/dev/null || true
	[ -n "$MD" ] && mdconfig -d -u "$MD" 2>/dev/null || true
	rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
mkdir -p "$WORK/mnt" "$WORK/pkg"

# One artifact's kernel and vmm.ko, recorded by label. A missing kernel is
# recorded as a MISSING line rather than skipped, because an artifact this
# cannot read is not an artifact that agreed.
record() {
	_label=$1; _k=$2; _v=$3
	if [ ! -f "$_k" ]; then
		printf '  %-20s NO KERNEL FOUND at %s\n' "$_label" "$_k"
		echo "MISSING $_label" >> "$WORK/verdicts"
		return
	fi
	_kd=$(sha256 -q "$_k")
	_vd="(absent)"
	[ -f "$_v" ] && _vd=$(sha256 -q "$_v")
	printf '  %-20s kernel=%s  vmm.ko=%s\n' \
	    "$_label" "$(echo "$_kd" | cut -c1-16)" "$(echo "$_vd" | cut -c1-16)"
	printf '  %-20s ident=%s\n' "" \
	    "$(strings -a "$_k" | grep -m1 -E '^FreeBSD [0-9]+\.[0-9]+' | sed 's/:.*//')"
	echo "$_kd $_vd $_label" >> "$WORK/verdicts"
}

echo "== $VERSION: one kernel across every artifact =="

# 1. The kernel PACKAGE -- what a pkg install or upgrade lands.
_kp=$(find "$RELOBJ/pkgbase-repo" -type f \
    -name "${PREFIX}-kernel-generic-${VERSION}.pkg" -print -quit 2>/dev/null) || _kp=""
if [ -n "$_kp" ]; then
	# Guarded, because this script runs under set -e and an unreadable or
	# truncated package would otherwise abort it mid-way -- no RESULT line,
	# and an exit status outside the 0/1 this promises. A caller keying on
	# the words rather than the status would see neither answer.
	if tar -xf "$_kp" -C "$WORK/pkg" 2>/dev/null; then
		record "package" \
		    "$(find "$WORK/pkg" -path '*boot/kernel/kernel' -type f -print -quit)" \
		    "$(find "$WORK/pkg" -name vmm.ko -print -quit)"
	else
		echo "  package             $_kp could not be read"
		echo "MISSING package" >> "$WORK/verdicts"
	fi
else
	echo "  package             NO ${PREFIX}-kernel-generic-${VERSION}.pkg under $RELOBJ/pkgbase-repo"
	echo "MISSING package" >> "$WORK/verdicts"
fi

# 2. The raw VM image -- what someone boots from a downloaded disk.
if [ -f "$RELOBJ/vm.ufs.raw" ]; then
	MD=$(mdconfig -a -t vnode -f "$RELOBJ/vm.ufs.raw" | sed 's/^md//')
	sleep 1
	# The root partition is FOUND, not assumed to be p4. The index depends
	# on how the image was laid out, and a recipe that adds or reorders a
	# partition would turn a perfectly good release into an unexplained
	# mount failure -- a check that cannot run reporting as a fault.
	_part=$(gpart show -p "md${MD}" 2>/dev/null |
	    awk '$4 == "freebsd-ufs" { print $3; exit }') || _part=""
	if [ -z "$_part" ]; then
		echo "  vm.ufs.raw          no freebsd-ufs partition in the image"
		echo "MISSING vm.ufs.raw" >> "$WORK/verdicts"
		mdconfig -d -u "$MD"; MD=""
	elif ! mount -o ro "/dev/$_part" "$WORK/mnt" 2>/dev/null; then
		echo "  vm.ufs.raw          /dev/$_part would not mount"
		echo "MISSING vm.ufs.raw" >> "$WORK/verdicts"
		mdconfig -d -u "$MD"; MD=""
	else
		MNT="$WORK/mnt"
		record "vm.ufs.raw" "$WORK/mnt/boot/kernel/kernel" "$WORK/mnt/boot/kernel/vmm.ko"
		umount "$WORK/mnt"; MNT=""
		mdconfig -d -u "$MD"; MD=""
	fi
else
	echo "  vm.ufs.raw          not built in this run"
fi

# 3. The installer ISO -- what boots when the media is burned. Attached and
# read as cd9660; the medium is decided by what it is, not by its name.
if [ -f "$RELOBJ/disc1.iso" ]; then
	MD=$(mdconfig -a -t vnode -f "$RELOBJ/disc1.iso" | sed 's/^md//')
	if ! mount -t cd9660 -o ro "/dev/md${MD}" "$WORK/mnt" 2>/dev/null; then
		echo "  disc1.iso           would not mount as cd9660"
		echo "MISSING disc1.iso" >> "$WORK/verdicts"
		mdconfig -d -u "$MD"; MD=""
	else
		MNT="$WORK/mnt"
		record "disc1.iso" "$WORK/mnt/boot/kernel/kernel" "$WORK/mnt/boot/kernel/vmm.ko"
		umount "$WORK/mnt"; MNT=""
		mdconfig -d -u "$MD"; MD=""
	fi
else
	echo "  disc1.iso           not built in this run"
fi

echo
[ -s "$WORK/verdicts" ] || {
	echo "RESULT: FAIL -- nothing was examined, which is not a pass"
	exit 1
}
if grep -q '^MISSING' "$WORK/verdicts"; then
	echo "RESULT: FAIL -- an artifact had no kernel to compare"
	exit 1
fi
_n=$(grep -c . "$WORK/verdicts")
_distinct=$(awk '{print $1}' "$WORK/verdicts" | sort -u | grep -c .)
if [ "$_distinct" = 1 ]; then
	echo "RESULT: PASS -- $_n artifacts, ONE kernel"
	exit 0
fi
echo "RESULT: FAIL -- $_distinct distinct kernels across $_n artifacts"
sed 's/^/    /' "$WORK/verdicts"
exit 1
