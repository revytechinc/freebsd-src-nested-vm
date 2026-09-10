#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Answer one question: does any package of this release other than
# nested-tests carry part of the nested test tree, and does nested-tests carry
# anything that is not part of it?
#
# That is exclusivity, and it is not completeness. A directory dropped from
# SUBDIR, or one make never descended into, installs nothing anywhere and
# passes here -- there is nothing in a package repository to compare against
# the source tree, so the check that would catch it belongs upstream of this
# one, against the METALOG or the source file list. What this refuses is the
# tree being SPLIT, which is the failure that reaches a machine.
#
# bsd.test.mk defaults PACKAGE to tests. A directory added under the nested
# tree without a PACKAGE line therefore lands in the tests package, and nothing
# fails at build time: the file installs, the package builds, the repository
# publishes. It fails later, on a machine, because nested/Kyuafile ships in
# nested-tests and include()s each subdirectory's own Kyuafile -- so kyua
# aborts for anyone who installed one package and not the other, and which of
# the two breaks depends on which way the missing PACKAGE line fell.
#
# The harness lives in its own package because the published install route is a
# four-package overlay over an untouched FreeBSD userland, and the base test
# suite cannot be installed there at all: it requires the whole base set, which
# conflicts file-for-file with what is already installed. So a release in which
# the harness has drifted back into -tests is a release nobody can install the
# harness from, and it says nothing about that while it is being built.
#
# Checked against the built packages rather than the METALOG, because the
# packages are what a machine installs -- a correct METALOG and a wrong package
# are still a wrong release.
#
# Exit 0 when the boundary holds, 1 when it does not, and 2 when the check could
# not be carried out at all -- a bad invocation, a repository path that cannot
# be used, an archive that cannot be read. Three values rather than two, because
# "I could not look" and "I looked and the answer is no" send whoever reads the
# log to different places, and the caller branches on that. Every refusal prints
# what it found: a silent refusal reads as a check that is not running.

set -eu

PROGRAM=${0##*/}

usage() {
	echo "usage: $PROGRAM -r <repo-dir> -p <pkg-name-prefix> -v <pkg-version>" >&2
	exit 2
}

REPO=""
PREFIX=""
VERSION=""
while getopts "r:p:v:" _o; do
	case "$_o" in
	r)	REPO=$OPTARG ;;
	p)	PREFIX=$OPTARG ;;
	v)	VERSION=$OPTARG ;;
	*)	usage ;;
	esac
done
[ -n "$REPO" ] && [ -n "$PREFIX" ] && [ -n "$VERSION" ] || usage
[ -d "$REPO" ] || { echo "$PROGRAM: not a directory: $REPO" >&2; exit 2; }

# Two things about the operands that find and its -name glob would otherwise
# reinterpret. Both are invocation faults, refused before anything is read.
#
# A path beginning with "-" is taken by find as part of the expression rather
# than as a starting point, and find then walks the current directory instead.
# With an operand like -delete that is not a wrong answer, it is a destructive
# one. `--' is not portable across every find, and prefixing "./" would change
# the paths in every message, so the leading "-" is simply refused.
case "$REPO" in
-*)
	echo "$PROGRAM: the repository path begins with '-': $REPO" >&2
	echo "$PROGRAM: find would read that as part of its expression and" >&2
	echo "$PROGRAM: walk the current directory instead. Give a path that" >&2
	echo "$PROGRAM: does not, or prefix it with ./" >&2
	exit 2
	;;
esac

