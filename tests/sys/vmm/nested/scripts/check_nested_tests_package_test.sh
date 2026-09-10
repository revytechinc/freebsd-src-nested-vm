#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Unit tests for check_nested_tests_package.sh.
#
# Both directions are exercised. A gate tested only where it blocks is tested
# only in the half that cannot hurt anyone: the case that matters here is the
# one where it must ALLOW a correct release, because a check that refuses
# everything gets switched off within a day.

set -eu

PROGRAM=${0##*/}
SCRIPTDIR=$(cd "$(dirname "$0")" && pwd)
CHECK="$SCRIPTDIR/check_nested_tests_package.sh"
[ -x "$CHECK" ] || { echo "$PROGRAM: not executable: $CHECK" >&2; exit 1; }

WORK=$(mktemp -d) || exit 1
# Every rm in this file is rooted here, so this is the one variable that must
# never be empty: an empty $WORK turns `rm -rf "$WORK/x"' into `rm -rf /x'.
# The rule is older than this file -- a deploy script that computed a bundle
# name from a failed build got an empty variable and deleted every bundle in
# the webroot.
case "$WORK" in
/*/*) ;;
*)	echo "$PROGRAM: refusing to run with WORK=$WORK" >&2; exit 1 ;;
esac
trap 'rm -rf "$WORK"' EXIT INT TERM

PREFIX=CloudBSD
VERSION=16.0.20260910.deepnest17
TREE=usr/tests/sys/vmm/nested

# Tallies live in files, not in variables.
#
# A case that needs a different working directory runs in a subshell, and a
# variable incremented there is discarded when the subshell exits -- so a row
# printed FAIL while the summary said "0 failed", which is the worst result a
# test suite can produce. A file is shared by every subshell.
_PASSF=$WORK/.pass
_FAILF=$WORK/.fail
_SKIPF=$WORK/.skip
: > "$_PASSF"
: > "$_FAILF"
: > "$_SKIPF"

_tally() { echo x >> "$1"; }
_count() { wc -l < "$1" | tr -d ' '; }

# Build a .pkg (a tar archive, which is what pkg(8) writes) whose members are
# the paths given on stdin.
mkpkg() {
	_out=$1
	_root=$WORK/root.$$
	rm -rf "$_root"
	while read -r _m; do
		[ -n "$_m" ] || continue
		case "$_m" in
		*/)	mkdir -p "$_root/$_m" ;;
		*)	mkdir -p "$_root/$(dirname "$_m")"; echo x > "$_root/$_m" ;;
		esac
	done
	( cd "$_root" && tar -cf "$_out" . )
	rm -rf "$_root"
}

# One case: a repository directory, the expected exit status, a name, and
# optionally a fragment the output must contain.
#
# The status alone is a weak assertion: several conditions share each value, so
# "refused for the named reason" and "refused for any reason" look identical
# without a fragment. Exercised: mistaking the -dbg package for the real one
# makes case 7 refuse with the wrong message, and only the fragment catches it.
# The three values are 0 the boundary holds, 1 it does not, 2 the check could
# not be carried out -- so an unreadable archive is 2 and one that was read and
# is empty is 1.
run_case() {
	_name=$1 _repo=$2 _want=$3 _msg=${4:-}
	set +e
	_out=$("$CHECK" -r "$_repo" -p "$PREFIX" -v "$VERSION" 2>&1)
	_got=$?
	set -e
	if [ -n "$_msg" ] && [ "$_got" -eq "$_want" ]; then
		case "$_out" in
		*"$_msg"*) ;;
		*)
			_tally "$_FAILF"
			printf 'FAIL  %-52s exit %s but not %s\n' "$_name" "$_got" "$_msg"
			printf '%s\n' "$_out" | sed 's/^/        /'
			return
			;;
		esac
	fi
	if [ "$_got" -eq "$_want" ]; then
		_tally "$_PASSF"
		printf 'ok    %-52s (exit %s)\n' "$_name" "$_got"
	else
		_tally "$_FAILF"
		printf 'FAIL  %-52s want %s got %s\n' "$_name" "$_want" "$_got"
		printf '%s\n' "$_out" | sed 's/^/        /'
	fi
}

