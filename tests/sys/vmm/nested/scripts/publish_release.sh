#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# publish_release.sh -- put a built release on the site: packages, media and the
# generated manifest, in one action, with the previous release kept.
#
# Until now this step lived nowhere. The site bundle had a deploy script; media,
# packages and the `latest` symlink were a person following a written procedure.
# That procedure exists because TWO deploy scripts have damaged this system:
#
#   - one computed a bundle name from a build that had FAILED, got an empty
#     variable, and its cleanup expanded to `find ... ! -name '' -delete`. That
#     excludes nothing. It deleted every JS bundle in the webroot and the site
#     went blank.
#   - one ran `cd <dir>` without checking the status. The cd failed on a
#     permission error, so the loop that followed executed in the operator's
#     HOME directory and moved his git repositories, source trees and object
#     directories out from under him.
#
# Every rule below is one of those, or the near miss that followed. They are
# code here rather than a checklist somebody remembers to read.
#
# Usage:
#   publish_release.sh -a <artifact-dir> -p <pkg-repo-dir> -v <version> [-n]
#
#   -a  directory holding the built media (ISOs, .img, .xz) and README.txt
#   -p  the ABI directory of the built package repository (holds <version>/)
#   -v  the release version, e.g. 16.0.20260908.deepnest13
#   -n  dry run: print what WOULD happen and change nothing
#
# Environment:
#   PUBLISH_HOST   host serving the site         (required, no default)
#   PUBLISH_WWW    webroot on that host          (required, no default)
#   PUBLISH_BASE   public URL for verification   (default https://nested.cloudbsd.cat)
#
# The first two have no defaults on purpose: this repository is public, and a
# default naming the serving host and its path would publish the publish target
# to everyone who clones it.
set -eu

PROGRAM="${0##*/}"
SCRIPTDIR=$(cd "$(dirname "$0")" && pwd -P)

ART=""
PKG=""
VERSION=""
DRY=0

while getopts a:p:v:n o; do
	case "$o" in
	a)	ART=$OPTARG ;;
	p)	PKG=$OPTARG ;;
	v)	VERSION=$OPTARG ;;
	n)	DRY=1 ;;
	*)	echo "usage: $PROGRAM -a <artifact-dir> -p <pkg-repo-dir> -v <version> [-n]" >&2
		exit 2 ;;
	esac
done

# No default host or path in this file. The repository is public, and a default
# naming the serving host and its jail path publishes the publish target to
# anyone who clones it. They come from the environment or the run fails.
HOST=${PUBLISH_HOST:-}
WWW=${PUBLISH_WWW:-}
BASE=${PUBLISH_BASE:-https://nested.cloudbsd.cat}
case "$BASE" in
https://[0-9A-Za-z]*)	;;
*)	echo "$PROGRAM: PUBLISH_BASE must be an https:// URL: $BASE" >&2; exit 2 ;;
esac
case "$BASE" in
*[!0-9A-Za-z._:/-]*)
	echo "$PROGRAM: PUBLISH_BASE contains characters that are not allowed: $BASE" >&2
	exit 2 ;;
esac
ABI=${ABI:-FreeBSD:16:amd64}

[ -n "$HOST" ] || { echo "$PROGRAM: set PUBLISH_HOST (no default: this file is public)" >&2; exit 2; }
[ -n "$WWW" ]  || { echo "$PROGRAM: set PUBLISH_WWW (no default: this file is public)" >&2; exit 2; }

# RULE 1: an empty variable must never reach a destructive command. Checked
# before anything else, and checked for EVERY value that will be interpolated
# into a path -- not just the ones that look dangerous.
for _v in ART PKG VERSION HOST WWW BASE ABI; do
	eval "_val=\${$_v:-}"
	[ -n "$_val" ] || { echo "$PROGRAM: $_v is empty; refusing to touch the webroot" >&2; exit 2; }
done

# RULE 6: whitelist. The version is the only caller-supplied value that reaches
# a path this script creates or removes, and those paths are interpolated into
# commands the REMOTE shell re-parses, so it is constrained twice.
#
# Character class FIRST. A shape check alone is not enough: `*` in a case
# pattern matches spaces and semicolons, so "16.0.20260908.deepnest13; rm -rf /"
# satisfies 16.0.[0-9]*.deepnest[0-9]* and would have been carried into an ssh
# command as a second statement. That is not hypothetical -- it is what the
# first version of this file did, and the test below is what caught it.
# A colon in HOST is not a character problem, it is a semantic one: rsync reads
# host:path and splits on the FIRST colon, so "h:22" or an IPv6 literal sends
# the transfer somewhere other than $WWW, and "h::mod" is daemon syntax.
case "$HOST" in
*:*)	echo "$PROGRAM: PUBLISH_HOST may not contain ':' -- rsync would read it as a path" >&2
	echo "$PROGRAM: use an ssh_config Host alias for a non-default port" >&2
	exit 2 ;;