# The prefix and the version are interpolated into a -name glob, where *, ? and
# [] are not literal. A version carrying one would silently change which
# archive is examined -- and this whole file exists to make sure the thing
# examined is the thing being released.
for _operand in "$PREFIX" "$VERSION"; do
	case "$_operand" in
	*[*?[]*|*\\*|*/*)
		echo "$PROGRAM: glob metacharacters in an operand: $_operand" >&2
		echo "$PROGRAM: it is interpolated into a -name pattern, where" >&2
		echo "$PROGRAM: those are not literal, so this would decide which" >&2
		echo "$PROGRAM: package to examine rather than name it." >&2
		exit 2
		;;
	esac
done

# A literal newline, held in a variable. `$(printf "\n")' cannot express one:
# command substitution strips trailing newlines, so the pattern would collapse
# to *""* and match every path -- which is how this guard first refused every
# correct release it was given.
_NL='
'
case "$REPO" in
*"$_NL"*)
	echo "$PROGRAM: the repository path contains a newline." >&2
	echo "$PROGRAM: package paths are handled a line at a time here, so" >&2
	echo "$PROGRAM: this one cannot be scanned correctly. Give a path" >&2
	echo "$PROGRAM: without one." >&2
	exit 2
	;;
esac

# The tree that must be in nested-tests, and only there.
TREE=usr/tests/sys/vmm/nested/

# Located by a filename carrying this release's version, so a package left
# behind by an older run is not found rather than silently accepted.
#
# Inline rather than in a function, because a function called as $(...) runs in
# a subshell and its `exit' ends only that subshell -- the caller would carry on
# with a two-line value and report the wrong fault. That is the shape this file
# exists to catch, and it was here.
# find's own status, and its stderr. A find that fails part way through --
# an unreadable subdirectory, an I/O error -- returns a partial list, and a
# partial list read as complete is this file's subject matter.
#
# -H, not -L, and not by default. A pkgbase repository carries a `latest'
# symlink beside the versioned directory it points at, so -L would descend both
# and find every package twice -- and the duplicate check below would then
# refuse every correct release. The cost is the boundary: a package living
# under a symlinked subdirectory OTHER than that one is not opened, and a leak
# there would pass. Nothing in the layout make(1) produces puts one there.
_hits=$(find -H "$REPO" \( -type f -o -type l \) \
    -name "${PREFIX}-nested-tests-${VERSION}.pkg") || {
	echo "$PROGRAM: cannot list $REPO" >&2
	exit 2
}
# Counted by asking find for one line per match, not by counting lines of the
# paths: the newline guard above covers the repository path itself, but a
# DIRECTORY beneath it holding a newline would otherwise split one package into
# two and refuse a correct release for a duplicate that does not exist.
_n=$(find -H "$REPO" \( -type f -o -type l \) \
    -name "${PREFIX}-nested-tests-${VERSION}.pkg" -exec printf 'x\n' \; |
    grep -c .) || _n=0
if [ "$_n" -gt 1 ]; then
	echo "$PROGRAM: more than one ${PREFIX}-nested-tests-${VERSION}.pkg:" >&2
	printf '%s\n' "$_hits" | sed 's/^/    /' >&2
	echo "$PROGRAM: a release that offers the same package twice is wrong" >&2
	echo "$PROGRAM: whichever copy is correct: which one a machine installs" >&2
	echo "$PROGRAM: depends on where it looked. Remove the stale one." >&2
	exit 1
fi
# find printed one line per match above; if the text it printed does not have
# that many lines, a matched PATH contains a newline. Carrying it further would
# split one package into two -- and in the loop below, where IFS is a newline,
# the package would not compare equal to itself and would be scanned as a
# bystander, reporting its own contents as a leak and refusing a correct
# release. Refused here instead, with the reason.
_hlines=$(printf '%s' "$_hits" | grep -c .) || _hlines=0
if [ "$_hlines" -ne "$_n" ]; then
	echo "$PROGRAM: a package path beneath $REPO contains a newline:" >&2
	printf '%s\n' "$_hits" | sed 's/^/    /' >&2
	echo "$PROGRAM: package paths are handled a line at a time here, so" >&2
	echo "$PROGRAM: this repository cannot be scanned correctly." >&2
	exit 2
fi
NT=$_hits

# Package members, with the leading ./ or / that different tar writers emit
# normalised away, and pkg(8)'s own two metadata entries and directory entries
# dropped -- they are not installed files. Matched exactly rather than as a
# leading '+', so a real file named +something outside the tree is still seen
# as the stray it is.
#
# tar's own exit status is taken before anything is filtered. In a pipeline the
# status belongs to the last command, so a tar that could not read the archive
# and a tar that read an empty one both arrive as "no lines" -- and this whole
# file exists because "the check could not look" must not become "the check
# found nothing".
members() {
	_terr=$(mktemp) || {
		echo "$PROGRAM: cannot create a temporary file" >&2
		return 2
	}
	if ! _raw=$(tar -tf "$1" 2>"$_terr"); then
		echo "$PROGRAM: cannot read $1" >&2
		sed 's/^/    /' "$_terr" >&2
		rm -f "$_terr"
		return 2
	fi
	rm -f "$_terr"
	# The empty-line filter is not cosmetic and has no test, which is worth
	# saying rather than leaving as a gap. `tar -cf ... .' writes a "./"
	# member; normalising the leading "./" turns it into an empty line, and
	# that line passes both of the other filters. It cannot change a verdict
	# today only because a stray list consisting of nothing but one newline
	# collapses to the empty string in $( ), so `[ -n "$STRAY" ]' is false --
	# two accidents stacked, and no way to observe the first through this
	# script's own interface. Removed here so neither is load-bearing.
	#
	# The filters' status is deliberately discarded, and only theirs: grep
	# exits 1 when nothing survives, and for a package holding only pkg's own
	# +MANIFEST entries "nothing survives" is the true answer, not a failure.
	# tar's status was taken above, where a real failure lives, so nothing is
	# being swallowed here that could mean "I could not look". Measured on a
	# build host: this tar exits 1 on a truncated archive and on a file that
	# is not an archive, and 0 with no members only on an empty file -- so
	# "read and carries no files" is never a misreport of "could not read".
	# -a and LC_ALL=C: GNU grep under a UTF-8 locale replaces its whole
	# output with "Binary file ... matches" when a member name carries an
	# invalid byte sequence, and every real member would vanish -- a leak
	# would read as no leak. FreeBSD grep decides on NUL alone, which a tar
	# member name cannot contain, so this is unreachable on the build hosts;
	# it is set so the answer does not depend on where the build ran.
	# One command, one status.
	#
	# This was five filters in a pipeline, and a pipeline reports only its
	# last command -- so a failure in the sed or in any earlier grep left
	# the final grep with empty input and exit 1, which reads as "looked
	# and found nothing" from a stage that never looked. awk normalises and
	# filters in one process: a real failure is a non-zero status, an empty
	# result is an empty result, and there is no third thing to confuse
	# them with.
	#
	# LC_ALL=C for the same reason the greps had it: a member name carrying
	# an invalid byte sequence must not change what the tool does.
	_list=$(printf '%s\n' "$_raw" | LC_ALL=C awk '
		{ sub(/^\.\//, ""); sub(/^\//, "") }
		$0 == "+MANIFEST" || $0 == "+COMPACT_MANIFEST" { next }
		/\/$/ { next }
		$0 == "" { next }
		{ print }
	') || {
		echo "$PROGRAM: reading the member list of $1 failed" >&2
		return 2
	}
	printf '%s' "$_list"
}

if [ -z "$NT" ]; then
	echo "$PROGRAM: no ${PREFIX}-nested-tests-${VERSION}.pkg in $REPO" >&2
	echo "$PROGRAM: the harness has nowhere to be installed from -- the" >&2
	echo "$PROGRAM: published route is an overlay and cannot take the base" >&2
	echo "$PROGRAM: test suite." >&2
	exit 1
fi

# An unreadable archive and an empty one reach different conclusions: members()
# has already said which it was on stderr when it fails.
NT_MEMBERS=$(members "$NT") || exit 2

# A path that climbs out of the tree it appears to be in.
#
# Every judgement below is a prefix match, and a prefix match is not a
# containment test: usr/tests/sys/vmm/nested/../../../etc/passwd begins with
# the tree and lands in /etc. Such a member would be counted as part of the
# harness, and the same member inside another package would not be seen as the
# leak it is. Refused rather than normalised -- a package built from our own
# tree has no reason to carry one, so its presence is a fault to look at and
# not a shape to accommodate.
check_no_dotdot() {
	_ddrc=0
	_dd=$(printf '%s\n' "$2" |
	    LC_ALL=C grep -a -E '(^|/)\.\.(/|$)') || _ddrc=$?
	if [ "$_ddrc" -gt 1 ]; then
		echo "$PROGRAM: could not scan the member list of $1" >&2
		exit 2
	fi
	[ -n "$_dd" ] || return 0
	echo "$PROGRAM: $1 carries a member that climbs out of its own path:" >&2
	printf '%s\n' "$_dd" | head -10 | sed 's/^/    /' >&2
	echo "$PROGRAM: every check here is a prefix match, and a path with" >&2
	echo "$PROGRAM: .. in it is not where it appears to be." >&2
	exit 1
}
check_no_dotdot "${NT##*/}" "$NT_MEMBERS"
if [ -z "$NT_MEMBERS" ]; then
	echo "$PROGRAM: $NT was read and carries no files" >&2
	exit 1
