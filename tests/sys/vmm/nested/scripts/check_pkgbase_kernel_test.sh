#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Exercise check_pkgbase_kernel.sh against repositories built to fail it.
#
# The check exists to stop a release from reusing a package repository that was
# not built from the kernel it is about to ship, so the cases that matter are
# the ones where the repository LOOKS right: correct directory, correct package
# name, correct version, and a kernel inside it that is not this build's. A
# test that only proves the happy path passes proves nothing about that.

set -eu

CHECK=${1:-$(dirname "$0")/check_pkgbase_kernel.sh}
[ -x "$CHECK" ] || { echo "no executable check at $CHECK" >&2; exit 2; }

W=$(mktemp -d "${TMPDIR:-/tmp}/pkbktest.XXXXXX")
trap 'rm -rf "$W"' EXIT

PASS=0
FAIL=0
# Counted apart from failures and NOT fed into the exit status. A host whose
# tar lacks a codec has not found a defect, and reporting it as one makes an
# absent tool indistinguishable from a broken check.
SKIP=0

# Runs one case and reports it. Takes the expected exit status, a label, and
# the arguments. A refusal must also SAY something: a check that refuses
# silently is indistinguishable from a check that is not running, so an empty
# reason fails the case even when the status is right.
expect() {
	_want=$1; _label=$2; shift 2
	_out=$("$CHECK" "$@" 2>&1) && _got=0 || _got=$?
	if [ "$_got" != "$_want" ]; then
		echo "FAIL  $_label: expected exit $_want, got $_got"
		echo "      $_out"
		FAIL=$((FAIL + 1))
		return
	fi
	if [ -z "$_out" ]; then
		echo "FAIL  $_label: exit $_got was right but the check said nothing"
		FAIL=$((FAIL + 1))
		return
	fi
	echo "ok    $_label"
	PASS=$((PASS + 1))
}

# Builds a package tarball holding one kernel, at the member spelling real
# pkgbase packages use -- a leading slash.
#
# COMPRESSION MATTERS HERE. pkg writes .pkg files compressed, so a suite built
# only from plain tar archives never exercises the path a release actually
# takes: a tar that cannot read the compression would pass every case here and
# fail on the first real package. The compression is chosen per fixture and
# each is verified readable before it is used, so a host without one codec
# skips that fixture loudly rather than testing nothing quietly.
make_pkg() {
	_dest=$1; _kernel=$2; _comp=${3:-none}
	_t=$(mktemp -d "$W/mk.XXXXXX")
	mkdir -p "$_t/boot/kernel"
	cp "$_kernel" "$_t/boot/kernel/kernel"
	: > "$_t/+MANIFEST"
	mkdir -p "$(dirname "$_dest")"
	case "$_comp" in
	zstd)	_cflag=--zstd ;;
	xz)	_cflag=-J ;;
	*)	_cflag="" ;;
	esac
	# bsdtar rewrites member names with -s, GNU tar does not have it and
	# stores them without the leading slash. Either spelling is one a real
	# package can use, and the check has to accept both.
	(cd "$_t" && tar -cf "$_dest" $_cflag -s '|^|/|' +MANIFEST boot 2>/dev/null) ||
	    (cd "$_t" && tar -cf "$_dest" $_cflag +MANIFEST boot 2>/dev/null) ||
	    { rm -rf "$_t"; return 1; }
	rm -rf "$_t"
	tar -tf "$_dest" >/dev/null 2>&1 || return 1
}

PREFIX=CloudBSD
VER=16.0.20260909.testrel
ABI=$W/repo/FreeBSD:16:amd64/$VER

# Two kernels that differ. Same length, one byte apart -- a check comparing
# sizes rather than contents would pass this and must not.
printf 'kernel-alpha-%040d' 1 > "$W/kernel.a"
printf 'kernel-alpha-%040d' 2 > "$W/kernel.b"

mkdir -p "$ABI"
make_pkg "$ABI/${PREFIX}-kernel-generic-${VER}.pkg" "$W/kernel.a"

expect 0 "the repository's kernel is this build's kernel" \
    -r "$W/repo" -k "$W/kernel.a" -p "$PREFIX" -v "$VER"

expect 1 "a repository carrying a DIFFERENT kernel is refused" \
    -r "$W/repo" -k "$W/kernel.b" -p "$PREFIX" -v "$VER"

expect 1 "a repository built for another release is refused" \
    -r "$W/repo" -k "$W/kernel.a" -p "$PREFIX" -v 16.0.20260909.otherrel

