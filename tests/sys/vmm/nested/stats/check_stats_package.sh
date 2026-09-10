#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Fail if a file in this directory tree is not shipped by the Makefile, or if
# the Makefile ships something that is not here.
#
# A packaging list is written once and then falls behind, and the failure is
# silent in the worst way: everything installs, the tool appears present, and
# one module is missing -- so it fails at import time on a machine, during a
# test round, having passed every check that ran where the source tree was.
#
# The same defect has shipped from this tree before: a packaging list carried
# five names for a six-member set, and nothing noticed until the sixth was
# looked for.
#
# Usage:
#   check_stats_package.sh [directory]
#
# Exits 0 when every file is accounted for in both directions, 1 otherwise.

set -eu

# comm(1) requires both inputs in the SAME collation order as the sort that
# produced them, and the locale decides that. Without this it prints "file 1 is
# not in sorted order" and its answer is unreliable -- a difference report that
# is quietly wrong is worse than no report.
LC_ALL=C
export LC_ALL

PROGRAM="${0##*/}"
DIR=${1:-$(cd "$(dirname "$0")" && pwd -P)}

[ -d "$DIR" ] || { echo "$PROGRAM: no directory at $DIR" >&2; exit 2; }
MK="$DIR/Makefile"
[ -f "$MK" ] || { echo "$PROGRAM: $DIR has no Makefile, so nothing in it ships" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/statspkg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Everything the Makefile names on the right of a `+=', which covers both
# ${PACKAGE}FILES and the file GROUPS that put a subdirectory in place. Paths
# are kept as written, because that is what says where a file lands.
# Parse the Makefile into (variable, file) pairs.
#
# Line continuations are joined first and each right-hand side is split on
# whitespace, because `nstats+= a.py b.py' is the idiomatic form and a parser
# that reads it as one filename reports both files unshipped AND a phantom
# "a.py b.py" as shipped -- three wrong answers from one line.
awk '
	/\\$/	{ sub(/\\$/, ""); acc = acc $0 " "; next }
		{ line = acc $0; acc = "" }
	line ~ /^[^#]*\+=/ {
		sub(/#.*/, "", line)
		v = line; sub(/\+=.*/, "", v); gsub(/[ \t]/, "", v)
		r = line; sub(/^[^=]*\+=/, "", r)
		n = split(r, f, /[ \t]+/)
		for (i = 1; i <= n; i++)
			if (f[i] != "") print v "\t" f[i]
	}
' "$MK" > "$WORK/pairs"

# FILESGROUPS names groups, not files.
awk -F'\t' '$1 != "FILESGROUPS" { print $2 }' "$WORK/pairs" |
    sort -u > "$WORK/listed"
awk -F'\t' '$1 == "FILESGROUPS" { print $2 }' "$WORK/pairs" |
    sort -u > "$WORK/groups"

# Everything actually here, relative to this directory. Bytecode is the output
# of whatever ran last rather than source; .gitignore is repository metadata.
# Neither belongs on an installed machine, and both would otherwise be reported
# as unshipped every run until somebody added them to the Makefile to quiet it.
( cd "$DIR" && find . -type f ) |
    sed 's|^\./||' |
    grep -vE '^Makefile$|^\.gitignore$|\.pyc$|\.orig$|\.rej$|\.bak$|(^|/)__pycache__/' |
    sort -u > "$WORK/present"

# A name carrying an unexpanded make variable cannot be compared against the
# filesystem, and this cannot expand it. Reported and set aside rather than
# counted as a ghost -- the DIR check already treats a computed value that way,
# and the two halves of this script must not disagree about whether such a
# value is acceptable.
_computed=$(grep '\${' "$WORK/listed") || _computed=""
if [ -n "$_computed" ]; then
	echo "$PROGRAM: note: these shipped names are computed, so whether they exist"
	echo "          could not be checked here:"
	printf '%s\n' "$_computed" | sed 's/^/    /'
	grep -v '\${' "$WORK/listed" > "$WORK/listed.plain" || : > "$WORK/listed.plain"
	mv "$WORK/listed.plain" "$WORK/listed"
fi

RC=0

# Present but not shipped. This is the direction that bites: the file is in the
# tree, every developer sees it, and no machine ever gets it.
_missing=$(comm -23 "$WORK/present" "$WORK/listed") || _missing=""
if [ -n "$_missing" ]; then
	echo "$PROGRAM: these files are in $DIR but nothing ships them:"
	printf '%s\n' "$_missing" | sed 's/^/    /'
	RC=1
fi

# Shipped but not present. Installs nothing and reports success, which is how a
# package comes to be missing a module that nobody removed.
_ghost=$(comm -13 "$WORK/present" "$WORK/listed") || _ghost=""
if [ -n "$_ghost" ]; then
	echo "$PROGRAM: $MK ships these, and they are not in $DIR:"
	printf '%s\n' "$_ghost" | sed 's/^/    /'
	RC=1
fi

# A file in a subdirectory lands there only if the group that ships it is
# DECLARED, and has a DIR. Three things have to line up and bsd.files.mk is
# silent when any of them does not:
#
#   * the group appears in FILESGROUPS -- without it the variable is inert and
#     every file in it is skipped while the Makefile still reads correctly;
#   * <group>DIR names the subdirectory -- without it the BASENAME is installed
#     into the parent, so the package looks complete and the import fails;
#   * <group>PACKAGE is set, or the files land outside the tests package.
#
# Measured: removing the FILESGROUPS line leaves seven modules uninstalled.
while IFS='	' read -r _v _p; do
	case "$_p" in
	*/*)	;;
	*)	continue ;;
	esac
	# Only the package's own FILES variable is exempt. "anything ending in
	# FILES" would also exempt a group someone called NSTATSFILES, which
	# bsd.files.mk still requires to be declared in FILESGROUPS -- so it
	# would skip the checks and not install.
	[ "$_v" = '${PACKAGE}FILES' ] && continue
	_sub=${_p%/*}
	if ! grep -qx "$_v" "$WORK/groups"; then
		echo "$PROGRAM: $_p is listed in \$$_v, which is not in FILESGROUPS;"
		echo "          bsd.files.mk ships nothing from an undeclared group"
		RC=1
	fi
	_dir=$(grep "^${_v}DIR=" "$MK" | head -1) || _dir=""
	if [ -z "$_dir" ]; then
		echo "$PROGRAM: $_p is shipped, but there is no ${_v}DIR to put it under $_sub/;"
		echo "          it would be installed into the parent directory instead"
		RC=1
	elif ! expr "$_dir" : ".*/${_sub}\$" >/dev/null; then
		# The DIR exists but does not literally end in this subdirectory.
		# It may still be correct -- `${TESTSDIR}/${MODDIR}' installs
		# perfectly well and this cannot expand make variables -- so say
		# what could not be established rather than failing a Makefile
		# that works. A checker that blocks a correct build is worse than
		# the drift it was written to catch.
		case "$_dir" in
		*'${'*)	echo "$PROGRAM: note: ${_v}DIR is computed, so whether $_p lands"
			echo "          under $_sub/ could not be checked here: $_dir" ;;
		*)	echo "$PROGRAM: $_p is shipped, but ${_v}DIR does not put it under $_sub/;"
			echo "          it would be installed into the parent directory instead"
			RC=1 ;;
		esac
	fi
	if ! grep -q "^${_v}PACKAGE=" "$MK"; then
		echo "$PROGRAM: $_v has no ${_v}PACKAGE, so its files land outside the package"
		RC=1
	fi
done < "$WORK/pairs"

if [ "$RC" = 0 ]; then
	echo "$PROGRAM: $(grep -c . "$WORK/present") files, all shipped, all present"
fi
exit "$RC"