fi

# grep exits 1 for "no lines matched" and 2 for a real error, and `|| true'
# would fold the second into the first -- the collapse members() refuses two
# screens up. Cheap to keep consistent, and inconsistency here is how the
# standard stops being one.
_src=0
STRAY=$(printf '%s\n' "$NT_MEMBERS" | LC_ALL=C grep -a -v "^${TREE}") || _src=$?
if [ "$_src" -gt 1 ]; then
	echo "$PROGRAM: could not scan the member list of ${NT##*/}" >&2
	exit 2
fi
if [ -n "$STRAY" ]; then
	echo "$PROGRAM: ${PREFIX}-nested-tests carries files outside ${TREE}:" >&2
	printf '%s\n' "$STRAY" | head -10 | sed 's/^/    /' >&2
	exit 1
fi

# The other direction, which is what a missing PACKAGE line actually produces.
#
# Every other package of this release is examined, not merely -tests. A
# directory whose PACKAGE line says nested-test, or vmm-tests, or anything else
# mistyped, lands in a third package and splits the Kyuafile tree exactly the
# same way -- and checking only the one package we expected the files to fall
# into would report that as correct. Matched on the VERSION alone rather than
# on our prefix too: a package built into the same repository under another
# prefix is still a package of this release, and scanning only our own would
# leave the header's claim wider than the code. The -dbg packages need no
# special case: their members are under usr/lib/debug and do not match.
#
# Listing every package costs about sixteen seconds over a 527-package release,
# measured, against a build of about forty minutes. That is the price of the
# check being able to find a package nobody predicted, which is the only kind
# worth finding here.
# Split on newlines only and with globbing off, so a repository path holding a
# space or a bracket is examined rather than torn into pieces -- and the loop
# stays in this shell, because a `find | while read' pipeline would put it in a
# subshell where what it learns cannot get back out.
# Unsorted first, so the status belongs to find rather than to sort: a
# pipeline reports only its last command, and a find that gave up half way
# would arrive here as a short list with a clean status.
_others=$(find -H "$REPO" \( -type f -o -type l \) \
    -name "*-${VERSION}.pkg") || {
	echo "$PROGRAM: cannot list $REPO" >&2
	exit 2
}
_onum=$(find -H "$REPO" \( -type f -o -type l \) -name "*-${VERSION}.pkg" \
    -exec printf 'x\n' \; | grep -c .) || _onum=0
