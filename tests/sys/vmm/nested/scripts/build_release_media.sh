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
# Absolute, resolved BEFORE the cd below. `dirname "$0"` evaluated after
# `cd "$TREE"` points somewhere else entirely for any relative invocation, and
# the run then aborts saying it cannot find its own helper -- after the
# multi-hour build has already completed.
SCRIPTDIR=$(cd "$(dirname "$0")" && pwd -P)
# Verified now, not at the end. The package set is checked by a helper beside
# this script; if it is missing, finding out AFTER the world and the packages
# are built loses the whole run for a condition that takes a millisecond to
# test. Same argument as every other preflight here.
CONTRACT="$SCRIPTDIR/check_release_contract.sh"
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
# `git rev-parse`, not `[ -d "$TREE/.git" ]`: in a git WORKTREE the .git entry
# is a FILE containing a gitdir: pointer, not a directory. Every tree this
# project builds from is a worktree, so the directory test refuses all of them.
git -C "$TREE" rev-parse --git-dir >/dev/null 2>&1 || {
	echo "$PROGRAM: $TREE is not a git checkout" >&2; exit 2; }
[ -f "$TREE/Makefile.inc1" ] || { echo "$PROGRAM: $TREE is not a FreeBSD source tree" >&2; exit 2; }

BRANCH=$(git -C "$TREE" rev-parse --abbrev-ref HEAD)
LOGD=${LOGD:-$TREE/../rel-media-logs}
export MAKEOBJDIRPREFIX=${MAKEOBJDIRPREFIX:-$HOME/obj-relmedia}

# Read the width from the machine; the fleet is not uniform and a literal is
# how half of a 64-core builder sat idle through every previous build.
# Portable core count. `sysctl -n hw.ncpu` is FreeBSD and macOS; `nproc` is
# Linux. Failing loudly beats defaulting to 1, which turns a 2.7-hour build into
# an overnight one with nothing saying why.
_numeric() {
	case "$1" in
	''|*[!0-9]*)	return 1 ;;
	*)		printf '%s\n' "$1"; return 0 ;;
	esac
}
ncpu() {
	# Each probe judged by the VALUE it printed, not by its exit status: some
	# builds of these tools print a usable number while returning non-zero, and
	# others exit 0 having printed nothing.
	_v=$(sysctl -n hw.ncpu 2>/dev/null) || _v=""
	_numeric "$_v" && return 0
	_v=$(nproc 2>/dev/null) || _v=""
	_numeric "$_v" && return 0
	_v=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || _v=""
	_numeric "$_v" && return 0
	return 1
}
# Tested by value, not by status: `J=$(...)` is an assignment and an assignment
# always succeeds, so a `||` clause on it never fires however badly the
# substitution failed.
J=${BUILD_J:-$(ncpu)}
[ -n "$J" ] || { echo "$PROGRAM: cannot determine the core count; set BUILD_J" >&2; exit 2; }

export PKG_NAME_PREFIX=CloudBSD
export PKG_MAINTAINER=nested@cloudbsd.cat
export PKG_WWW=https://nested.cloudbsd.cat
# newvers.sh bakes $USER@$HOSTNAME into uname -v and the loader banner; keep
# any internal hostname out of the media.
#
# WITH_REPRODUCIBLE_PATHS is NOT a default. REPRODUCIBLE_PATHS is listed under
# __DEFAULT_NO_OPTIONS in share/mk/bsd.opts.mk, so without this every module
# this builds carries the absolute path of the build tree -- the builder's home
# directory -- in its debug and assertion strings, and ships it to everyone who
# downloads the media. Removing that is the entire reason the release this was
# written for exists, and it would have been undone here by omission.
#
# It is asserted after buildkernel rather than trusted, because the failure is
# invisible: the build succeeds, the module loads, and only `strings` says the
# path is still there.
STAMP_USER=cloudbsd
STAMP_HOST=build