esac

for _v in VERSION HOST ABI; do
	eval "_val=\${$_v}"
	case "$_val" in
	*[!0-9A-Za-z._:-]*)
		echo "$PROGRAM: $_v contains characters that are not allowed: $_val" >&2
		exit 2 ;;
	-*)	echo "$PROGRAM: $_v may not begin with '-'; ssh and rsync would read it as an option" >&2
		exit 2 ;;
	esac
done
# ABI is interpolated into paths that reach `rm -rf`, so its SHAPE is checked,
# not merely its characters. A dot is legitimate in a version, which means the
# character class alone accepts `..` -- and `$WWW/pkgbase/../$VERSION` escapes
# into the webroot itself. That is a traversal into a recursive delete, reached
# without a single disallowed character.
case "$ABI" in
[A-Za-z0-9]*:[0-9]*:[A-Za-z0-9_]*) ;;
*)	echo "$PROGRAM: ABI is not of the form Name:version:arch: $ABI" >&2; exit 2 ;;
esac

# The webroot is a path, so it may contain slashes -- but not a quote, which
# would end the quoting in the remote command, nor a shell metacharacter.
case "$WWW" in
*[!0-9A-Za-z._/-]*)
	echo "$PROGRAM: PUBLISH_WWW contains characters that are not allowed: $WWW" >&2
	exit 2 ;;
/*)	;;
*)	echo "$PROGRAM: PUBLISH_WWW must be an absolute path" >&2; exit 2 ;;
esac

# `..` anywhere, in any of them. Every one of these is interpolated into a path
# that is created, moved or recursively removed on the serving host.
for _v in VERSION HOST ABI WWW; do
	eval "_val=\${$_v}"
	case "/$_val/" in
	*/../*)	echo "$PROGRAM: $_v contains a '..' component: $_val" >&2
		echo "$PROGRAM: these values are interpolated into paths that get removed" >&2
		exit 2 ;;
	esac
done
# Then the shape, now that the value cannot contain a separator.
case "$VERSION" in
16.0.[0-9]*.deepnest[0-9]*|16.0.[0-9]*.release[0-9]*) ;;
*)	echo "$PROGRAM: refusing an unrecognised version: $VERSION" >&2
	echo "$PROGRAM: expected 16.0.<date>.deepnestN or .releaseN" >&2
	exit 2 ;;
esac

say() { echo "==> $*"; }
would() { if [ "$DRY" = 1 ]; then echo "WOULD: $*"; return 0; fi; return 1; }

# RULE 7: one privileged channel, decided once, rather than doas sprinkled
# through the script. The webroot lives inside a jail whose directory is not
# traversable by the publishing user, so an unprivileged `test -d` reports the
# path missing when it is merely unreadable -- which is exactly the "predicate
# silently reports the wrong thing" case rule 7 exists for.
#
# The command is sent on STDIN rather than as an argument. Wrapping it in
# `doas sh -c '...'` would add a second layer of shell quoting around values
# that are already interpolated, and every layer is another chance to get the
# escaping wrong. `sh -s` reads the script and re-parses nothing extra.
PRIV=""
remote() { printf '%s\n' "$*" | ssh -o BatchMode=yes -- "$HOST" "${PRIV}sh -s"; }

# Decided once, by asking rather than assuming.
if printf 'test -d %s\n' "$WWW" | ssh -o BatchMode=yes -- "$HOST" "sh -s" 2>/dev/null; then
	PRIV=""
	say "the webroot is reachable unprivileged"
elif printf 'test -d %s\n' "$WWW" | ssh -o BatchMode=yes -- "$HOST" "doas sh -s" 2>/dev/null; then
	PRIV="doas "
	RSYNC_PATH="doas rsync"
	say "the webroot needs doas; using it for every remote step"
else
	echo "$PROGRAM: cannot reach $WWW on $HOST, with or without doas" >&2
	exit 1
fi

# RULE 4: assert the layout BEFORE changing anything.
say "checking the local artifacts"
# ART and PKG are rsync SOURCES. rsync reads a source containing a colon before
# any slash as host:path -- the same split already blocked on PUBLISH_HOST -- so
# a local directory named `evil:artifacts` would make the transfer PULL from a
# remote host instead of reading the build output. Requiring an absolute path
# removes the ambiguity: a leading slash means there is always a slash before
# any colon. It also settles the find-predicate case, since a path beginning
# with `/` cannot begin with `-`.
for _v in ART PKG; do
	eval "_val=\${$_v}"
	case "$_val" in
	/*)	;;
	*)	echo "$PROGRAM: $_v must be an absolute path: $_val" >&2
		echo "$PROGRAM: a relative one can be read by rsync as host:path" >&2
		exit 2 ;;
	esac
	case "/$_val/" in
	*/../*)	echo "$PROGRAM: $_v contains a '..' component: $_val" >&2; exit 2 ;;
	esac
done
[ -d "$ART" ] || { echo "$PROGRAM: no such artifact directory: $ART" >&2; exit 1; }
[ -d "$PKG/$VERSION" ] || { echo "$PROGRAM: no such package version: $PKG/$VERSION" >&2; exit 1; }

# The package set must satisfy the release contract. Publishing a repository
# nothing checked is how four packages reached a webroot once.
CONTRACT="$SCRIPTDIR/check_release_contract.sh"
[ -x "$CONTRACT" ] || { echo "$PROGRAM: $CONTRACT missing; refusing to publish unchecked" >&2; exit 2; }
if ! sh "$CONTRACT" -r "$PKG" -v "$VERSION"; then
	echo "$PROGRAM: the package repository does not satisfy the release contract" >&2
	exit 1
fi

# Media: at least one installer image, and every file non-empty. A zero-length
# image uploads perfectly and fails on the machine that boots it.
# Newline-separated with globbing OFF. Unquoted word splitting on find output
# breaks a name containing a space into two paths, and an unquoted expansion is
# still glob-expanded -- a file called `*.iso` would expand to every iso in the
# current directory and publish files this build never produced.
_saveIFS=$IFS
set -f
IFS='
'
_media=$(find -- "$ART" -maxdepth 1 \( -name '*.iso' -o -name '*.img' -o -name '*.xz' \) | sort)
[ -n "$_media" ] || { echo "$PROGRAM: no media in $ART" >&2; exit 1; }
_count=0
for _f in $_media; do
	[ -s "$_f" ] || { echo "$PROGRAM: zero-length artifact: $_f" >&2; exit 1; }
	# A name containing a newline splits into two paths here however carefully
	# IFS is set, and the second becomes an extra rsync source. These names are
	# ours; an unexpected one is refused rather than handled.
	case "${_f##*/}" in
	*[!0-9A-Za-z._-]*)
		echo "$PROGRAM: artifact name has characters we never generate: ${_f##*/}" >&2
		exit 1 ;;
	esac
	_count=$((_count + 1))
