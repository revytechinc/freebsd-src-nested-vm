#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# build_release_media.sh -- build release media from a committed tree, using
# every core the host has.
#
# Phased with a log per phase: a wide parallel build interleaves its output,
# and a failure buried in one combined log has already cost this project a day.
#
# Nearly every block below removes something a previous run left behind. That
# is not defensiveness: each of those targets reports SUCCESS when it silently
# does nothing, so the failure surfaces phases later, or not at all, in media
# that is a mixture of two builds and looks like one.
#
# This lived for a long time as ~/relbuild-vN.sh on the build host, forked once
# per release because the commit to build was written into it. Eight stale
# copies accumulated that way, and a fix was once applied to the wrong one.
# The commit is an argument here for exactly that reason.
#
# Usage:
#   build_release_media.sh [-c commit] [-r release] [-t tree] <target>
#
#   <target>   real-release (installer media) or vm-release (VM images)
#   -c  commit or ref to build. Default: whatever the tree is already at.
#   -r  release name to record in the provenance file. Default: the tag on
#       HEAD, or "untagged". Every release we cut should have one.
#   -t  source tree to build. Default: the tree this script lives in.
#
# Run it on the build host, from a committed tree. It reads the core count
# from the machine rather than taking it as an argument.
set -eu

PROGRAM="${0##*/}"
COMMIT=""
RELEASE_TAG="${RELEASE_TAG:-}"
TREE=""

while getopts c:r:t: o; do
	case "$o" in
	c)	COMMIT=$OPTARG ;;
	r)	RELEASE_TAG=$OPTARG ;;
	t)	TREE=$OPTARG ;;
	*)	echo "usage: $PROGRAM [-c commit] [-r release] [-t tree] <real-release|vm-release>" >&2
		exit 2 ;;
	esac
done
shift $((OPTIND - 1))

TARGET=${1:-}
case "$TARGET" in
real-release|vm-release)	;;
*)	echo "usage: $PROGRAM [-c commit] [-r release] [-t tree] <real-release|vm-release>" >&2
	exit 2 ;;
esac

# Default to the tree this script is part of, so a checkout builds itself and
# there is no second copy of the source to drift from the one being reviewed.
if [ -z "$TREE" ]; then
	TREE=$(dirname "$0")/../../../../..
fi
# Absolute, and resolved the same way make will resolve it: RELOBJ below is
# MAKEOBJDIRPREFIX with TREE concatenated onto it, so a relative or unresolved
# path aims every cleanup block at a directory that does not exist. They then
# all silently no-op, and the stale-artifact traps this script exists to avoid
# are back, with nothing saying so.
TREE=$(cd "$TREE" && pwd -P) || { echo "$PROGRAM: no such tree" >&2; exit 2; }
[ -d "$TREE/.git" ] || { echo "$PROGRAM: $TREE is not a git checkout" >&2; exit 2; }
[ -f "$TREE/Makefile.inc1" ] || { echo "$PROGRAM: $TREE is not a FreeBSD source tree" >&2; exit 2; }

BRANCH=$(git -C "$TREE" rev-parse --abbrev-ref HEAD)
LOGD=${LOGD:-$TREE/../rel-media-logs}
export MAKEOBJDIRPREFIX=${MAKEOBJDIRPREFIX:-$HOME/obj-relmedia}

# Read the width from the machine; the fleet is not uniform and a literal is
# how half of a 64-core builder sat idle through every previous build.
J=${BUILD_J:-$(sysctl -n hw.ncpu)}

export PKG_NAME_PREFIX=CloudBSD
export PKG_MAINTAINER=nested@cloudbsd.cat
export PKG_WWW=https://nested.cloudbsd.cat
# newvers.sh bakes $USER@$HOSTNAME into uname -v and the loader banner; keep
# any internal hostname out of the media.
STAMP="env USER=cloudbsd HOSTNAME=build"

mkdir -p "$LOGD"
say() { echo "=== $(date '+%H:%M:%S') $*" | tee -a "$LOGD/summary.log"; }
run() {
	_phase=$1; shift
	say "$_phase: starting"
	if "$@" > "$LOGD/$_phase.log" 2>&1; then
		say "$_phase: ok"
	else
		say "$_phase: FAILED -- last 40 lines:"
		tail -40 "$LOGD/$_phase.log" | tee -a "$LOGD/summary.log"
		exit 1
	fi
}

say "target=$TARGET tree=$TREE branch=$BRANCH cores=$J host=$(hostname -s)"

cd "$TREE"
if [ -n "$COMMIT" ]; then
	git checkout -q -f "$COMMIT"
	HAVE=$(git rev-parse --short HEAD); WANT=$(git rev-parse --short "$COMMIT")
	[ "$HAVE" = "$WANT" ] || { say "tree at $HAVE, wanted $WANT"; exit 1; }
fi