# PKG_VERSION is what every package in the repository is NAMED, and without it
# the packages come out called after a FreeBSD snapshot rather than after this
# release.
#
# Makefile.inc1 sets it only `.if !defined(PKG_VERSION)`, and its default for a
# CURRENT branch is "16.snap<timestamp>". So a build that does not pass it
# produces CloudBSD-bhyve-16.snap20260909121429 where every published release
# so far is CloudBSD-bhyve-16.0.20260908.deepnest13 -- 524 of them, none
# carrying "snap". That is not cosmetic: pkg decides whether an installed
# machine is out of date by comparing those strings, so publishing the snapshot
# form puts the upgrade path in the hands of a version comparison nobody
# intended.
#
# -r already names the release. It is the same fact, so it is not asked for
# twice: the version is derived from it and the revision the tree declares.
# PKG_VERSION from the environment still wins, for a build that needs to say
# something else.
if [ -z "${PKG_VERSION:-}" ]; then
	_rev=$(awk -F'"' '/^REVISION=/{print $2}' "$TREE/sys/conf/newvers.sh")
	[ -n "$_rev" ] || { echo "$PROGRAM: cannot read REVISION from newvers.sh" >&2; exit 1; }
	_rel=${RELEASE_TAG:-untagged}
	case "$_rel" in
	*[!0-9A-Za-z._-]*|"")
		echo "$PROGRAM: -r may only contain [0-9A-Za-z._-]: $_rel" >&2; exit 2 ;;
	esac
	PKG_VERSION="${_rev}.$(date -u +%Y%m%d).${_rel}"
fi
# Validated whatever its source. It is not only derived here -- the environment
# can supply it -- and it ends up in a package filename, in an `env` argument
# list, and in a pattern used to check those filenames. Every one of those
# treats a space, a quote or a regex metacharacter as something other than text.
case "$PKG_VERSION" in
""|*[!0-9A-Za-z._-]*)
	echo "$PROGRAM: PKG_VERSION may only contain [0-9A-Za-z._-]: $PKG_VERSION" >&2
	exit 2 ;;
esac
export PKG_VERSION

# PKG_VERSION is exported above, so `env` need not carry it as an unquoted word
# in a string that later gets split. The other two are fixed literals.
STAMP="env USER=$STAMP_USER HOSTNAME=$STAMP_HOST WITH_REPRODUCIBLE_PATHS=yes"

mkdir -p "$LOGD"
say() { echo "=== $(date '+%H:%M:%S') $*" | tee -a "$LOGD/summary.log"; }
run() {
	_phase=$1; shift
	CURRENT_PHASE=$_phase
	say "$_phase: starting"
	# Only external commands are ever passed here. Do not pass a shell function:
	# backgrounding runs it in a child, so any variable it sets is lost to this
	# shell and surfaces much later as an empty path.
	"$@" > "$LOGD/$_phase.log" 2>&1 &
	CURRENT_CHILD=$!
	if wait "$CURRENT_CHILD"; then
		CURRENT_CHILD=
		# Cleared on success. Left set, an interrupt arriving between phases
		# reports the phase that already finished -- and if that was
		# buildworld, on_failure treats the interrupt as a SOURCE failure and
		# keeps the staging tier, which is the state the trap exists to remove.
		CURRENT_PHASE="after-$_phase"
		say "$_phase: ok"
	else
		CURRENT_CHILD=
		say "$_phase: FAILED -- last 40 lines:"
		tail -40 "$LOGD/$_phase.log" | tee -a "$LOGD/summary.log"
		on_failure "$_phase"
		exit 1
	fi
}

# Which failures are the source's fault, and which are ours.
#
# A compile error means the code is wrong. Its object directory is the
# expensive, still-valid part -- 83k .meta files that are the difference
# between a ten-minute retry and a three-hour one -- and it is KEPT.
#
# Everything after that produces staging state, and staging state left behind
# is what makes the NEXT run lie: pkgbase-repo is a directory target with no
# prerequisites, so make sees the directory, skips the recipe and reports
# success. That is not cleaned file by file. It is removed as a unit, because
# surgery on it buys minutes and reintroduces the exact class it exists to
# prevent.
#
# Two things this deliberately never touches: MAKEOBJDIRPREFIX above $RELOBJ,
# and anything outside the tree being built.
SOURCE_PHASES="buildworld buildkernel"