done
# The loop must have seen every file find found. If a name contained a newline
# the counts disagree, and that is the case this cannot otherwise detect.
_found=$(find -- "$ART" -maxdepth 1 \( -name '*.iso' -o -name '*.img' -o -name '*.xz' \) |
    wc -l | tr -d ' ')
[ "$_count" = "$_found" ] || {
	echo "$PROGRAM: counted $_count artifacts but find reported $_found;" >&2
	echo "$PROGRAM: a filename probably contains a newline. Refusing." >&2
	exit 1
}
# Restored immediately. Left set, globbing stays OFF for the rest of the run and
# the package step's "$PKG/$VERSION"/*.pkg is handed to ls as a literal string,
# so the count it verifies the transfer against is meaningless.
IFS=$_saveIFS
set +f
say "$_count media files, none empty"

say "checking the remote layout"
remote "test -d '$WWW/pkgbase/$ABI'" || { echo "$PROGRAM: $WWW/pkgbase/$ABI missing on $HOST" >&2; exit 1; }
remote "test -d '$WWW/releases'"     || { echo "$PROGRAM: $WWW/releases missing on $HOST" >&2; exit 1; }

PREV=$(remote "readlink '$WWW/pkgbase/$ABI/latest' 2>/dev/null || true")
PREV=${PREV##*/}
say "currently published: ${PREV:-<none>}"
[ "$PREV" != "$VERSION" ] || say "note: $VERSION is already the published version; this will refresh it"

# ---------------------------------------------------------------- packages
# RULE 3: copy new, verify it is in place, and only then move the pointer.
say "copying packages ($(du -sh "$PKG/$VERSION" | cut -f1))"
if ! would "rsync $PKG/$VERSION -> $HOST:$WWW/pkgbase/$ABI/"; then
	if [ -n "${RSYNC_PATH:-}" ]; then
		rsync -a --delete --rsync-path="$RSYNC_PATH" -- \
		    "$PKG/$VERSION/" "$HOST:$WWW/pkgbase/$ABI/$VERSION.incoming/"
	else
		rsync -a --delete -- "$PKG/$VERSION/" "$HOST:$WWW/pkgbase/$ABI/$VERSION.incoming/"
	fi
	# Rename into place only after the whole transfer succeeded, so an
	# interrupted copy never becomes a half-populated version directory that
	# looks complete.
	# Move aside, rename, restore on failure -- the same shape as the media
	# step. `rm -rf` then `mv` destroys the published version BEFORE the rename,
	# so an interruption between the two leaves nothing to serve and nothing to
	# put back. That matters most on a republish of the same version, which this
	# script explicitly allows.
	if ! remote "set -e
		D='$WWW/pkgbase/$ABI'
		rm -rf \"\$D/$VERSION.old\"
		if [ -d \"\$D/$VERSION\" ]; then mv \"\$D/$VERSION\" \"\$D/$VERSION.old\"; fi
		if ! mv \"\$D/$VERSION.incoming\" \"\$D/$VERSION\"; then
			if [ -d \"\$D/$VERSION.old\" ]; then mv \"\$D/$VERSION.old\" \"\$D/$VERSION\"; fi
			exit 1
		fi
		rm -rf \"\$D/$VERSION.old\""; then
		echo "$PROGRAM: could not put the packages in place; the previous copy of" >&2
		echo "$PROGRAM: $VERSION was restored and nothing was published" >&2
		exit 1
	fi
	# Compare the NAMES that landed against the names that were sent. Two counts
	# can agree at zero: an unmatched glob makes ls error and wc print 0 on both
	# sides, so a transfer that landed nothing compares equal and reads as
	# verified. A name list cannot be satisfied that way.
	# The remote command's STATUS is checked separately from its output. An ssh
	# failure and an empty directory both produce no output, and telling the
	# operator "packages are missing" when the network dropped points at
	# entirely the wrong repair.
	if ! _remote_list=$(remote "cd '$WWW/pkgbase/$ABI/$VERSION' && find . -maxdepth 1 -name '*.pkg' | sed 's|^\./||' | sort"); then
		echo "$PROGRAM: could not list the published packages on $HOST" >&2
		echo "$PROGRAM: this is a connection or path failure, not a missing package" >&2
		exit 1
	fi
	_local_list=$(cd "$PKG/$VERSION" && find . -maxdepth 1 -name '*.pkg' | sed 's|^\./||' | sort)
	_ln=$(printf '%s\n' "$_local_list" | grep -c .)
	[ "$_ln" -gt 0 ] || { echo "$PROGRAM: no packages found locally to publish" >&2; exit 1; }
	if [ "$_remote_list" != "$_local_list" ]; then
		echo "$PROGRAM: what landed is not what was sent." >&2
		_cmp=$(mktemp -d) || exit 1
		printf '%s\n' "$_local_list"  > "$_cmp/local"
		printf '%s\n' "$_remote_list" > "$_cmp/remote"
		comm -23 "$_cmp/local" "$_cmp/remote" | sed 's/^/  missing remotely: /' >&2
		comm -13 "$_cmp/local" "$_cmp/remote" | sed 's/^/  unexpected there: /' >&2
		rm -rf "$_cmp"
		exit 1
	fi
	say "verified $_ln packages in place, by name"
fi

# ------------------------------------------------------------------- media
say "copying media"
RELDIR="$WWW/releases/16.0-CURRENT-amd64"
if ! would "rsync media -> $HOST:$RELDIR/"; then
	# Cleared, not just created. A failure part-way through the upload leaves
	# .incoming populated, and mkdir -p on the next run merges the new files
	# into the old ones and moves the mixture into place as one build.
	remote "rm -rf '$RELDIR.incoming' && mkdir -p '$RELDIR.incoming'"
	# One at a time, quoted, after `--`. An unquoted list splits on spaces, and
	# rsync reads a source beginning with `--` as an OPTION -- a file called
	# --files-from=x.iso sitting in the artifact directory would silently
	# redirect the transfer to another file list.
	_s2=$IFS; set -f; IFS='
'
	for _f in $_media; do
		IFS=$_s2; set +f
		if [ -n "${RSYNC_PATH:-}" ]; then
			rsync -a --rsync-path="$RSYNC_PATH" -- "$_f" "$HOST:$RELDIR.incoming/"
		else
			rsync -a -- "$_f" "$HOST:$RELDIR.incoming/"
		fi
		set -f; IFS='
'
	done
	IFS=$_s2; set +f
	# `if`, not `[ -f ] && rsync`. As the last statement of a loop body under
	# set -e, a false test makes the LOOP exit non-zero and aborts the script --
	# so a missing release.json would kill the publish after the media was
	# uploaded, leaving an orphaned .incoming on the server and the release
	# half-done.
	for _extra in README.txt CHECKSUM.SHA256 CHECKSUM.SHA256.txt release.json; do
		if [ -f "$ART/$_extra" ]; then
			if [ -n "${RSYNC_PATH:-}" ]; then
				rsync -a --rsync-path="$RSYNC_PATH" -- "$ART/$_extra" "$HOST:$RELDIR.incoming/"
			else
				rsync -a -- "$ART/$_extra" "$HOST:$RELDIR.incoming/"
			fi
		fi
	done
	# Keep the outgoing set as the rollback until the new one is verified.
	# Rolled back if the final move fails. Without this the previous release is
	# already aside, the live directory does not exist, and the run carries on to
	# flip `latest` at a release whose media is missing -- the site then serves
	# nothing for it until somebody notices.
	# Do NOT rotate .previous when republishing the SAME version. Re-running a
	# publish -- to fix a verification bug, say -- would otherwise move the
	# just-published media aside and put it straight back, so .previous ends up
	# holding a copy of the release it is supposed to be the rollback FROM. The
	# genuine previous release is then gone. That happened.
	# Whether to rotate is decided from the MEDIA ACTUALLY IN PLACE, not from
	# the package pointer.
	#
	# $PREV is read from the published packages' `latest` symlink, and the two
	# can disagree -- they disagree exactly when a publish failed between the
	# media step and the pointer step, which is the situation a re-run is for.
	# Keyed on $PREV, the retry rotates a second time: the media just published
	# is moved into .previous, and the genuine previous release is gone. The
	# comment above records that happening once already; this is the same loss
	# by a different route.
	#
	# release.json travels with the media and names the commit it was built
	# from, so the media can identify itself. If what is already there is this
	# build, there is nothing to roll back to and nothing to rotate.
	_rotate=yes
	[ "$PREV" = "$VERSION" ] && _rotate=no
	[ "$_rotate" = yes ] || say "republishing $VERSION: keeping the existing rollback untouched"

	# The identity of the media already in place is established INSIDE the same
	# remote script that acts on it.
	#
	# Deciding it on one connection and acting on it on the next is a race with
	# a bad prize: between the two, an overlapping publish can change what is
	# there, and the flag computed a moment ago then either rotates a tree that
	# has become this same build -- replacing the rollback with the thing it
	# was meant to roll back from -- or declines to rotate a tree that has
	# become a different release, overwriting it with no copy kept.
	#
	# The comparison is a checksum of release.json, not a field parsed out of
	# it. release.json carries the commit, the build time and every artifact
	# with its size, so an identical file is an identical build; and a checksum
	# needs no regex escaped through two shells, where a quoting slip returns
	# an empty string, compares unequal, and rotates.
	_heresum=""
	if [ -f "$ART/release.json" ]; then
		_heresum=$(sha256 -q "$ART/release.json" 2>/dev/null) || _heresum=""
		[ -n "$_heresum" ] || _heresum=$(sha256sum "$ART/release.json" 2>/dev/null | cut -d" " -f1)
	fi
	case "$_heresum" in
	""|*[!0-9a-f]*) _heresum="" ;;
	esac
	if ! remote "set -e
		_rotate='$_rotate'
		if [ -n '$_heresum' ] && [ -f '$RELDIR/release.json' ]; then
			_t=\$(sha256 -q '$RELDIR/release.json' 2>/dev/null) || _t=''
			[ -n \"\$_t\" ] || _t=\$(sha256sum '$RELDIR/release.json' 2>/dev/null | cut -d' ' -f1)
			if [ \"\$_t\" = '$_heresum' ]; then
				_rotate=no
				echo 'the media in place is already this build; keeping the existing rollback'
			fi
		fi
		if [ \"\$_rotate\" = yes ]; then
			rm -rf '$RELDIR.previous'
			if [ -d '$RELDIR' ]; then mv '$RELDIR' '$RELDIR.previous'; fi
		else
			rm -rf '$RELDIR.replacing'
			if [ -d '$RELDIR' ]; then mv '$RELDIR' '$RELDIR.replacing'; fi
		fi
		if ! mv '$RELDIR.incoming' '$RELDIR'; then
			if [ \"\$_rotate\" = yes ] && [ -d '$RELDIR.previous' ]; then
				mv '$RELDIR.previous' '$RELDIR'
			elif [ -d '$RELDIR.replacing' ]; then
				mv '$RELDIR.replacing' '$RELDIR'
			fi
			exit 1
		fi
		rm -rf '$RELDIR.replacing'"; then
		echo "$PROGRAM: could not put the new media in place; the previous release" >&2
		echo "$PROGRAM: was restored and nothing was published" >&2
		exit 1
	fi
	# .previous is KEPT on purpose and is not cleaned up here. Media has no
	# per-version directories -- unlike packages, where the previous version
	# remains under its own name -- so this copy is the only rollback that
	# exists. One generation, replaced by the next publish.
	say "media in place, previous kept at $(basename "$RELDIR").previous"
fi

# ------------------------------------------------------- the trust material
# A signed repository is only usable by a client that knows which key to trust,
# and for command-signed repositories that means a FINGERPRINT file. Publishing
# the packages without it leaves every client with signature checking either
# off or wrong, and a wrong one fails SILENTLY -- pkg says the repository is up
# to date and shows nothing in it.
#
# The fingerprint is derived from the catalogue being published, not from a key
# file somebody points at. data.pub inside data.pkg is byte-identical to the
# public half of the key that signed it, so the published fingerprint cannot
# be the fingerprint of a different key than the one that signed the release.
#
# Nothing is published when the catalogue is unsigned. That is not an omission
# to fix later: publishing a fingerprint beside an unsigned repository makes
# every client that follows our instructions see an empty repository.
#
# One window this does not close, stated rather than hidden: the fingerprint is
# served from ONE fixed path shared by every release, because install.sh has to
# be able to fetch it without knowing which release it is about to install. So
# between replacing it here and moving `latest` below, a client still on the
# previous release fetches trust material for the new catalogue. That is
# harmless while the signing key stays the same -- which is the normal case,
# and the only case so far -- and silently presents as an empty repository if
# the key ever changes between releases. Rotating the key therefore needs its
# own procedure, not just another run of this script.
# Initialised before the branches, not inside them. Under `set -u` a path that
# leaves it unset -- a dry run whose generator failed, say -- aborts the script
# where the verification block reads it, which is a long way from the cause.
PUBLISHED_FINGERPRINT=0
_fpsum=""
_cat="$PKG/$VERSION/data.pkg"
_fpsrc="$SCRIPTDIR/gen_repo_fingerprint.sh"
if [ ! -f "$_cat" ]; then
	echo "$PROGRAM: no catalogue at $_cat -- packages were published without one" >&2
	exit 1
fi

# Whether the catalogue is signed decides between publishing a fingerprint and
# DELETING the published one, so it is established positively or not at all.
#
# `tar -tf ... | grep -q` reads a tar failure as "unsigned", because the
# pipeline's status is grep's. A truncated file, an unreadable one, or a tar
# that died would therefore have deleted the live fingerprint of a correctly
# signed release, and every client checking signatures would then see an empty
# repository. So the listing is captured, tar's own status is checked, and
# anything other than a clean answer stops the publish.
if ! _members=$(tar -tf "$_cat" 2>/dev/null); then
	echo "$PROGRAM: cannot list $_cat -- so whether this release is signed" >&2
	echo "$PROGRAM: cannot be established, and the choice between publishing" >&2
	echo "$PROGRAM: a fingerprint and deleting one must not be guessed" >&2
	exit 1
fi
# Both spellings: tar writes "data.pub" or "./data.pub" depending on how the
# archive was created, and only one of them was accepted before.
if printf '%s\n' "$_members" | grep -qxF -e data.pub -e ./data.pub; then
	[ -x "$_fpsrc" ] || [ -f "$_fpsrc" ] || {
		echo "$PROGRAM: the repository is signed but $_fpsrc is missing," >&2
		echo "$PROGRAM: so no fingerprint can be published and every client" >&2
		echo "$PROGRAM: would see an empty repository" >&2
		exit 1; }
	say "repository is signed; publishing the fingerprint"
	_fp=$(mktemp) || exit 1
	if ! sh "$_fpsrc" -c "$_cat" -o "$_fp" >/dev/null; then
		rm -f "$_fp"
		if [ "$DRY" = 1 ]; then
			# A dry run reports; it does not fail. Aborting here would make
			# the one mode that exists to be safe the only one that stops.
			say "WOULD FAIL: cannot derive the fingerprint from $_cat"
			PUBLISHED_FINGERPRINT=0
			_fp=""
		else
			echo "$PROGRAM: could not derive the fingerprint from $_cat" >&2
			exit 1
		fi
	fi
	# The digest that was actually published, kept so the verification below
	# can require THIS value rather than merely a fingerprint-shaped page.
	_fpsum=""
	if [ -n "$_fp" ] && [ -s "$_fp" ]; then
		_fpsum=$(sed -n 's/^fingerprint: *"\([0-9a-f]*\)".*/\1/p' "$_fp")
	fi
	# WRITTEN REMOTELY, not scp'd.
	#
	# scp runs as the login user and cannot write a webroot that needs doas --
	# which this one does, and the script says so twenty lines earlier before
	# using doas for every other remote step. So the packages and the media
	# published fine and the fingerprint failed with "Permission denied",
	# leaving the site serving new media, old packages and no trust material.
	#
	# The file is two lines built from a digest this has already constrained to
	# 64 lowercase hex characters, so generating it on the far side costs
	# nothing and goes through the same privileged path as everything else.
	case "$_fpsum" in
	[0-9a-f]*) ;;
	*) echo "$PROGRAM: refusing to publish a non-hex fingerprint: $_fpsum" >&2; exit 1 ;;
	esac
	case "$_fpsum" in
	*[!0-9a-f]*) echo "$PROGRAM: refusing to publish a non-hex fingerprint" >&2; exit 1 ;;
	esac
	[ "${#_fpsum}" = 64 ] || {
		echo "$PROGRAM: fingerprint is ${#_fpsum} characters, not 64" >&2; exit 1; }
	if [ -n "$_fp" ] && ! would "write the fingerprint on $HOST:$WWW/cloudbsd-fingerprint"; then
		# Written to a temporary name and renamed, so a client fetching during
		# the write gets either the old file or the new one and never half.
		if ! remote "set -e
			printf 'function: sha256\nfingerprint: \"$_fpsum\"\n' \
			    > '$WWW/cloudbsd-fingerprint.incoming'
			chmod 0444 '$WWW/cloudbsd-fingerprint.incoming'
			mv '$WWW/cloudbsd-fingerprint.incoming' '$WWW/cloudbsd-fingerprint'"; then
			rm -f "$_fp"
			remote "rm -f '$WWW/cloudbsd-fingerprint.incoming'" || true
			echo "$PROGRAM: could not publish the fingerprint" >&2
			exit 1
		fi
	fi
	[ -z "$_fp" ] || rm -f "$_fp"
	[ -z "$_fpsum" ] || PUBLISHED_FINGERPRINT=1
else
	say "repository is UNSIGNED; publishing no fingerprint"
	say "  clients will install over HTTPS with no signature check"
	# Remove a fingerprint left by a previous SIGNED release. Leaving it makes
	# every new install configure fingerprint checking against a repository
	# that carries no signature, and see an empty repository for it.
	if ! would "rm -f $HOST:$WWW/cloudbsd-fingerprint (stale, from a signed release)"; then
		# NOT `|| true`. If this ssh fails, a fingerprint from the previous
		# signed release stays served beside an unsigned repository, and every
		# new install configures signature checking that rejects everything --
		# silently, as an empty repository. Swallowing the failure produces
		# exactly the state the comment above says must not exist.
		if ! remote "rm -f '$WWW/cloudbsd-fingerprint'"; then
			echo "$PROGRAM: could not remove the stale fingerprint on $HOST." >&2
			echo "$PROGRAM: this release is unsigned, so leaving it served would" >&2
			echo "$PROGRAM: make every new install see an empty repository." >&2
			exit 1
		fi
	fi
	PUBLISHED_FINGERPRINT=0
fi

# ------------------------------------------------------------ the pointer
# Moved last. Everything above is invisible to a user until this changes.
say "pointing latest at $VERSION"
if ! would "ln -sfn $VERSION $WWW/pkgbase/$ABI/latest"; then
	remote "ln -sfn '$VERSION' '$WWW/pkgbase/$ABI/latest'"
	_now=$(remote "readlink '$WWW/pkgbase/$ABI/latest'")
	[ "${_now##*/}" = "$VERSION" ] || { echo "$PROGRAM: latest is ${_now}, not $VERSION" >&2; exit 1; }
fi

# --------------------------------------------------------------- verify
# RULE: by CONTENT, never by status. The site is an SPA behind a fallback, so a
# MISSING file returns 200 serving index.html. A status-code check passes for
# something that is not there.
if [ "$DRY" = 1 ]; then
	say "dry run: nothing was changed"
	exit 0
fi

# /pkg is a symlink to pkgbase on the serving host. The upload writes pkgbase/
# and the verification reads /pkg/, so if that symlink ever goes away the check
# fetches a URL unrelated to what was just published -- and a real failure
# reports ok. Assert the mapping instead of assuming it.
if ! _pkgmap=$(remote "cd '$WWW' || exit 1
	if [ -L pkg ]; then readlink pkg
	elif [ -d pkg ]; then echo DIRECTORY
	else echo ABSENT
	fi"); then
	echo "$PROGRAM: could not inspect $WWW/pkg on $HOST" >&2
	exit 1
fi
case "$_pkgmap" in
pkgbase|pkgbase/)	say "/pkg -> pkgbase, so the published URL reaches what was uploaded" ;;
DIRECTORY)	echo "$PROGRAM: $WWW/pkg is a real directory, not a link to pkgbase." >&2
		echo "$PROGRAM: the packages went to pkgbase/ and the site serves /pkg/;" >&2
		echo "$PROGRAM: they are different places and nothing would be served." >&2
		exit 1 ;;
ABSENT)		echo "$PROGRAM: $WWW/pkg does not exist; /pkg URLs reach nothing" >&2; exit 1 ;;
*)		echo "$PROGRAM: $WWW/pkg points at '$_pkgmap', not pkgbase" >&2; exit 1 ;;
esac