newrepo() {
	_r=$WORK/$1
	rm -rf "$_r"
	mkdir -p "$_r"
	echo "$_r"
}

# 1. The allow direction: a correct release.
R=$(newrepo good)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
$TREE/nested_utils.subr
$TREE/stats/schema.sql
$TREE/stats/nested_stats/store.py
EOF
mkpkg "$R/${PREFIX}-tests-${VERSION}.pkg" <<EOF
usr/tests/sys/vmm/Kyuafile
usr/tests/sys/vmm/utils.subr
usr/tests/lib/libc/Kyuafile
EOF
run_case "correct release" "$R" 0

# 2. The regression this exists to catch: a directory fell back to PACKAGE=tests.
R=$(newrepo leak)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
$TREE/nested_utils.subr
EOF
mkpkg "$R/${PREFIX}-tests-${VERSION}.pkg" <<EOF
usr/tests/sys/vmm/Kyuafile
$TREE/newdir/Kyuafile
$TREE/newdir/some_test.sh
EOF
run_case "a nested directory left in -tests" "$R" 1 "carries part of"

# 3. The other direction: nested-tests grew something outside its tree.
R=$(newrepo stray)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
usr/bin/somethingelse
EOF
run_case "nested-tests carries a file outside the tree" "$R" 1 "outside"

# 4. No nested-tests package at all -- the harness cannot be installed.
R=$(newrepo absent)
mkpkg "$R/${PREFIX}-tests-${VERSION}.pkg" <<EOF
usr/tests/sys/vmm/Kyuafile
EOF
run_case "no nested-tests package" "$R" 1 "no CloudBSD-nested-tests"

# 5. A release with no base tests package is still correct.
R=$(newrepo notests)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
run_case "no -tests package present" "$R" 0

# 6. A package from an older release must not be accepted for this one.
R=$(newrepo oldversion)
mkpkg "$R/${PREFIX}-nested-tests-16.0.20260910.deepnest16.pkg" <<EOF
$TREE/Kyuafile
EOF
run_case "only an older release's package" "$R" 1 "no CloudBSD-nested-tests"

# 7. The -dbg package must not be mistaken for the package itself. Its members
#    live under /usr/lib/debug, so accepting it would fail for the wrong reason
#    -- or, worse, pass.
R=$(newrepo dbgdecoy)
mkpkg "$R/${PREFIX}-nested-tests-dbg-${VERSION}.pkg" <<EOF
usr/lib/debug/$TREE/hw/something.debug
EOF
run_case "only the -dbg package" "$R" 1 "no CloudBSD-nested-tests"

# 8. An archive that cannot be read is not an empty one.
R=$(newrepo corrupt)
dd if=/dev/urandom of="$R/${PREFIX}-nested-tests-${VERSION}.pkg" bs=1024 count=4 \
    2>/dev/null
run_case "unreadable archive is not an answer" "$R" 2 "cannot read"

# 8b. Readable and empty is a different fact, and gets a different message.
R=$(newrepo emptyarchive)
_e=$WORK/emptyroot; rm -rf "$_e"; mkdir -p "$_e"
( cd "$_e" && tar -cf "$R/${PREFIX}-nested-tests-${VERSION}.pkg" -T /dev/null )
run_case "readable but empty says so" "$R" 1 "carries no files"

# 9. Leading ./ from tar, directory entries and pkg's own metadata are not
#    files and must not be mistaken for strays.
R=$(newrepo normalise)
_root=$WORK/nroot
rm -rf "$_root"; mkdir -p "$_root/$TREE/stats"
echo x > "$_root/$TREE/Kyuafile"
echo x > "$_root/$TREE/stats/schema.sql"
echo '{}' > "$_root/+MANIFEST"
echo '{}' > "$_root/+COMPACT_MANIFEST"
( cd "$_root" && tar -cf "$R/${PREFIX}-nested-tests-${VERSION}.pkg" . )
run_case "./ prefixes, directories and +MANIFEST ignored" "$R" 0

# 9b. A mistyped PACKAGE line puts the files in a third package entirely. A
#     check that looked only in -tests would call this correct.
R=$(newrepo thirdpackage)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
mkpkg "$R/${PREFIX}-vmm-tests-${VERSION}.pkg" <<EOF
$TREE/newdir/Kyuafile
$TREE/newdir/some_test.sh
EOF
run_case "a nested directory in a third package" "$R" 1 "vmm-tests"