is_source_phase() {
	for _p in $SOURCE_PHASES; do
		[ "$1" = "$_p" ] && return 0
	done
	return 1
}

# Evidence FIRST, always. The partial repository, the half-written images and
# the stage directories are the proof of what went wrong; cleaning first and
# reporting after is how a failure becomes unreproducible.
capture_evidence() {
	_phase=$1
	_dir="$LOGD/issues/$(date -u +%Y%m%dT%H%M%SZ)-$_phase"
	mkdir -p "$_dir" || return 0
	# `after-<phase>` is a position, not a phase, so its log is named for the
	# phase that produced it. Without this an interrupt between phases captures
	# no log at all.
	_logname=${_phase#after-}
	[ -f "$LOGD/$_logname.log" ] && tail -500 "$LOGD/$_logname.log" > "$_dir/phase.log"
	[ -f "$LOGD/build-identity.txt" ] && cp "$LOGD/build-identity.txt" "$_dir/" 2>/dev/null
	# Every expansion guarded. This runs from a trap, and the trap is armed
	# before some of these are assigned -- under `set -u` an unbound variable
	# aborts the handler, so an early Ctrl-C would capture nothing AND skip the
	# cleanup, which is the debris the trap exists to remove.
	{
		echo "phase:    $_phase"
		echo "target:   ${TARGET:-<unset>}"
		echo "tree:     ${TREE:-<unset>}"
		echo "commit:   $(git -C "${TREE:-.}" rev-parse HEAD 2>/dev/null)"
		echo "dirty:    $(git -C "${TREE:-.}" status --porcelain 2>/dev/null | wc -l | tr -d ' ') path(s)"
		echo "objdir:   ${MAKEOBJDIRPREFIX:-<unset>}"
		echo "relobj:   ${RELOBJ:-<not reached>}"
		echo "when:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "host:     $(hostname -s)"
		echo "source_failure: $(is_source_phase "$_phase" && echo yes || echo no)"
	} > "$_dir/issue.txt" 2>/dev/null || say "could not write the evidence file; continuing to clean up"
	# What the staging tier looked like at the moment it failed -- a listing is
	# small and answers "how far did it get" without keeping gigabytes.
	if [ -n "${RELOBJ:-}" ] && [ -d "$RELOBJ" ]; then
		ls -la "$RELOBJ" > "$_dir/relobj.listing" 2>/dev/null
		# Deep enough to reach pkgbase-repo/<ABI>/<version>/*.pkg. This count is
		# the signal that says "it exited 0 with four packages", so a depth that
		# stops short records 0 and throws away the whole point.
		# BSD wc pads its output; the count is read by eye and by grep, and
		# "packages_at_failure:        4" is worse at both than "4".
		echo "packages_at_failure: $(find "$RELOBJ" -maxdepth 5 -name '*.pkg' \
		    2>/dev/null | wc -l | tr -d ' ')" >> "$_dir/issue.txt"
	fi
	say "evidence: $_dir"
}

# The staging tier, removed as a unit. Never $MAKEOBJDIRPREFIX itself.
clean_stage() {
	[ -n "${RELOBJ:-}" ] || return 0
	[ -d "$RELOBJ" ] || return 0
	[ -n "${MAKEOBJDIRPREFIX:-}" ] && [ -n "${TREE:-}" ] || {
		say "refusing to clean: the objdir or tree is not set"
		return 0
	}
	# Refuse to run on anything that is not the release directory under the
	# objdir we were given. An empty or unexpected value reaching rm -rf is
	# how a deploy script once deleted a webroot.
	#
	# Both sides are resolved before comparing. A textual match against
	# "${MAKEOBJDIRPREFIX}${TREE}" compares SPELLINGS, so a trailing slash, a
	# symlinked tree, or a path containing .. makes it stop matching -- and the
	# failure is silent: it prints "refusing", returns 0, and the run carries on
	# believing the staging tier was removed when it was not.
	_expect=$(cd "${MAKEOBJDIRPREFIX}${TREE}" 2>/dev/null && pwd -P) || _expect=""
	_actual=$(cd "$RELOBJ" 2>/dev/null && pwd -P) || _actual=""
	if [ -z "$_expect" ] || [ -z "$_actual" ]; then
		# Not cleaning is the safe choice, but it must not read as cleaned.
		# The staging tier survives, so the NEXT run would meet a directory
		# target that already exists, skip it and report success. Say so loudly
		# enough that the next run's preflight is expected to refuse.
		say "WARNING: could not resolve the staging path, so it was NOT removed."
		say "WARNING: $RELOBJ may still exist. The next build must refuse it as stale."
		return 0
	fi
	# Recomputed, not glob-matched: `*` in a case pattern matches slashes too,
	# so "$_expect"/*/release accepted any release directory arbitrarily deep
	# under the objdir, and rm -rf'd it.
	_want=""
	for _cand in "${MAKEOBJDIRPREFIX}${TREE}/${TARGET_ARCH:-amd64}.${TARGET_ARCH:-amd64}/release" \
	             "${MAKEOBJDIRPREFIX}${TREE}/amd64.amd64/release" \
	             "${MAKEOBJDIRPREFIX}${TREE}/release"; do
		_r=$(cd "$_cand" 2>/dev/null && pwd -P) || continue
		[ "$_r" = "$_actual" ] && { _want=$_r; break; }
	done
	if [ -z "$_want" ]; then
		say "WARNING: the staging path is not one this script builds into, so it was"
		say "WARNING: NOT removed. found: $_actual"
		say "WARNING: it may still exist. The next build must refuse it as stale."
		return 0
	fi
	say "removing the staging tier as a unit: $RELOBJ"
	rm -rf "$RELOBJ"
}

on_failure() {
	_phase=$1
	capture_evidence "$_phase"
	if is_source_phase "$_phase"; then
		say "$_phase is a source failure -- the object directory is kept, it is still valid"
		return 0
	fi
	clean_stage
}

# Interrupted is not a verdict, but it leaves the same staging debris a failure
# does -- and the next run would then skip a target and report success. Capture
# and clean on the way out, exactly as for a failure.
# Disarmed on entry, so a second Ctrl-C during capture_evidence -- which walks
# a large object tree and can take seconds -- cannot re-enter and start a second
# rm -rf beside the first.
# Stop and reap the running phase before anything is removed. SIGINT rather
# than SIGKILL: bmake runs its own interrupt handling, and a killed mkimg, xz or
# pkg create leaves a truncated target with a fresh mtime that make then treats
# as done.
stop_child() {
	[ -n "${CURRENT_CHILD:-}" ] || return 0
	# SIGINT to the phase process. `set -m` was tried here to make it a process
	# group leader so the whole group could be signalled, and it is the wrong
	# tool: job control needs a controlling terminal, so under daemon(8) -- which
	# is how the build service will run this -- it prints "can't access tty" and
	# turns itself off, leaving the group approach silently inoperative.
	#
	# Signalling the direct child is sufficient in practice because bmake
	# installs its own SIGINT handler and terminates its job processes before
	# exiting. What makes that safe is the bounded wait below: nothing is
	# removed until the phase has actually gone.
	kill -INT "$CURRENT_CHILD" 2>/dev/null || true
	# `wait` alone is not enough -- it can return immediately if the job was
	# already reaped when the trap interrupted it, and returning then would start
	# rm -rf beside a live writer. Poll until the process is really gone.
	_w=0
	while kill -0 "$CURRENT_CHILD" 2>/dev/null && [ "$_w" -lt 60 ]; do
		sleep 1
		_w=$((_w + 1))
	done
	[ "$_w" -lt 60 ] || say "the phase did not stop within 60s; not removing anything"
	CURRENT_CHILD=''
	[ "$_w" -lt 60 ]
}

# If the phase will not stop, nothing is removed: a partly-removed tree with a
# live writer in it is worse than a stale one, because the next run cannot tell
# what it is looking at.
trap 'trap - INT TERM; say "interrupted"; if stop_child; then on_failure "${CURRENT_PHASE:-interrupted}"; else capture_evidence "${CURRENT_PHASE:-interrupted}"; fi; exit 130' INT TERM

[ -x "$CONTRACT" ] || {
	echo "$PROGRAM: $CONTRACT is missing or not executable." >&2
	echo "$PROGRAM: it decides whether the built repository is publishable, so a" >&2
	echo "$PROGRAM: build without it would produce media nothing had checked." >&2
	exit 2
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

# The object directory has to be writable BY THIS USER, all of it.
#
# This build runs unprivileged. build_packages.sh runs under doas and shares
# this object directory, so it leaves root-owned files behind -- 75 of them,
# the last time -- and the next unprivileged build dies partway through
# buildworld with:
#
#   error: unable to open output file 'vmmapi_machdep.o': 'Operation not permitted'
#
# which reads as a compiler problem and is a permissions problem. Finding the
# first offending file takes milliseconds; discovering it through a failed
# buildworld takes as long as the build got. `doas chown -R` on the object
# directory is the fix, and the message says so rather than making somebody
# work it out twice.
_me=$(id -un)
_notmine=$(find "$MAKEOBJDIRPREFIX" ! -user "$_me" -print 2>/dev/null | head -1)
if [ -n "$_notmine" ]; then
	_n=$(find "$MAKEOBJDIRPREFIX" ! -user "$_me" 2>/dev/null | grep -c .) || _n="?"
	say "$_n file(s) under $MAKEOBJDIRPREFIX are not owned by $_me, e.g."
	say "    $_notmine"
	say "This build is unprivileged and would fail partway through buildworld"
	say "with 'unable to open output file ... Operation not permitted'."
	say "Fix: doas chown -R $_me $MAKEOBJDIRPREFIX"
	exit 1
fi

run buildworld  $STAMP make -C "$TREE" -j"$J" buildworld
run buildkernel $STAMP make -C "$TREE" -j"$J" buildkernel KERNCONF=GENERIC

# Scoped to this tree's objdir, not to MAKEOBJDIRPREFIX as a whole: the prefix
# is shared between trees, and -t makes a second tree building into it ordinary.
# An unscoped search returns whichever vmm.ko the walk reaches first, which may
# belong to another build entirely -- and that module is both the one gated for
# undefined symbols and the one hashed into the provenance file.
KERNCONF_DIR_NAME=GENERIC
# Find the KERNEL BUILD directory first, then the module inside it.
#
# Searching for vmm.ko across the objdir and taking the first hit picks
# whichever the directory walk reaches first, and there is more than one: a
# previous release run leaves a staged copy under kernelstage/kernel/boot/
# kernel/vmm.ko, which has no GENERIC ancestor at all. The walk-upwards that
# followed then could not find the kernel directory -- correctly, because it
# had been handed the wrong module.
#
# The build directory is the right scope: it holds every module this build
# produced, where the stage holds a subset that has already been copied.
_kdir=$(find "${MAKEOBJDIRPREFIX}${TREE}" -type d -path "*/sys/$KERNCONF_DIR_NAME" -print -quit)
if [ -z "$_kdir" ] || [ ! -d "$_kdir" ]; then
	say "no sys/$KERNCONF_DIR_NAME kernel build directory under ${MAKEOBJDIRPREFIX}${TREE}."
	say "The path check cannot run, and a check that cannot run is not a pass."
	exit 1
fi
KO=$(find "$_kdir" -name vmm.ko -print -quit)
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

# The build tree's path must not survive into the module.
#
# WITH_REPRODUCIBLE_PATHS rewrites it to /usr/src via -ffile-prefix-map. Both
# halves are checked: absence of the real path says the option took effect, and
# presence of /usr/src says the rewrite happened rather than the strings simply
# being absent from a module built some other way. Checking only the first
# would pass for a vmm.ko that carried no path strings at all.
# Checked across the KERNEL AND EVERY MODULE, not just vmm.ko. The option is
# set for the whole build, so the interesting failure is the partial one -- a
# subdirectory that overrides the flag -- and a gate that looks at one module
# reports success for it.
#
# Scoped to the shipped artifacts: the kernel binary and *.ko. The rest of the
# objdir legitimately contains absolute paths -- .meta files record them by
# design -- so scanning the directory wholesale would fail every build.
# $_kdir was established above, before vmm.ko was looked for inside it.
if [ ! -f "$_kdir/kernel" ]; then
	say "no kernel binary at $_kdir/kernel -- the path check would examine"
	say "modules only and report a pass for a kernel it never looked at."
	exit 1
fi
# xargs, not a loop calling grep per file. 880 artefacts is 880 forks that way
# and the scan takes minutes; batched it is under a second, which is the
# difference between a gate that runs every build and one that gets removed.
# Count what will be scanned BEFORE scanning, and refuse an implausible
# number. An empty find produces an empty leaker list, which is
# indistinguishable from a clean build: the gate would report a pass having
# examined nothing. A GENERIC kernel build has hundreds of modules.
_nchecked=$(find "$_kdir" -name '*.ko' -type f 2>/dev/null | grep -c .) || _nchecked=0
if [ "$_nchecked" -lt 50 ]; then
	say "only $_nchecked modules found under $_kdir -- a GENERIC build has"
	say "hundreds. The scan would pass by looking at almost nothing. Refusing."
	exit 1
fi
# `|| _leakers=""` is not decoration. grep exits 1 when it matches nothing,
# xargs turns that into 123, and under `set -e` the failed assignment ends the
# script instantly and SILENTLY -- no message, no phase log, no evidence
# directory. So the gate aborted the build precisely when it had nothing to
# report, which is to say on every clean build. It did exactly that here: the
# run stopped dead after printing the vmm.ko path and left eight lines of log.
_leakers=$(find "$_kdir" -name '*.ko' -type f -print0 2>/dev/null |
    xargs -0 grep -al -- "$TREE" 2>/dev/null) || _leakers=""
_nleak=$(printf '%s' "$_leakers" | grep -c . 2>/dev/null) || _nleak=0
if [ "$_nleak" -ne 0 ]; then
	say "$_nleak module(s) carry the build tree path $TREE:"
	printf '%s\n' "$_leakers" | head -10 | sed 's/^/    /' | tee -a "$LOGD/summary.log"
	say "WITH_REPRODUCIBLE_PATHS did not take effect everywhere, and this media"
	say "would publish the builder's directory layout to everyone who downloads it."
	exit 1
fi

# The kernel binary is checked separately, because it has one known and
# DIFFERENT leak that -ffile-prefix-map does not address.
#
# newvers.sh writes "${user}@${host}:${objdir}" into the version string, so
# `uname -v` on every installed machine names the build directory. That is the
# OBJDIR, not a source path, and the option that removes it is
# WITH_REPRODUCIBLE_BUILD -- which also drops the "#N" build number that
# bench_guest.sh parses for its label and that the install page tells people to
# look for. Turning it on is therefore a decision with consequences outside
# this script, and it is not made here.
#
# What this does is refuse to let it hide: exactly one match, and only the
# version string, is reported and allowed. Anything else is a real leak.
_kbin="$_kdir/kernel"
if [ -f "$_kbin" ]; then
	_khits=$(strings "$_kbin" 2>/dev/null | grep -- "$TREE") || _khits=""
	_nk=$(printf '%s' "$_khits" | grep -c . 2>/dev/null) || _nk=0
	# The EXACT prefix newvers.sh writes, built from the same USER and
	# HOSTNAME the STAMP sets -- not a generic word@word: pattern, which any
	# other string carrying the build path could satisfy and thereby have a
	# real leak downgraded to an advisory.
	_kvers=$(printf '%s' "$_khits" |
	    grep -c "^[[:space:]]*${STAMP_USER}@${STAMP_HOST}:") || _kvers=0
	if [ "$_nk" -gt 0 ] && [ "$_nk" -eq "$_kvers" ]; then
		say "kernel: the only build-path string is newvers.sh's version line,"
		say "        which WITH_REPRODUCIBLE_PATHS does not cover. uname -v will"
		say "        name the object directory. Set WITH_REPRODUCIBLE_BUILD to"
		say "        remove it -- see the note above for what else that changes."
	elif [ "$_nk" -gt 0 ]; then
		say "kernel carries $_nk build-path string(s), $((_nk - _kvers)) of them"
		say "outside newvers.sh's version line:"
		printf '%s\n' "$_khits" | head -5 | sed 's/^/    /' | tee -a "$LOGD/summary.log"
		exit 1
	fi
fi

# And the other half: /usr/src must actually be present in vmm.ko. Absence of
# the real path alone would also be satisfied by a module carrying no path
# strings at all, which proves nothing about the rewrite.
_mapped=$(strings "$KO" 2>/dev/null | grep -c -- /usr/src) || _mapped=0
if [ "$_mapped" -eq 0 ]; then
	say "vmm.ko carries neither $TREE nor /usr/src in any string."
	say "That is not the reproducible-paths rewrite working -- it is a module"
	say "with no path strings at all, so this check proved nothing. Refusing."
	exit 1
fi
say "paths: $_nchecked modules checked, none carry $TREE; vmm.ko has $_mapped rewritten to /usr/src"

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

say "package version: $PKG_VERSION"
run pkgbase-repo $STAMP make -C "$TREE/release" -j"$PKGJ" pkgbase-repo \
	WORLDDIR="$TREE" NOPORTS=1

# The packages must actually be NAMED after this release.
#
# `make` exiting zero says the recipe ran, not that it produced what was asked
# for. PKG_VERSION reaching the build is one variable away from not reaching
# it, and the symptom is a repository full of correctly built packages with the
# wrong name -- which publishes perfectly and breaks the upgrade path, because
# pkg decides what is out of date by comparing those strings.
_pkgs=$(find "$RELOBJ/pkgbase-repo" -name '*.pkg' 2>/dev/null) || _pkgs=""
_npkg=$(printf '%s' "$_pkgs" | grep -c .) || _npkg=0
if [ "$_npkg" -lt 100 ]; then
	say "pkgbase-repo produced $_npkg packages. A release carries hundreds."
	say "make reported success; the target did not do its work."
	exit 1
fi
# A `case` glob, not a grep pattern. PKG_VERSION interpolated into a regex
# makes its dots match any character -- and a less friendly value could match
# everything, so a repository with entirely wrong names would pass. `case`
# compares text, and the loop runs in this shell rather than forking per file.
_wrong=$(printf '%s\n' "$_pkgs" | sed 's|.*/||' | while read -r _b; do
	[ -n "$_b" ] || continue
	case "$_b" in
	data.pkg|packagesite.pkg|filesite.pkg|meta.pkg) continue ;;
	*"-$PKG_VERSION.pkg") continue ;;
	*) echo "$_b" ;;
	esac
