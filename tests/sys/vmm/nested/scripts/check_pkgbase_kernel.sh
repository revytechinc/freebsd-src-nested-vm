#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Answer one question: was this pkgbase repository built from THIS kernel?
#
# A release is two media targets over one object directory, and building the
# package repository twice costs about nineteen minutes and produces a second
# kernel -- newvers.sh embeds a build counter and a timestamp, so two runs over
# identical source do not yield identical bytes. Reusing the first target's
# repository saves the time and keeps the release down to one kernel, but only
# if reuse is granted on proof.
#
# "The directory exists" is not proof. That reasoning is what let make skip the
# pkgbase-repo target and report success over four packages, and it must not
# return in a different costume. So the proof here is the kernel binary itself,
# compared byte for byte. A repository left behind by a failed or older run
# carries a different kernel and is refused.
#
# Two independent guards, not one:
#   - the package is looked up by a filename carrying the release version, so a
#     repository built for another release is not even found;
#   - the kernel inside it must be byte-identical to the kernel given.
#
# Exit 0 to reuse, 1 to rebuild. Every refusal prints its reason, because a
# silent refusal here reads as "the check is not running".

set -eu

REPO=""
KERNEL=""
PREFIX=""
VERSION=""

usage() {
	cat >&2 <<'USAGE'
usage: check_pkgbase_kernel.sh -r <pkgbase-repo dir> -k <kernel binary>
                               -p <package name prefix> -v <package version>

Exits 0 if the repository's kernel package contains exactly the given kernel
binary, 1 otherwise. Prints the reason either way.
USAGE
	exit 2
}

while getopts "r:k:p:v:" _o; do
	case "$_o" in
	r) REPO=$OPTARG ;;
	k) KERNEL=$OPTARG ;;
	p) PREFIX=$OPTARG ;;
	v) VERSION=$OPTARG ;;
	*) usage ;;
	esac
done

[ -n "$REPO" ] && [ -n "$KERNEL" ] && [ -n "$PREFIX" ] && [ -n "$VERSION" ] || usage

refuse() {
	echo "pkgbase-repo reuse refused: $1"
	exit 1
}

# PREFIX and VERSION are pasted into a `find -name' pattern, where `*', `?'
# and `[' are glob metacharacters rather than literals. A version of `*' would
# match the first .pkg the walk reaches and the answer would be about some
# other archive entirely -- a reuse decision made on the wrong file, which is
# the one outcome this script exists to prevent. Both are package-name
# components, so the allowed characters are exactly a package name's.
for _f in "$PREFIX" "$VERSION"; do
	case "$_f" in
	*[!0-9A-Za-z._-]*)
		refuse "$_f is not a package-name component" ;;
	esac
done

[ -d "$REPO" ] || refuse "no repository at $REPO"
[ -f "$KERNEL" ] || refuse "no kernel binary at $KERNEL to compare against"

# By version, so a repository built for a different release cannot match. The
# name is the first guard and the bytes are the second; neither alone is
# enough, because a filename is a label and a matching kernel in a repository
# named for another release would still be the wrong repository to publish.
# Every match, not the first one the walk reaches. A repository holding more
# than one ABI subtree -- a stale FreeBSD:15:amd64 beside the current
# FreeBSD:16:amd64, say -- offers several packages of this name, and taking
# whichever came first would compare an arbitrary one and, on a mismatch,
# delete a repository that did contain the right package. An ambiguous
# repository is not one to reuse silently.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pkbk.XXXXXX") || refuse "cannot make a work directory"
trap 'rm -rf "$WORK"' EXIT

# find's own failure is kept apart from find finding nothing. Redirecting its
# errors away and treating a non-zero status as "no package" makes an
# unreadable directory print the same line as an empty one, and those need
# different answers from whoever reads it: one is a repository to rebuild, the
# other is a permission to fix.
_ferr="$WORK/find.err"
if ! _matches=$(find "$REPO" -type f \
    -name "${PREFIX}-kernel-generic-${VERSION}.pkg" 2>"$_ferr"); then
	refuse "cannot search $REPO: $(tr '\n' ' ' < "$_ferr")"
fi
# find complaining while still succeeding is reported, not treated as a
# refusal. A symlink loop notice is not a reason to spend nineteen minutes
# rebuilding a repository that was found -- but it is worth a reader seeing,
# because the next thing it might be is a directory that was skipped.
if [ -s "$_ferr" ]; then
	echo "note: $(tr '\n' ' ' < "$_ferr")"
fi
_n=$(printf '%s' "$_matches" | grep -c .) || _n=0
[ "$_n" -gt 0 ] || refuse "no ${PREFIX}-kernel-generic-${VERSION}.pkg in $REPO"
if [ "$_n" -gt 1 ]; then
	refuse "$REPO holds $_n packages named ${PREFIX}-kernel-generic-${VERSION}.pkg;
  which one the release would ship is not decidable from here:
$(printf '%s\n' "$_matches" | sed 's/^/    /')"
fi
# A path with whitespace in it would come apart at the next command and be
# reported as an unreadable package, which is a true statement about the wrong
# problem. pkgbase never generates one; say so rather than let it through.
case "$_matches" in
*[[:space:]]*)	refuse "the package path contains whitespace: $_matches" ;;
esac
PKG=$_matches