say "verifying what is actually served"
_fail=0
# _want is the type expected, or ANY to accept anything that is not the SPA
# fallback. The real assertion here is "a file was served, not index.html";
# pinning an exact type fails correctly-published files whose extension nginx
# does not recognise, which is worse than not checking, because it reports a
# good release as broken.
_check() {
	_url=$1; _want=$2
	# fetch(1) where it exists, curl otherwise. Calling a missing fetch prints
	# an error for every artifact and buries the real result.
	_ct=""
	if command -v fetch >/dev/null 2>&1; then
		_ct=$(fetch -qo /dev/null --print-headers -- "$_url" 2>/dev/null |
		    sed -n 's/^Content-Type: *//p' | tr -d '\r' | head -1)
	fi
	if [ -z "$_ct" ] && command -v curl >/dev/null 2>&1; then
		_ct=$(curl -sI -- "$_url" 2>/dev/null |
		    sed -n 's/^[Cc]ontent-[Tt]ype: *//p' | tr -d '\r' | head -1)
	fi
	# text/html FIRST. The site is an SPA behind a fallback, so a missing file
	# returns 200 serving index.html -- and `text/html` matches a `text/`
	# prefix, so testing the wanted type first reported a missing file as ok.
	# That is exactly the confusion this whole function exists to prevent, and
	# it was reintroduced by the order of two case arms.
	case "$_ct" in
	text/html*)	echo "  MISSING $_url -- served the SPA fallback, not the file" >&2; _fail=$((_fail+1)) ;;
	esac
	case "$_ct" in
	text/html*)	;;
	*)		[ "$_want" = ANY ] && { echo "  ok   $_url ($_ct)"; return 0; } ;;
	esac
	case "$_ct" in
	text/html*)	;;
	"$_want"*)	echo "  ok   $_url ($_ct)" ;;
	'')		echo "  NO ANSWER $_url" >&2; _fail=$((_fail+1)) ;;
	*)		echo "  BAD  $_url (content-type $_ct, wanted $_want)" >&2; _fail=$((_fail+1)) ;;
	esac
}
# ANY: the repository catalogue has no extension nginx maps to a type, so it
# arrives as application/octet-stream. What must be true is that it is not the
# fallback page.
_check "$BASE/pkg/$ABI/latest/meta.conf" ANY