_olines=$(printf '%s' "$_others" | grep -c .) || _olines=0
if [ "$_olines" -ne "$_onum" ]; then
	echo "$PROGRAM: a package path beneath $REPO contains a newline." >&2
	echo "$PROGRAM: package paths are handled a line at a time here, so" >&2
	echo "$PROGRAM: this repository cannot be scanned correctly." >&2
	exit 2
fi
_others=$(printf '%s\n' "$_others" | sort)
LEAKED_IN=""
_oldifs=$IFS
IFS='
'
set -f
for _p in $_others; do
	[ "$_p" = "$NT" ] && continue
	_m=$(members "$_p") || exit 2
	check_no_dotdot "${_p##*/}" "$_m"
	_lrc=0
	_leak=$(printf '%s\n' "$_m" | LC_ALL=C grep -a "^${TREE}") || _lrc=$?
	if [ "$_lrc" -gt 1 ]; then
		echo "$PROGRAM: could not scan the member list of ${_p##*/}" >&2
		exit 2
	fi
	[ -n "$_leak" ] || continue
	echo "$PROGRAM: ${_p##*/} carries part of ${TREE}:" >&2
	printf '%s\n' "$_leak" | head -10 | sed 's/^/    /' >&2
	LEAKED_IN="$LEAKED_IN ${_p##*/}"
done
set +f
IFS=$_oldifs
if [ -n "$LEAKED_IN" ]; then
	echo "$PROGRAM: a directory under that tree has the wrong PACKAGE, or" >&2
	echo "$PROGRAM: none, and took bsd.test.mk's default of tests." >&2
	echo "$PROGRAM: The packages would split the Kyuafile tree between them." >&2
	exit 1
fi

N=$(printf '%s\n' "$NT_MEMBERS" | LC_ALL=C grep -a -c "^${TREE}")
echo "$PROGRAM: nested-tests carries $N files, all under ${TREE}, and no"
echo "$PROGRAM: other package of this release carries any of it."
exit 0
