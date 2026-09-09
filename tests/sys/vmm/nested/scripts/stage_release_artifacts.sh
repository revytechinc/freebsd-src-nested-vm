#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# stage_release_artifacts.sh -- turn a release object directory into the set of
# files that actually gets published: publishable names, VM images compressed,
# a checksum list, a README and a generated manifest.
#
# The release makefiles produce `disc1.iso` and `vm.zfs.raw`. What the site
# serves is `<prefix>-16.0-CURRENT-amd64-disc1.iso` and
# `<prefix>-16.0-CURRENT-amd64-zfs.raw.xz`. Nothing in the tree did that
# translation -- it was done by hand for the previous release, which is why the
# published set could not be reproduced from a checkout, and why a rebuild
# needed a person who remembered the naming.
#
# Usage:
#   stage_release_artifacts.sh -r <release-objdir> -o <out-dir> [-p prefix]
#                              [-l label] [-a arch] [-i build-identity]
#
#   -r  the release object directory holding disc1.iso, vm.*.raw and friends
#   -o  where to write the staged set. Created; must not already hold artifacts.
#   -p  name prefix (default CloudBSD, matching the package prefix)
#   -l  version label in the filename (default 16.0-CURRENT)
#   -a  architecture (default amd64)
#   -i  build-identity.txt, for the README and the manifest
#   -k  the package repository ABI directory, so the manifest records how many
#       packages the release carries rather than leaving it null
set -eu

PROGRAM="${0##*/}"
SCRIPTDIR=$(cd "$(dirname "$0")" && pwd -P)

RELOBJ=""; OUT=""; PREFIX="CloudBSD"; LABEL="16.0-CURRENT"; ARCH="amd64"; IDENT=""; PKGREPO=""

while getopts r:o:p:l:a:i:k: o; do
	case "$o" in
	r) RELOBJ=$OPTARG ;;
	o) OUT=$OPTARG ;;
	p) PREFIX=$OPTARG ;;
	l) LABEL=$OPTARG ;;
	a) ARCH=$OPTARG ;;
	i) IDENT=$OPTARG ;;
	k) PKGREPO=$OPTARG ;;
	*) echo "usage: $PROGRAM -r <release-objdir> -o <out-dir> [-p prefix] [-l label] [-a arch] [-i identity]" >&2
	   exit 2 ;;
	esac
done

for _v in RELOBJ OUT PREFIX LABEL ARCH; do
	eval "_val=\${$_v:-}"
	[ -n "$_val" ] || { echo "$PROGRAM: $_v is required" >&2; exit 2; }
