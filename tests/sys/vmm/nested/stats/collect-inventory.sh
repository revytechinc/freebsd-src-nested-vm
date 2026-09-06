#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# Emit an inventory of work products under a directory, as TSV on stdout.
#
# Run this on a fleet machine; the classification happens elsewhere, in one
# place, so that the policy for "is this data or litter" can be changed and
# re-applied without going back to every machine.
#
# The walk is bounded in two ways, both deliberate:
#
#   * It stops at MAXDEPTH.  Home directories here hold between 150 000 and
#     1.7 million files; per-file detail at that scale is not an inventory,
#     it is a second filesystem.
#
#   * It refuses to descend into source trees and object directories, and
#     records each as a single rolled-up entry with its total size.  The
#     question worth asking about a checked-out tree is whether the whole
#     thing is still wanted, never which object file inside it is largest.
#
# Dotfiles are skipped, as shell and editor state is not a work product.
#
# Output columns, tab-separated:
#     kind  hint  size_bytes  mtime_epoch  sha256  path
#
# `size_bytes` is -1 where it was not computed: for directories whose size is
# the sum of the entries listed under them, and for a `du` that timed out.

set -u

ROOT=${1:-$HOME}
MAXDEPTH=${2:-3}
DU_TIMEOUT=${DU_TIMEOUT:-240}

emit() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

# Total size of a subtree, in bytes; -1 when du did not finish in time.
dirsize() {
	_kb=$(timeout "$DU_TIMEOUT" du -skx "$1" 2>/dev/null | awk 'NR==1{print $1}')
	if [ -n "${_kb:-}" ]; then
		echo $((_kb * 1024))
	else
		echo -1
	fi
}

is_srctree() {
	[ -d "$1/.git" ] && return 0
	[ -f "$1/Makefile.inc1" ] && return 0
	return 1
}

is_objdir() {
	case "${1##*/}" in
	obj | obj-* | *.obj | node_modules) return 0 ;;
	esac
	[ -d "$1/amd64.amd64" ] && return 0
	[ -f "$1/.OBJDIR" ] && return 0
	return 1
}

walk() {
	_d=$1
	_depth=$2
	for _e in "$_d"/*; do
		# An unmatched glob leaves the pattern itself behind.
		[ -e "$_e" ] || [ -L "$_e" ] || continue
		_b=${_e##*/}
		case "$_b" in .*) continue ;; esac

		_mt=$(stat -f '%m' "$_e" 2>/dev/null) || _mt=0
		[ -n "$_mt" ] || _mt=0

		if [ -L "$_e" ]; then
			emit symlink - 0 "$_mt" - "$_e"
		elif [ -f "$_e" ]; then
			_sz=$(stat -f '%z' "$_e" 2>/dev/null) || _sz=-1
			_sha=-
			case "$_b" in
			*.ko)
				_sha=$(sha256 -q "$_e" 2>/dev/null) || _sha=-
				[ -n "$_sha" ] || _sha=-
				;;
			esac
			emit file - "${_sz:--1}" "$_mt" "$_sha" "$_e"
		elif [ -d "$_e" ]; then
			if is_srctree "$_e"; then
				emit dir srctree "$(dirsize "$_e")" "$_mt" - "$_e"
			elif is_objdir "$_e"; then
				emit dir objdir "$(dirsize "$_e")" "$_mt" - "$_e"
			elif [ "$_depth" -ge "$MAXDEPTH" ]; then
				emit dir rolled "$(dirsize "$_e")" "$_mt" - "$_e"
			else
				# Size is left to the sum of what follows, so no
				# subtree is walked twice.
				emit dir plain -1 "$_mt" - "$_e"
				walk "$_e" $((_depth + 1))
			fi
		else
			emit other - 0 "$_mt" - "$_e"
		fi
	done
}

printf '#root\t%s\n' "$ROOT"
printf '#host\t%s\n' "$(hostname -s)"
printf '#maxdepth\t%s\n' "$MAXDEPTH"
walk "$ROOT" 1
printf '#end\n'