done)
_nwrong=$(printf '%s' "$_wrong" | grep -c .) || _nwrong=0
if [ "$_nwrong" -ne 0 ]; then
	say "$_nwrong of $_npkg packages are not named for $PKG_VERSION, e.g."
	printf '%s\n' "$_wrong" | head -5 | sed 's/^/    /' | tee -a "$LOGD/summary.log"
	say "PKG_VERSION did not reach the package build. Publishing these would"
	say "put the upgrade path in the hands of a version string nobody chose."
	exit 1
fi
say "packages: $_npkg, all named $PKG_VERSION"

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
# A count is not the contract. A floor of 100 catches the four-package case and
# misses 526 of 527 with CloudBSD-bhyve absent, which installs a kernel with no
# hypervisor and is far likelier. check_release_contract.sh compares the set.
# No `else` here. The preflight at the top of this script already exits when
# $CONTRACT is missing or not executable, so a fallback branch would be
# unreachable -- and an unreachable fallback reads as a supported path that
# somebody will later rely on.
if [ -x "$CONTRACT" ]; then
	# NOT piped into tee. `cmd | tee` reports tee's status, and tee succeeds
	# whenever it can write -- so a repository that FAILS the contract would
	# fall straight through and go on to build media from it. That is precisely
	# the failure this check replaced a package count to catch, reintroduced by
	# the plumbing. Capture the status, then show the output.
	# Run it as an `if` CONDITION, not as a bare command whose status is read
	# afterwards. This script is `set -e`: a bare failing command exits
	# immediately, so `_cc=$?` never runs and neither does the evidence capture
	# or the cleanup below -- the build would abort with nothing recorded about
	# why. A condition is the one context where set -e stands down.
	_cc_out="$LOGD/contract.out"
	if [ -n "${RELEASE_BASELINE_REPO:-}" ]; then
		if sh "$CONTRACT" -r "$REPO/$ABI" -b "$RELEASE_BASELINE_REPO" \
		    > "$_cc_out" 2>&1; then _cc=0; else _cc=1; fi
	else
		if sh "$CONTRACT" -r "$REPO/$ABI" > "$_cc_out" 2>&1; then
			_cc=0
		else
			_cc=1
		fi
	fi
	cat "$_cc_out" | tee -a "$LOGD/summary.log"
	if [ "$_cc" -ne 0 ]; then
		say "the built repository does not satisfy the release contract"
		on_failure pkgbase-repo
		exit 1
	fi
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