# 9c. The -dbg package's members live under usr/lib/debug and are not a leak.
R=$(newrepo dbgalongside)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
mkpkg "$R/${PREFIX}-nested-tests-dbg-${VERSION}.pkg" <<EOF
usr/lib/debug/$TREE/hw/something.debug
EOF
run_case "the -dbg package alongside is not a leak" "$R" 0

# 9d. A package holding only pkg's own metadata is empty, not unreadable.
R=$(newrepo manifestonly)
_m=$WORK/mroot; rm -rf "$_m"; mkdir -p "$_m"
echo '{}' > "$_m/+MANIFEST"
echo '{}' > "$_m/+COMPACT_MANIFEST"
( cd "$_m" && tar -cf "$R/${PREFIX}-nested-tests-${VERSION}.pkg" . )
run_case "nested-tests holding only +MANIFEST" "$R" 1 "carries no files"

# 9e. And a manifest-only BYSTANDER package must not fail the scan: it has no
#     members to leak, and treating "no members" as an error would refuse a
#     correct release.
R=$(newrepo manifestbystander)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
_m=$WORK/mroot2; rm -rf "$_m"; mkdir -p "$_m"
echo '{}' > "$_m/+MANIFEST"
( cd "$_m" && tar -cf "$R/${PREFIX}-emptyish-${VERSION}.pkg" . )
run_case "a manifest-only bystander package" "$R" 0

# 9f. Two copies of the package under one repository is a repository fault, and
#     must not be reported as a missing PACKAGE line in the second copy.
R=$(newrepo duplicate)
mkdir -p "$R/sub"
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
mkpkg "$R/sub/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
run_case "two copies of the nested-tests package" "$R" 1 "more than one"

# 9g. A repository path holding a space must be examined, not torn apart.
R=$(newrepo "repo with space")
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
mkpkg "$R/${PREFIX}-vmm-tests-${VERSION}.pkg" <<EOF
$TREE/newdir/Kyuafile
EOF
run_case "a repository path holding a space" "$R" 1 "vmm-tests"

# 9h. A repository handed in as a symlink is descended, not refused. A false
#     refusal on a correct release is how a gate stops being run at all.
R=$(newrepo linktarget)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
ln -s "$R" "$WORK/repolink"
run_case "the repository given as a symlink" "$WORK/repolink" 0

# 9i. tar -cf . emits a "./" entry, which normalises to an empty line. This case
#     establishes only that such an entry does not cause a refusal -- it does
#     NOT exercise the filter that removes it, and passes with that filter
#     deleted. It cannot: a stray list consisting of one newline collapses to
#     the empty string in $( ), so the emptiness test is false either way. The
#     filter is kept so that behaviour is not load-bearing; see the note beside
#     it in the checker. Claiming this case covers it would be worse than
#     having no case at all.
R=$(newrepo emptyline)
_el=$WORK/elroot; rm -rf "$_el"; mkdir -p "$_el/$TREE"
echo x > "$_el/$TREE/Kyuafile"
echo x > "$_el/$TREE/zzz_last.sh"
( cd "$_el" && tar -cf "$R/${PREFIX}-nested-tests-${VERSION}.pkg" . ./$TREE/zzz_last.sh )
run_case "a ./ entry does not cause a refusal" "$R" 0