done
for _v in RELOBJ OUT; do
	eval "_val=\${$_v}"
	case "$_val" in /*) ;; *) echo "$PROGRAM: $_v must be absolute: $_val" >&2; exit 2 ;; esac
	case "/$_val/" in */../*) echo "$PROGRAM: $_v has a '..' component" >&2; exit 2 ;; esac
done
# These three end up in filenames the world downloads.
for _v in PREFIX LABEL ARCH; do
	eval "_val=\${$_v}"
	case "$_val" in
	*[!0-9A-Za-z._-]*) echo "$PROGRAM: $_v may only contain [0-9A-Za-z._-]: $_val" >&2; exit 2 ;;
	esac
done

[ -d "$RELOBJ" ] || { echo "$PROGRAM: no such release directory: $RELOBJ" >&2; exit 1; }

BASE="${PREFIX}-${LABEL}-${ARCH}"

# The translation, as data. Left is what the makefiles produce, right is what
# the world downloads. `xz` marks the ones that get compressed.
#
#   <source>|<published suffix>|<compress?>|<required?>
#
# The installer images come from `real-release` and are always expected. The VM
# images come from `vm-release`, which is a separate target and needs tooling
# for each format -- so they are optional HERE, and their absence is reported
# rather than fatal. Without that distinction a release built without VM images
# fails after writing gigabytes of compressed output, and the next attempt
# refuses to start because the output directory is no longer empty.
SET="disc1.iso|disc1.iso|no|yes
bootonly.iso|bootonly.iso|no|yes
memstick.img|memstick.img|no|yes
mini-memstick.img|mini-memstick.img|no|yes
vm.ufs.raw|ufs.raw|xz|no
vm.ufs.qcow2|ufs.qcow2|xz|no
vm.ufs.vhd|ufs.vhd|xz|no
vm.ufs.vmdk|ufs.vmdk|xz|no
vm.zfs.raw|zfs.raw|xz|no
vm.zfs.qcow2|zfs.qcow2|xz|no
vm.zfs.vhd|zfs.vhd|xz|no
vm.zfs.vmdk|zfs.vmdk|xz|no"

mkdir -p "$OUT" || { echo "$PROGRAM: cannot create $OUT" >&2; exit 1; }
# Refuse to stage into a directory that already holds artifacts: a leftover from
# a previous run would be published alongside the new ones and look like part of
# the same build.
if [ -n "$(find "$OUT" -maxdepth 1 \( -name '*.iso' -o -name '*.img' -o -name '*.xz' \) 2>/dev/null)" ]; then
	echo "$PROGRAM: $OUT already contains artifacts; empty it first" >&2
	echo "$PROGRAM: publishing a mixture of two builds is indistinguishable from one build" >&2
	exit 1
fi

_missing=""
_skipped=""
_saveIFS=$IFS
IFS='
'
for _line in $SET; do
	IFS=$_saveIFS
	_src=$(printf '%s' "$_line" | cut -d'|' -f1)
	_suffix=$(printf '%s' "$_line" | cut -d'|' -f2)
	_mode=$(printf '%s' "$_line" | cut -d'|' -f3)
	_req=$(printf '%s' "$_line" | cut -d'|' -f4)
	[ -n "$_src" ] || { IFS='
'; continue; }
	if [ ! -f "$RELOBJ/$_src" ]; then
		if [ "$_req" = yes ]; then
			_missing="$_missing $_src"
		else
			_skipped="$_skipped $_src"
		fi
		IFS='
'
		continue
	fi
	case "$_mode" in
	xz)	echo "  compressing $_src -> $BASE-$_suffix.xz"
		# -T0 uses every core; this is 8 images of several gigabytes and the
		# single-threaded default turns a ten-minute step into an hour.
		xz -T0 -c -- "$RELOBJ/$_src" > "$OUT/$BASE-$_suffix.xz.part"
		mv -- "$OUT/$BASE-$_suffix.xz.part" "$OUT/$BASE-$_suffix.xz" ;;
	*)	echo "  copying     $_src -> $BASE-$_suffix"
		cp -- "$RELOBJ/$_src" "$OUT/$BASE-$_suffix.part"
		mv -- "$OUT/$BASE-$_suffix.part" "$OUT/$BASE-$_suffix" ;;
	esac
	IFS='
'
done
IFS=$_saveIFS

if [ -n "$_skipped" ]; then
	echo "$PROGRAM: not built by this release, and not required:$_skipped"
fi
if [ -n "$_missing" ]; then
	echo "$PROGRAM: the build did not produce these REQUIRED artifacts:$_missing" >&2
	echo "$PROGRAM: refusing to stage a partial release -- a set missing an image" >&2
	echo "$PROGRAM: publishes perfectly and fails on whoever wanted that format" >&2
	exit 1
fi

# Count what is on disk as well as what the loop thought it did. The loop knows
# what it skipped; this knows what actually landed, and a disagreement between
# the two means a copy or a compression failed silently.
# Counted by the names SET says should exist, not by a file pattern. The two
# were only accidentally aligned: every current entry happens to end in .iso,
# .img or .xz, so an entry added later with any other suffix would stage
# correctly and then be reported as a silent copy failure.
_want=0
_have=0
_s2=$IFS
IFS='
'
for _line in $SET; do
	IFS=$_s2
	[ -n "$_line" ] || { IFS='
'; continue; }
	_suffix=$(printf '%s' "$_line" | cut -d'|' -f2)
	_mode=$(printf '%s' "$_line" | cut -d'|' -f3)
	_src=$(printf '%s' "$_line" | cut -d'|' -f1)
	_name="$BASE-$_suffix"
	[ "$_mode" = xz ] && _name="$_name.xz"
	# Only count what this build actually had a source for.
	[ -f "$RELOBJ/$_src" ] || { IFS='
'; continue; }
	_want=$((_want + 1))
	[ -f "$OUT/$_name" ] && _have=$((_have + 1))
	IFS='
'
done
IFS=$_s2
echo "$PROGRAM: staged $_have of $_want artifacts"
[ "$_have" = "$_want" ] || {
	echo "$PROGRAM: $((_want - _have)) artifact(s) did not land in $OUT" >&2
	echo "$PROGRAM: the sources were all present -- the _missing check above" >&2
	echo "$PROGRAM: passed -- so a copy or a compression failed silently" >&2
	exit 1
}

# Checksums over an EXPLICIT list. `sha256 *.iso *.img *.xz` passes an unmatched
# pattern through literally, so a release with no .img files asks the tool to
# hash a file named "*.img", it errors, and the checksum file is left truncated
# beside artifacts it does not describe.
_files=$(cd "$OUT" && find . -maxdepth 1 \( -name '*.iso' -o -name '*.img' -o -name '*.xz' \) \
    | sed 's|^\./||' | sort)
[ -n "$_files" ] || { echo "$PROGRAM: nothing staged to checksum" >&2; exit 1; }
(
	cd "$OUT" || exit 1
	IFS='
'
	# shellcheck disable=SC2086
	set -f
	if command -v sha256 >/dev/null 2>&1; then
		sha256 -- $_files > CHECKSUM.SHA256
		sha256sum -- $_files > CHECKSUM.SHA256.txt 2>/dev/null || true
	else
		sha256sum -- $_files > CHECKSUM.SHA256.txt
		cp CHECKSUM.SHA256.txt CHECKSUM.SHA256
	fi
)
echo "$PROGRAM: checksums written for $(printf '%s\n' "$_files" | grep -c .) files"

# The README that ships beside the images. Someone who downloads an image
# without reading the site has this and nothing else, so it carries the warning
# and the build identity. Generated here, from the same identity the manifest
# uses, so the two can never disagree.
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
	if [ -n "$IDENT" ] && [ -f "$IDENT" ]; then
		sed 's/^/  /' "$IDENT"
	else
		echo "  (no build identity was supplied)"
	fi
	echo
	echo "Artifacts"
	echo "---------"
	( cd "$OUT" && find . -maxdepth 1 \( -name '*.iso' -o -name '*.img' -o -name '*.xz' \) |
	    sed 's|^\./||' | sort |
	    while read -r _a; do
		printf '  %-45s %12d\n' "$_a" "$(stat -f %z "$_a" 2>/dev/null || stat -c %s "$_a")"
	    done )
} > "$OUT/README.txt"
echo "$PROGRAM: README.txt written"

# The manifest the site reads for versions, sizes and download paths.
GEN="$SCRIPTDIR/gen_release_manifest.sh"
if [ -x "$GEN" ]; then
	# `if`, not `[ -n ] && assign`: a false test returns 1, and under set -e
	# that ends the run right before the manifest is written.
	set -- -d "$OUT" -u "/releases/${LABEL}-${ARCH}" -o "$OUT/release.json"
	[ -n "$IDENT" ] && set -- "$@" -i "$IDENT"
	[ -n "$PKGREPO" ] && set -- "$@" -p "$PKGREPO"
	sh "$GEN" "$@"
else
	echo "$PROGRAM: $GEN not found; no release.json was written" >&2
	exit 1
fi

echo "$PROGRAM: staged into $OUT"