# The README that ships beside the images. It was hand-written for the first
# release and then hand-edited for each one after, which is how it came to
# describe the media as a CloudBSD release -- it is an experimental FreeBSD
# build for one feature, and CloudBSD is only the package-name prefix. Nothing
# generated it, so nothing kept it true either.
#
# The warning is not boilerplate: this is unaudited kernel code that can take
# a host down, and someone who downloads an image without reading the site has
# only this file to tell them so.
# Without this the sed below writes nothing, and the file whose entire job is
# to say which kernel these images carry ships with an empty identity section.
[ -s "$LOGD/build-identity.txt" ] || {
	say "no build identity to put in the README -- refusing to ship media that does not say what it is"
	exit 1
}
README="$RELOBJ/README.txt"
{
	echo "Experimental FreeBSD media — bhyve nested virtualization"
	echo
	echo "EXPERIMENTAL. This carries brand-new bhyve nested-virtualization"
	echo "kernel code. It has NOT been security audited and has NOT been"
	echo "production hardened. It can panic or destabilise the host. Do not"
	echo "install it on production equipment or any machine whose data you"
	echo "care about. Use throwaway or test hardware only."
	echo
	echo "Build identity"
	echo "--------------"
	sed 's/^/  /' "$LOGD/build-identity.txt"
	echo
	echo "Artifacts"
	echo "---------"
	# RELOBJ, not the objdir prefix: these are the files that ship, and they
	# sit beside this README. stat(1) is the FreeBSD one -- so is mkimg, sysctl
	# and everything else here, and a GNU fallback would be worse than none:
	# `stat -f' on GNU coreutils means filesystem status, succeeds, and prints
	# text where a byte count belongs.
	find "$RELOBJ" -maxdepth 1 \( -name '*.iso' -o -name '*.img' \
		-o -name '*.qcow2' -o -name '*.vhd' -o -name '*.vmdk' \
		-o -name '*.xz' \) 2>/dev/null | sort |
		while read -r f; do
			printf '  %-45s %12d\n' "${f##*/}" "$(stat -f %z "$f")"
		done
} > "$README"
say "README: $README"

say "DONE $TARGET"