# Name the member exactly rather than extracting through a wildcard. Package
# members are stored with a leading `/', which bsdtar strips on extraction, so
# a pattern anchored either way matches only one of the two spellings -- and
# GNU tar needs --wildcards for a pattern at all, which bsdtar does not accept.
# Reading the table of contents first sidesteps both: whatever spelling the
# package uses is the spelling handed back to tar.
# The table of contents to a file FIRST, with its own status checked. Piping
# tar straight into grep hides tar's failure: grep succeeds or fails on empty
# input either way, and a corrupt or truncated package then reports "has no
# boot/kernel/kernel member" -- a true statement about the wrong problem, in a
# script whose whole contract is that every refusal names its real reason.
# No `--' before the archive: `-f' consumes the very next argument, so
# `tar -tf -- "$PKG"' asks tar to read an archive literally named `--'.
# It is needed on the extraction below, where the member name is positional
# and comes from archive content rather than from this script.
if ! tar -tf "$PKG" > "$WORK/toc" 2>/dev/null; then
	refuse "$PKG is not a readable package"
fi
# The member name EXACTLY, not "anything ending in boot/kernel/kernel".
#
# A suffix match accepts a decoy: a package can list `./decoy/boot/kernel/
# kernel' holding this build's kernel ahead of the real member holding another
# one, and the first match then grants reuse for a repository that ships the
# other kernel -- the precise outcome this script exists to prevent. pkgbase
# stores the file at one place, with or without a leading slash, so those two
# spellings are the whole set.
MEMBER=$(grep -m1 -E '^/?boot/kernel/kernel$' "$WORK/toc") || MEMBER=""
[ -n "$MEMBER" ] || refuse "$PKG has no boot/kernel/kernel member"

# A member name is archive CONTENT, and content that begins with a dash becomes
# an option when it reaches a command. `--' ends option parsing, and a leading
# dash is refused outright rather than relied on `--' to neutralise: a package
# carrying such a member is malformed, not merely awkward to quote.
case "$MEMBER" in
-*)	refuse "$PKG names a member beginning with a dash: $MEMBER" ;;
esac

# One member, not the whole package. Unpacking a kernel package copies hundreds
# of megabytes to answer a question about a single file.
#
# And capped, because a package here is untrusted content: it may be a
# leftover, or from another repository entirely. Without a bound, an archive
# whose kernel member is enormous fills the working filesystem before cmp ever
# runs. The bound is the only size that can possibly matter -- a megabyte past
# the kernel being compared against, since anything longer already differs and
# `cmp' will say so on the truncated copy.
# `head -c', not `dd bs=... count=...'. dd counts READS, not bytes, and a read
# from a pipe returns whatever happens to be buffered rather than a full block
# -- so a block-counted dd on a pipe stops early and hands back a truncated
# file that looks complete. Measured: a 31MB kernel came through as a few
# hundred kilobytes, and the check then refused a repository that was
# perfectly good. Small fixtures never showed it, because one read covers them.
# tar's status, not the pipeline's. A pipeline reports its LAST command, so
# `tar ... | head' reports head -- which succeeds happily on a stream that
# stopped early because the archive was truncated or would not decompress. The
# comparison then fails on a partial file and the refusal blames the kernel
# instead of the package, which is the one thing this script must not do.
_want=$(wc -c < "$KERNEL" | tr -d ' ')
_tarrc="$WORK/tar.rc"
{ tar -xOf "$PKG" -- "$MEMBER" 2>/dev/null; echo $? > "$_tarrc"; } |
    head -c $(( _want + 1 )) > "$WORK/kernel"
# Empty is its own case, not a missing status to treat as failure. The
# compound that records it is itself in the pipeline, so when head closes the
# pipe the shell can be killed before `echo $?' ever runs -- and reading that
# as "tar exited <nothing>" would refuse a perfectly good package. What
# actually decides it is whether the copy reached the cap, which the branch
# below tests either way.
_rc=$(cat "$_tarrc" 2>/dev/null) || _rc=""
[ -n "$_rc" ] || _rc=141
# A member longer than the cap makes head close the pipe, and tar dies of
# SIGPIPE on its next write. That is this script CHOOSING to stop reading, not
# a bad archive, so those two statuses are the expected ones -- 141 where the
# shell reports 128+SIGPIPE, 13 where tar reports EPIPE itself.
# A broken-pipe status is only legitimate when head really did close the pipe,
# and head only closes it after taking its full cap. If tar died of SIGPIPE
# with LESS than that written, the pipe closed for some other reason and the
# copy is a fragment -- which would go on to fail the comparison and blame the
# kernel for a truncated package.
_got=$(wc -c < "$WORK/kernel" | tr -d ' ')
case "$_rc" in
0)	;;
13|141)
	if [ "$_got" -ne $(( _want + 1 )) ]; then
		refuse "$PKG stopped short of $MEMBER after $_got bytes"
	fi ;;
*)	refuse "$PKG would not yield $MEMBER (tar exited $_rc)" ;;
esac
[ -s "$WORK/kernel" ] || refuse "$MEMBER in $PKG is empty"

if cmp -s "$WORK/kernel" "$KERNEL"; then
	echo "pkgbase-repo reuse granted: $PKG carries this build's kernel"
	exit 0
fi

refuse "$PKG carries a different kernel than $KERNEL"