# The fingerprint, when there is one. Checked by CONTENT and by its actual
# text, not merely by being served: the site answers 200 with the SPA fallback
# for anything missing, and index.html would pass a status check, pass a
# content-type check for text/*, and then be installed on every client as
# trust material -- which reads as "signature verification is on" while
# verifying nothing.
if [ "$PUBLISHED_FINGERPRINT" = 1 ]; then
	_fpbody=""
	if command -v fetch >/dev/null 2>&1; then
		_fpbody=$(fetch -qo - -- "$BASE/cloudbsd-fingerprint" 2>/dev/null || true)
	fi
	if [ -z "$_fpbody" ] && command -v curl >/dev/null 2>&1; then
		_fpbody=$(curl -fs -- "$BASE/cloudbsd-fingerprint" 2>/dev/null || true)
	fi
	# The exact digest, not merely a page containing the right two words. The
	# SPA fallback, a cached copy of the PREVIOUS release's fingerprint, or any
	# page that happens to carry both tokens would satisfy a shape check -- and
	# a stale fingerprint is the worst of the three, because it is a real
	# fingerprint for the wrong key and turns every install into an empty
	# repository while reporting that verification is on.
	_served=$(printf '%s\n' "$_fpbody" |
	    sed -n 's/^fingerprint: *"\([0-9a-f]*\)".*/\1/p' | head -1)
	if [ -z "$_fpbody" ]; then
		echo "  BAD  $BASE/cloudbsd-fingerprint (nothing served)" >&2
		_fail=$((_fail+1))
	elif [ "$_served" = "$_fpsum" ] && [ -n "$_fpsum" ]; then
		echo "  ok   $BASE/cloudbsd-fingerprint ($_fpsum)"
	elif [ -z "$_served" ]; then
		echo "  BAD  $BASE/cloudbsd-fingerprint (not a fingerprint file)" >&2
		_fail=$((_fail+1))
	else
		echo "  BAD  $BASE/cloudbsd-fingerprint serves $_served," >&2
		echo "       but this release was signed with $_fpsum" >&2
		_fail=$((_fail+1))
	fi
fi

_s3=$IFS; set -f; IFS='
'
for _f in $_media; do
	IFS=$_s3; set +f
	_check "$BASE/releases/16.0-CURRENT-amd64/$(basename "$_f")" "application/"
	set -f; IFS='
'
done
IFS=$_s3; set +f

[ "$_fail" -eq 0 ] || { echo "$PROGRAM: $_fail published artefact(s) are not being served" >&2; exit 1; }

say "published $VERSION"
if [ "$PREV" = "$VERSION" ]; then
	say "republished $VERSION; the existing rollback was left as it was"
else
	say "previous release $PREV remains in place as a rollback"
fi