# A dirty tree produces media that does not correspond to the commit recorded
# beside it, which is the one thing the provenance file exists to promise.
if [ -n "$(git status --porcelain)" ]; then
	say "tree has uncommitted changes -- media would not match the recorded commit:"
	git status --short | sed 's/^/  /' | tee -a "$LOGD/summary.log"
	[ -n "${ALLOW_DIRTY_TREE:-}" ] || exit 1
	say "ALLOW_DIRTY_TREE set -- continuing, and the provenance file will say so"
fi
say "tree at $(git rev-parse --short HEAD)"

# The media selects base packages by name and the installer selects them again;
# built expecting different names, the failure surfaces on a user's machine.
P_REL=$(cd "$TREE/release" && $STAMP make -V PKG_NAME_PREFIX WORLDDIR="$TREE" 2>/dev/null | tail -1)
P_INS=$(cd "$TREE/usr.sbin/bsdinstall/scripts" && $STAMP make -V PKG_NAME_PREFIX 2>/dev/null | tail -1)
say "prefix: release=[$P_REL] installer=[$P_INS]"
[ -n "$P_REL" ] && [ "$P_REL" = "$P_INS" ] && [ "$P_REL" = "$PKG_NAME_PREFIX" ] || {
	say "prefix inconsistent -- refusing to build media that would fail at install time"
	exit 1
}

run buildworld  $STAMP make -C "$TREE" -j"$J" buildworld
run buildkernel $STAMP make -C "$TREE" -j"$J" buildkernel KERNCONF=GENERIC

# Scoped to this tree's objdir, not to MAKEOBJDIRPREFIX as a whole: the prefix
# is shared between trees, and -t makes a second tree building into it ordinary.
# An unscoped search returns whichever vmm.ko the walk reaches first, which may
# belong to another build entirely -- and that module is both the one gated for
# undefined symbols and the one hashed into the provenance file.
KO=$(find "${MAKEOBJDIRPREFIX}${TREE}" -name vmm.ko -print -quit)
# An empty KO is worse than a missing one: `nm ""` fails, its error is
# discarded, grep matches nothing, and the symbol gate reports a pass it never
# performed.
[ -n "$KO" ] || {
	say "no vmm.ko under ${MAKEOBJDIRPREFIX}${TREE} -- the kernel build produced nothing to check"
	exit 1
}
say "vmm.ko: $KO"
if nm "$KO" 2>/dev/null | grep -q ' U svm_l2'; then
	say "vmm.ko has undefined svm_l2 symbols -- would not load"; exit 1
fi

# `pkgbase-repo' is a DIRECTORY target with no prerequisites, so once the
# directory exists make reports "up to date" and skips the recipe entirely.
# A failed or interrupted run leaves that directory behind with a handful of
# packages in it, and every retry then silently builds nothing and reports
# success -- the media staging is what eventually fails, several phases later,
# on a repository with no catalogue. Remove it so the target actually runs.
RELOBJ="${MAKEOBJDIRPREFIX}${TREE}/amd64.amd64/release"
if [ -d "$RELOBJ/pkgbase-repo" ]; then
	say "removing a stale pkgbase-repo so make does not skip the target"
	rm -rf "$RELOBJ/pkgbase-repo" "$RELOBJ/pkgbase-repo-dir"
fi

# The media staging directories are the same trap one level along: a second run
# fails on `mkdir bootonly-memstick: File exists` because the first run left
# them behind. real-release is not re-runnable against a used objdir unless
# they go.
for _d in disc1 bootonly dvd disc1-disc1 disc1-memstick bootonly-bootonly \
	  bootonly-memstick dvd-dvd; do
	[ -e "$RELOBJ/$_d" ] && rm -rf "$RELOBJ/$_d"
done