expect 1 "a repository under another package prefix is refused" \
    -r "$W/repo" -k "$W/kernel.a" -p SomethingElse -v "$VER"

expect 1 "a missing repository is refused" \
    -r "$W/nosuchrepo" -k "$W/kernel.a" -p "$PREFIX" -v "$VER"

expect 1 "a missing kernel to compare against is refused" \
    -r "$W/repo" -k "$W/nosuchkernel" -p "$PREFIX" -v "$VER"

# The compressed fixtures: this is how pkg actually writes a package, and the
# uncompressed cases above would pass on a host whose tar cannot read them.
for _c in zstd xz; do
	_cd=$W/comp-$_c/FreeBSD:16:amd64/$VER
	if make_pkg "$_cd/${PREFIX}-kernel-generic-${VER}.pkg" "$W/kernel.a" "$_c"; then
		expect 0 "a $_c-compressed package is read" \
		    -r "$W/comp-$_c" -k "$W/kernel.a" -p "$PREFIX" -v "$VER"
		expect 1 "a $_c-compressed package with the wrong kernel is refused" \
		    -r "$W/comp-$_c" -k "$W/kernel.b" -p "$PREFIX" -v "$VER"
	else
		echo "SKIP  $_c: this tar cannot write or read it"
		SKIP=$((SKIP + 1))
	fi
done

# A package that is not a package at all. This must be told apart from a
# package with no kernel in it: the two need different answers from whoever
# reads the message, and a check that conflates them sends them to the wrong
# place.
BAD=$W/badrepo/FreeBSD:16:amd64/$VER
mkdir -p "$BAD"
head -c 4096 /dev/urandom > "$BAD/${PREFIX}-kernel-generic-${VER}.pkg"
_out=$("$CHECK" -r "$W/badrepo" -k "$W/kernel.a" -p "$PREFIX" -v "$VER" 2>&1) && _rc=0 || _rc=$?
if [ "$_rc" = 1 ] && echo "$_out" | grep -q "not a readable package"; then
	echo "ok    an unreadable package is named as unreadable, not as empty"
	PASS=$((PASS + 1))
else
	echo "FAIL  an unreadable package: exit $_rc, said: $_out"
	FAIL=$((FAIL + 1))
fi

# A package with the right name and no kernel in it. This is the shape a
# partial or interrupted package build leaves behind, and the one most likely
# to be mistaken for a usable repository.
EMPTY=$W/emptyrepo/FreeBSD:16:amd64/$VER
mkdir -p "$EMPTY"
_t=$(mktemp -d "$W/mk.XXXXXX"); : > "$_t/+MANIFEST"
(cd "$_t" && tar -cf "$EMPTY/${PREFIX}-kernel-generic-${VER}.pkg" +MANIFEST)
rm -rf "$_t"

expect 1 "a kernel package with no kernel in it is refused" \
    -r "$W/emptyrepo" -k "$W/kernel.a" -p "$PREFIX" -v "$VER"

# An empty repository directory. This is the four-package case in miniature:
# the directory exists, which is exactly the reasoning the check replaces.
mkdir -p "$W/bare"
expect 1 "an empty repository directory is refused" \
    -r "$W/bare" -k "$W/kernel.a" -p "$PREFIX" -v "$VER"

# A kernel large enough to need more than one read out of the pipe. The small
# fixtures above pass whether or not the extraction is truncated, because one
# read covers them -- which is exactly how a block-counted dd shipped a check
# that refused every real repository while every test agreed it was fine.
BIG=$W/bigrepo/FreeBSD:16:amd64/$VER
mkdir -p "$BIG"
dd if=/dev/urandom of="$W/kernel.big" bs=1048576 count=12 2>/dev/null
make_pkg "$BIG/${PREFIX}-kernel-generic-${VER}.pkg" "$W/kernel.big"
expect 0 "a multi-megabyte kernel is compared in full, not truncated" \
    -r "$W/bigrepo" -k "$W/kernel.big" -p "$PREFIX" -v "$VER"
# The same size, differing near the END -- which a truncated read would miss.
cp "$W/kernel.big" "$W/kernel.bigalt"
printf '\377' | dd of="$W/kernel.bigalt" bs=1 seek=12582910 count=1 conv=notrunc 2>/dev/null
expect 1 "a difference in the last bytes of a large kernel is caught" \
    -r "$W/bigrepo" -k "$W/kernel.bigalt" -p "$PREFIX" -v "$VER"