# 9j. A repository path containing a NEWLINE must not be counted as two
#     packages. Counting lines of find's output counts newlines in the paths
#     as well as between them, and the refusal it produces is against a release
#     that is correct.
R=$(newrepo "repo
with newline")
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
run_case "a repository path containing a newline" "$R" 2 "contains a newline"

# 9k. A package present as a symlink is a package. `-type f' alone would skip
#     it, and a leak inside one would pass.
R=$(newrepo symlinkedpkg)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
mkdir -p "$WORK/elsewhere"
mkpkg "$WORK/elsewhere/${PREFIX}-vmm-tests-${VERSION}.pkg" <<EOF
$TREE/newdir/Kyuafile
EOF
ln -s "$WORK/elsewhere/${PREFIX}-vmm-tests-${VERSION}.pkg" \
    "$R/${PREFIX}-vmm-tests-${VERSION}.pkg"
run_case "a leak inside a symlinked package" "$R" 1 "carries part of"

# 9l. The real pkgbase layout: a versioned directory with a `latest' symlink
#     beside it pointing at the same packages. This is what make(1) produces,
#     and it is why the scan uses -H rather than -L -- with -L every package is
#     found twice and the duplicate check refuses a release that is correct.
R=$(newrepo pkgbaselayout)
mkdir -p "$R/FreeBSD:16:amd64/$VERSION"
mkpkg "$R/FreeBSD:16:amd64/$VERSION/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
mkpkg "$R/FreeBSD:16:amd64/$VERSION/${PREFIX}-tests-${VERSION}.pkg" <<EOF
usr/tests/sys/vmm/Kyuafile
EOF
ln -s "$VERSION" "$R/FreeBSD:16:amd64/latest"
run_case "the real layout, with its latest symlink" "$R" 0

# 10. A repository path that is not a directory is an invocation fault, not a
#     broken release -- the caller branches on 2 to say so.
run_case "repository directory absent" "$WORK/nosuchdir" 2 "not a directory"

# 9m. A repository path beginning with "-" is refused. find would read it as
#     part of its expression and walk the current directory -- and with an
#     operand like -delete that is destructive rather than merely wrong.
mkdir -p "$WORK/./-dashdir"
mkpkg "$WORK/./-dashdir/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
_here=$(pwd)
cd "$WORK"
run_case "a repository path beginning with -" "-dashdir" 2 "begins with"
cd "$_here"

# 9n. Glob metacharacters in the prefix or version are refused: they are
#     interpolated into a -name pattern, where they are not literal, so they
#     would choose which package to examine rather than name it.
R=$(newrepo globby)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
set +e
_out=$("$CHECK" -r "$R" -p "$PREFIX" -v '16.0.*' 2>&1); _got=$?
set -e
if [ "$_got" -eq 2 ] && { case "$_out" in *"glob metacharacters"*) true ;; *) false ;; esac; }; then
	_tally "$_PASSF"; printf 'ok    %-52s (exit 2)\n' "a wildcard version is refused"
else
	_tally "$_FAILF"; printf 'FAIL  %-52s want 2 got %s\n' "a wildcard version is refused" "$_got"
	printf '%s\n' "$_out" | sed 's/^/        /'
fi

# 9o. Only pkg's own two metadata entries are dropped. A real file whose name
#     begins with "+" is a member like any other, and outside the tree it is a
#     stray -- filtering every "^+" would hide it.
R=$(newrepo plusfile)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
+notmetadata
EOF
run_case "a real +file outside the tree is a stray" "$R" 1 "outside"

# 9p. THE PRODUCTION INPUT FORM. Every fixture above is an uncompressed tar,
#     and a real .pkg is zstd-compressed -- so without this case the suite the
#     build trusts to "check the checker" never proves the checker can read a
#     package of the kind it will actually be given. SKIPped loudly rather than
#     silently if this tar cannot write zstd, because a case that vanishes
#     without saying so is a case nobody knows they lost.
_z=$WORK/zroot; rm -rf "$_z"; mkdir -p "$_z/$TREE"
echo x > "$_z/$TREE/Kyuafile"
R=$(newrepo zstd)
if ( cd "$_z" && tar --zstd -cf "$R/${PREFIX}-nested-tests-${VERSION}.pkg" . ) \
    2>/dev/null &&
    tar -tf "$R/${PREFIX}-nested-tests-${VERSION}.pkg" >/dev/null 2>&1; then
	run_case "a zstd-compressed package, as pkg writes them" "$R" 0
else
	_tally "$_SKIPF"
	printf 'SKIP  %-52s this tar cannot write or read zstd\n' \
	    "a zstd-compressed package"
fi

# 9q. A slash in an operand is refused. find -name never matches a slash, so
#     without this the package is simply "not found" and an invocation fault
#     arrives as "the harness has nowhere to be installed from" -- an
#     invocation fault reported as a broken release, which is the collapse
#     this file exists to prevent.
R=$(newrepo slashy)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
set +e
_out=$("$CHECK" -r "$R" -p "$PREFIX" -v "16.0/deepnest17" 2>&1); _got=$?
set -e
if [ "$_got" -eq 2 ] && { case "$_out" in *"metacharacters"*) true ;; *) false ;; esac; }; then
	_tally "$_PASSF"; printf 'ok    %-52s (exit 2)\n' "a slash in the version is refused"