# The produced images are the third instance of the same trap. mkimg(1)
# REFUSES an existing output -- "won't overwrite ../mini-memstick.img" --
# rather than replacing it, so a re-run dies partway through the media
# phase on a file the PREVIOUS run made.  Worse, the artifacts rebuilt
# before that point are from this build and the rest are from the last
# one, so what is left in the directory is a mixture of two builds that
# looks like one.
rm -f "$RELOBJ"/*.iso "$RELOBJ"/*.img "$RELOBJ"/*.xz \
      "$RELOBJ"/vm.*.raw "$RELOBJ"/vm.*.qcow2 \
      "$RELOBJ"/vm.*.vhd "$RELOBJ"/vm.*.vmdk 2>/dev/null || true

# The vm-image target ends `mk-vmimage.sh ... || true` followed by
# `touch ${.TARGET}`, so a FAILED image build still marks itself complete.
# Make then skips it on every retry: vm-release reports ok in one second and
# produces nothing. Remove the marker and the partial image trees so a re-run
# actually re-runs.
for _m in vm-image vm-image.meta; do
	[ -e "$RELOBJ/$_m" ] && rm -f "$RELOBJ/$_m"
done
rm -rf "$RELOBJ"/vm-image-* 2>/dev/null

# Package creation is memory-bound, not CPU-bound: each `pkg create` holds
# roughly 2.7GB, so -j64 asks for ~170GB on a 127GB machine. The parent gets
# killed, the pkg children are orphaned and keep running, and the build stops
# mid-package with no OOM line to explain it. Cap this phase by memory rather
# than by core count.
PHYSG=$(( $(sysctl -n hw.physmem) / 1073741824 ))
PKGJ=$(( PHYSG / 5 ))
[ "$PKGJ" -gt "$J" ] && PKGJ=$J
[ "$PKGJ" -lt 4 ] && PKGJ=4
say "pkgbase-repo: -j$PKGJ (memory-bound: ~2.7GB per pkg process, so a fifth of RAM on ${PHYSG}G)"

run pkgbase-repo $STAMP make -C "$TREE/release" -j"$PKGJ" pkgbase-repo \
	WORLDDIR="$TREE" NOPORTS=1

# Prove the repo is usable rather than trusting make's exit status: the
# staging step needs a `latest' symlink and a catalogue, and their absence is
# what turned a silent skip into a failure four phases downstream.
REPO="$RELOBJ/pkgbase-repo"
ABI=$(ls "$REPO" 2>/dev/null | head -1)
if [ ! -L "$REPO/$ABI/latest" ]; then
	say "pkgbase-repo has no 'latest' symlink -- the media cannot install from it"
	ls -la "$REPO/$ABI" 2>/dev/null | head -5 | tee -a "$LOGD/summary.log"
	exit 1
fi
NPKG=$(ls "$REPO/$ABI/latest"/*.pkg 2>/dev/null | wc -l | tr -d " ")
say "pkgbase-repo: $NPKG packages, latest -> $(readlink "$REPO/$ABI/latest")"
if [ "${NPKG:-0}" -lt 100 ]; then
	say "only $NPKG packages -- expected the full base set; refusing to build media"
	exit 1
fi

# pkg(8) refuses a repository whose files are not owned by the user
# running it.  Root-created files under a user home inherit that
# user's group (BSD semantics), so the repo comes out 0/1001 where
# pkg wants 0/0.  The refusal surfaces inside pkgbase-stage.lua during
# disc1, long after the packages were built, and reads as a pkg fault
# rather than an ownership one.
# Every pkg-owned scratch directory here is recreated by the build, and
# pkg refuses to use one whose files belong to a different user than the
# one running it.  A tree that has been built by both mlapointe and root
# therefore fails deep inside pkgbase-stage.lua during disc1, naming an
# ownership mismatch with no hint of which path or which build left it.
# Delete them rather than chase their ownership: they cost seconds to
# rebuild and carry nothing worth keeping.
rm -rf "$RELOBJ"/pkgdb-* "$RELOBJ"/pkgbase-repo-dir

case "$TARGET" in
# NO_ROOT and WITHOUT_QEMU are a pair, and Makefile.vm enforces it with an
# .error.  release.sh always sets both; invoking vm-release directly sets
# neither, and then etcupdate(8) -N adds -DNO_ROOT partway down the tree
# walk on its own.  usr.sbin/pkg then queries $(MAKE) -C release -V BRANCH,
# that sub-make sees NO_ROOT without WITHOUT_QEMU, and the whole release
# dies in installconfig for a reason that has nothing to do with pkg.
vm-release)
	run "$TARGET" $STAMP make -C "$TREE/release" -j"$J" "$TARGET" \
		WORLDDIR="$TREE" NOPORTS=1 WITH_VMIMAGES=yes \
		NO_ROOT=1 WITHOUT_QEMU=1 ;;
*)
	run "$TARGET" $STAMP make -C "$TREE/release" -j"$J" "$TARGET" \
		WORLDDIR="$TREE" NOPORTS=1 ;;
esac

# Provenance, beside the artifacts.  Media whose source and module are not
# recorded is unusable the moment the code moves, and the code will move.
KOSHA=$(sha256 -q "$KO" 2>/dev/null || sha256sum "$KO" | cut -d' ' -f1)
{
	echo "release:     ${RELEASE_TAG:-$(git -C "$TREE" describe --tags --exact-match HEAD 2>/dev/null || echo untagged)}"
	echo "commit:      $(git -C "$TREE" rev-parse HEAD)$([ -n "$(git -C "$TREE" status --porcelain)" ] && echo ' (DIRTY TREE)')"
	echo "branch:      $BRANCH"
	echo "vmm.ko:      $KOSHA"
	echo "prefix:      $PKG_NAME_PREFIX"
	echo "target:      $TARGET"
	echo "built:       $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "cores:       $J"
	echo "host-class:  $(sysctl -n hw.model)"
} > "$LOGD/build-identity.txt"
say "build identity:"
sed 's/^/  /' "$LOGD/build-identity.txt" | tee -a "$LOGD/summary.log"

say "artifacts:"
find "${MAKEOBJDIRPREFIX}${TREE}" \( -name '*.iso' -o -name '*.img' -o -name '*.qcow2' \
	-o -name '*.vhd' -o -name '*.vmdk' \) 2>/dev/null |
	while read -r f; do printf '  %8s  %s\n' "$(du -h "$f" | cut -f1)" "$f"; done |
	tee -a "$LOGD/summary.log"
say "DONE $TARGET"
