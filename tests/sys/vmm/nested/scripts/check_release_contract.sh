#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# check_release_contract.sh -- decide whether a build that says it succeeded
# actually produced a release.
#
# `make` exiting 0 is not the claim we care about. A release build once exited 0
# having produced FOUR packages instead of the full base set: `pkgbase-repo` is
# a directory target with no prerequisites, a previous failed run had left the
# directory behind, and make skipped the recipe because its output already
# existed. Nothing in the build noticed. The failure surfaced later, somewhere
# else, as media that could not install.
#
# A count does not catch this either, and that is the point worth being precise
# about. A floor of 100 would have caught 4. It would NOT catch 526 of 527 with
# CloudBSD-bhyve missing -- which is a broken release that installs a kernel
# with no hypervisor, and is far likelier than losing 96% of the set.
#
# So the contract is a SET comparison, not a threshold:
#
#   1. every package the previous published release contained is still here.
#      A release may add packages; it may not silently lose one.
#   2. the packages this project exists to ship are present by name.
#   3. the repository is usable: catalogue files, and `latest` resolving.
#
# Rule 1 needs a baseline. The published repository is the honest one -- it is
# what users actually have -- and -b takes it. Without a baseline this checks
# rules 2 and 3 and says so, rather than silently checking less than it claims.
#
# Usage:
#   check_release_contract.sh -r <repo-dir> [-v <version>] [-b <baseline-dir>]
#
#   -r  the ABI directory of the built repository, holding <version>/ and latest
#   -v  version to check. Default: whatever `latest` points at.
#   -b  ABI directory of a previous release to compare against, for rule 1.
set -eu

PROGRAM="${0##*/}"
REPO=""
VERSION=""
BASELINE=""

# The packages this project exists to ship. A release without these is not a
# nested-virtualisation release whatever else it contains, so they are named
# rather than inferred -- inference from the build is what produced the empty
# release in the first place.
REQUIRED="CloudBSD-kernel-generic CloudBSD-bhyve CloudBSD-lib9p CloudBSD-acpi CloudBSD-runtime"

while getopts r:v:b: o; do
	case "$o" in
	r)	REPO=$OPTARG ;;
	v)	VERSION=$OPTARG ;;
	b)	BASELINE=$OPTARG ;;
	*)	echo "usage: $PROGRAM -r <repo-dir> [-v version] [-b baseline-dir]" >&2
		exit 2 ;;
	esac
done

[ -n "$REPO" ] || { echo "$PROGRAM: -r is required" >&2; exit 2; }
[ -d "$REPO" ] || { echo "$PROGRAM: no such repository directory: $REPO" >&2; exit 1; }

# A baseline that was asked for and cannot be read is an error, never a skip.
# Falling through to "no baseline given" would hand back a PASS that checked
# two rules to somebody who believes it checked three -- which is the exact
# failure this file's header says it must not commit.
if [ -n "$BASELINE" ] && [ ! -d "$BASELINE" ]; then
	echo "$PROGRAM: baseline directory does not exist: $BASELINE" >&2
	echo "$PROGRAM: refusing to report a result that silently checks less than it was asked to" >&2
	exit 2
fi

fail() { echo "$PROGRAM: FAIL: $*" >&2; FAILED=$((FAILED + 1)); }
note() { echo "$PROGRAM: $*"; }
FAILED=0