else
	_tally "$_FAILF"; printf 'FAIL  %-52s want 2 got %s\n' "a slash in the version is refused" "$_got"
	printf '%s\n' "$_out" | sed 's/^/        /'
fi

# 9r. A package of this release under ANOTHER prefix is still a package of this
#     release. Scanning only our own prefix would never open it, and a leak
#     into it would pass while the header claimed otherwise.
R=$(newrepo foreignprefix)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
mkpkg "$R/FreeBSD-tests-${VERSION}.pkg" <<EOF
$TREE/newdir/Kyuafile
EOF
run_case "a leak into a package under another prefix" "$R" 1 "carries part of"

# 9s. A newline in a DIRECTORY beneath the repository, not in the repository
#     path itself. The guard above covers only REPO. Left unhandled, the
#     package path is split, the package does not compare equal to itself in
#     the leak loop, and its own contents are reported as a leak -- a correct
#     release refused with a message about a defect that does not exist.
R=$(newrepo nlchild)
mkdir -p "$R/sub
dir"
mkpkg "$R/sub
dir/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
run_case "a newline in a directory beneath the repository" "$R" 2 "contains a newline"

# 9t/9u. Members whose paths climb out of the tree they appear to be in.
#
#     Built with `tar -cPf', because tar normalises ".." away by default -- the
#     obvious fixture produces usr/tests/etc/passwd and tests nothing. -P keeps
#     the path as written, which is the only way to make an archive shaped like
#     the one this guard exists for. SKIPped if this tar will not.
mkpkg_dotdot() {
	_out=$1 _extra=$2
	_r=$WORK/ddroot.$$
	rm -rf "$_r"
	mkdir -p "$_r/$TREE" "$_r/usr/etc"
	echo x > "$_r/$TREE/Kyuafile"
	echo x > "$_r/usr/etc/passwd"
	( cd "$_r" && tar -cPf "$_out" \
	    "$TREE/Kyuafile" $_extra ) 2>/dev/null || return 1
	tar -tf "$_out" 2>/dev/null |
	    LC_ALL=C grep -a -q -E '(^|/)\.\.(/|$)' || return 1
	return 0
}

R=$(newrepo dotdot)
if mkpkg_dotdot "$R/${PREFIX}-nested-tests-${VERSION}.pkg" \
    "$TREE/../../../../etc/passwd"; then
	run_case "a member that climbs out of the tree" "$R" 1 "climbs out"
else
	_tally "$_SKIPF"
	printf 'SKIP  %-52s this tar will not preserve ..\n' \
	    "a member that climbs out of the tree"
fi

R=$(newrepo dotdotbystander)
mkpkg "$R/${PREFIX}-nested-tests-${VERSION}.pkg" <<EOF
$TREE/Kyuafile
EOF
if mkpkg_dotdot "$R/${PREFIX}-tests-${VERSION}.pkg" \
    "$TREE/../../../../etc/passwd"; then
	run_case "a bystander member with .. in its path" "$R" 1 "climbs out"
else
	_tally "$_SKIPF"
	printf 'SKIP  %-52s this tar will not preserve ..\n' \
	    "a bystander member with .. in its path"
fi

# 11. Missing arguments are a usage error, distinct from a failed check.
set +e
"$CHECK" -r "$WORK" -p "$PREFIX" >/dev/null 2>&1
_got=$?
set -e
if [ "$_got" -eq 2 ]; then
	_tally "$_PASSF"; printf 'ok    %-52s (exit 2)\n' "missing -v is a usage error"
else
	_tally "$_FAILF"; printf 'FAIL  %-52s want 2 got %s\n' "missing -v is a usage error" "$_got"
fi

echo
echo "$PROGRAM: $(_count "$_PASSF") passed, $(_count "$_FAILF") failed," \
    "$(_count "$_SKIPF") skipped"
[ "$(_count "$_FAILF")" -eq 0 ]