# A repository the search cannot read. This must not print the same line as an
# empty repository: one is a repository to rebuild, the other a permission to
# fix, and they go to different people.
#
# Skipped when running as root, which can read it regardless -- and counted as
# a skip rather than a pass, because a case that cannot fail has not passed.
UNREADABLE=$W/unreadable
mkdir -p "$UNREADABLE/sub"
chmod 000 "$UNREADABLE/sub"
if [ "$(id -u)" = 0 ] || find "$UNREADABLE" -type f >/dev/null 2>&1; then
	echo "SKIP  an unreadable repository: this user can read it anyway"
	SKIP=$((SKIP + 1))
else
	_out=$("$CHECK" -r "$UNREADABLE" -k "$W/kernel.a" -p "$PREFIX" -v "$VER" 2>&1) && _rc=0 || _rc=$?
	if [ "$_rc" = 1 ] && echo "$_out" | grep -q "cannot .*search"; then
		echo "ok    an unreadable repository is named as unreadable, not as empty"
		PASS=$((PASS + 1))
	else
		echo "FAIL  an unreadable repository: exit $_rc, said: $_out"
		FAIL=$((FAIL + 1))
	fi
fi
chmod 755 "$UNREADABLE/sub"

# A package truncated halfway through its kernel member. The extraction stops
# early, and the refusal must say the package would not yield the member --
# not that the kernel differs, which is true of the fragment and useless to
# whoever reads it.
TRUNC=$W/truncrepo/FreeBSD:16:amd64/$VER
mkdir -p "$TRUNC"
_full=$W/full.pkg
make_pkg "$_full" "$W/kernel.big" xz
head -c $(( $(wc -c < "$_full") / 2 )) "$_full" > "$TRUNC/${PREFIX}-kernel-generic-${VER}.pkg"
_out=$("$CHECK" -r "$W/truncrepo" -k "$W/kernel.big" -p "$PREFIX" -v "$VER" 2>&1) && _rc=0 || _rc=$?
if [ "$_rc" = 1 ] && echo "$_out" | grep -qE "not a readable package|would not yield"; then
	echo "ok    a truncated package blames the package, not the kernel"
	PASS=$((PASS + 1))
else
	echo "FAIL  a truncated package: exit $_rc, said: $_out"
	FAIL=$((FAIL + 1))
fi

# A package listing a DECOY kernel at a deeper path before the real member.
# A suffix match takes the decoy -- which holds this build's kernel -- and
# grants reuse for a repository that would ship the other one.
DEC=$W/decoyrepo/FreeBSD:16:amd64/$VER
mkdir -p "$DEC"
_t=$(mktemp -d "$W/mk.XXXXXX")
mkdir -p "$_t/decoy/boot/kernel" "$_t/boot/kernel"
cp "$W/kernel.a" "$_t/decoy/boot/kernel/kernel"
cp "$W/kernel.b" "$_t/boot/kernel/kernel"
: > "$_t/+MANIFEST"
(cd "$_t" && tar -cf "$DEC/${PREFIX}-kernel-generic-${VER}.pkg" +MANIFEST decoy boot)
rm -rf "$_t"
expect 1 "a decoy kernel at a deeper path does not grant reuse" \
    -r "$W/decoyrepo" -k "$W/kernel.a" -p "$PREFIX" -v "$VER"

# A repository holding the same package name under two ABI subtrees. Which one
# the release would ship is not decidable from here, and picking the first the
# directory walk reaches would compare an arbitrary archive -- then delete a
# repository that did hold the right one.
AMB=$W/ambiguous
mkdir -p "$AMB/FreeBSD:16:amd64/$VER" "$AMB/FreeBSD:15:amd64/$VER"
make_pkg "$AMB/FreeBSD:16:amd64/$VER/${PREFIX}-kernel-generic-${VER}.pkg" "$W/kernel.a"
make_pkg "$AMB/FreeBSD:15:amd64/$VER/${PREFIX}-kernel-generic-${VER}.pkg" "$W/kernel.b"
expect 1 "a repository holding two packages of that name is refused" \
    -r "$AMB" -k "$W/kernel.a" -p "$PREFIX" -v "$VER"

# A version or prefix carrying a glob metacharacter. These are pasted into a
# find pattern, where `*' matches rather than compares.
expect 1 "a wildcard version is refused rather than matched" \
    -r "$W/repo" -k "$W/kernel.a" -p "$PREFIX" -v '*'
expect 1 "a wildcard prefix is refused rather than matched" \
    -r "$W/repo" -k "$W/kernel.a" -p '*' -v "$VER"

echo
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