# Resolve the version from the symlink rather than taking it on trust: a repo
# whose `latest` points somewhere else is not publishable no matter how good
# the directory we were told to look at is.
LATEST_TARGET=""
if [ -L "$REPO/latest" ]; then
	LATEST_TARGET=$(readlink "$REPO/latest")
	LATEST_TARGET=${LATEST_TARGET##*/}
fi
[ -n "$VERSION" ] || VERSION=$LATEST_TARGET

if [ -z "$VERSION" ]; then
	fail "no version given and 'latest' is not a symlink -- the media cannot install from this"
	exit 1
fi

VDIR="$REPO/$VERSION"
[ -d "$VDIR" ] || { fail "version directory missing: $VDIR"; exit 1; }

if [ -n "$LATEST_TARGET" ] && [ "$LATEST_TARGET" != "$VERSION" ]; then
	fail "latest -> $LATEST_TARGET but checking $VERSION; publishing this would serve the other one"
fi

# --- rule 3: the repository is usable ------------------------------------
# Checked first because it is the cheapest and because a repo with no
# catalogue cannot be installed from however complete its package set is.
for f in meta meta.conf packagesite.pkg data.pkg; do
	[ -s "$VDIR/$f" ] || fail "catalogue file missing or empty: $f"
done

# --- the package set -----------------------------------------------------
# `ls` into a variable rather than a glob in a for-loop: an unmatched glob in
# sh expands to the literal pattern, which would then be reported as a missing
# package named '*.pkg' instead of as an empty repository.
# Strip the exact version we already know, not a guess at where a version
# starts. `sed 's/-[0-9][^-]*$//'` was the first attempt and it is wrong for any
# version containing a hyphen or a suffix -- 16.0.s20260908-g1234abc, or 1.2.3_1
# -- where it removes the wrong segment or nothing at all. Both sides of the
# comparison then normalise differently and rule 1 reports a package as lost
# because its version format changed, or misses a real loss because two names
# collapsed onto one. The version is a parameter here; use it.
names_in() {
	ls "$1" 2>/dev/null | sed -n "s/-$2\.pkg\$//p" | sort -u
}
SET=$(names_in "$VDIR" "$VERSION")
# Count the packages, not everything ending in .pkg: the catalogue itself is
# packagesite.pkg and data.pkg, so a naive *.pkg count reports two packages that
# do not exist and would let a repository two short of its baseline look right.
NPKG=$(printf '%s\n' "$SET" | grep -c .)
NFILES=$(ls "$VDIR"/*.pkg 2>/dev/null | wc -l | tr -d ' ')
note "version $VERSION: $NPKG packages ($NFILES .pkg files including the catalogue)"

if [ "${NPKG:-0}" -eq 0 ]; then
	fail "no packages at all in $VDIR"
	exit 1
fi

# --- rule 2: the packages this project exists to ship --------------------
for want in $REQUIRED; do
	if ! printf '%s\n' "$SET" | grep -qx "$want"; then
		fail "required package missing: $want"
	fi
done

# --- rule 1: nothing the previous release had has disappeared ------------
if [ -n "$BASELINE" ] && [ -d "$BASELINE" ]; then
	BVER=""
	[ -L "$BASELINE/latest" ] && { BVER=$(readlink "$BASELINE/latest"); BVER=${BVER##*/}; }
	if [ -n "$BVER" ] && [ -d "$BASELINE/$BVER" ]; then
		# Both sides to temp files: comm needs two files, and building one of
		# them inside the other's command substitution -- which the first draft
		# of this did -- is unreadable and leaks the file on any early exit.
		TMP=${TMPDIR:-/tmp}/$PROGRAM.$$
		mkdir -p "$TMP" || { echo "$PROGRAM: cannot create $TMP" >&2; exit 1; }
		trap 'rm -rf "$TMP"' EXIT INT TERM
		names_in "$BASELINE/$BVER" "$BVER" > "$TMP/baseline"
		printf '%s\n' "$SET" > "$TMP/current"
		LOST=$(comm -23 "$TMP/baseline" "$TMP/current")
		BVER_COUNT=$(grep -c . < "$TMP/baseline")
		if [ -n "$LOST" ]; then
			fail "packages present in $BVER and missing here:"
			printf '%s\n' "$LOST" | sed 's/^/    /' >&2
		else
			note "no package from $BVER ($BVER_COUNT names) is missing here"
		fi
	else
		note "baseline $BASELINE has no resolvable version; rule 1 not checked"
	fi
else
	note "no baseline given; checked only that required packages and the catalogue are present"
fi

if [ "$FAILED" -gt 0 ]; then
	echo "$PROGRAM: $FAILED contract failure(s) -- this build produced a repository that should not be published" >&2
	exit 1
fi

note "PASS -- $VERSION satisfies the release contract"
