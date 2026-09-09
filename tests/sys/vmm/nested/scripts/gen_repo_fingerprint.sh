#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# gen_repo_fingerprint.sh -- write the pkg(8) fingerprint file for our
# repository's public key.
#
# We sign the catalogue with `pkg repo ... signing_command:`, not with a key
# file, so that the private key can live on a machine other than the builder --
# see build_packages.sh for what that separation is and is not worth, which
# depends on the account the command runs as rather than on the mechanism.
#
# That choice decides the client configuration for us, and not the way one
# would guess -- the two signing modes need DIFFERENT client settings, and
# pairing them wrongly fails silently:
#
#   pkg repo <dir> rsa:<key>          -> client: SIGNATURE_TYPE PUBKEY,
#                                                 PUBKEY <path to the .pub>
#   pkg repo <dir> signing_command: X -> client: SIGNATURE_TYPE FINGERPRINTS,
#                                                 FINGERPRINTS <a directory>
#
# Measured on pkg 2.8.4: with the right fingerprint the catalogue validates and
# the packages appear. With a wrong one, pkg prints "No trusted public keys
# found", still says "repository is up to date", and presents an EMPTY
# repository. There is no error status to notice -- so whatever consumes this
# file has to check that packages are actually visible, not that pkg exited 0.
#
# The fingerprint is the SHA-256 of the public key file itself, and it must be
# the same public key the signing command returns in its CERT block. If those
# two ever diverge the repository signs correctly and validates nowhere.
#
# Prefer -c over -p.
#
# When a catalogue is signed with an external command, pkg stores the public
# key the command returned as a member of the catalogue itself: data.pkg holds
# data.sig, data.pub and data. Measured on pkg 2.8.4, that embedded data.pub is
# BYTE-IDENTICAL to the signing key's public half -- so a fingerprint taken
# from the catalogue is provably the key that signed THAT catalogue.
#
# Taken from a key file instead, it is only the key somebody pointed at, and
# the two can drift: sign with one key, publish the fingerprint of another, and
# every client silently sees an empty repository. Deriving it from the artifact
# being published removes that possibility rather than documenting it.
#
# Usage:
#   gen_repo_fingerprint.sh -c <data.pkg>  [-n <name>] [-o <output file>]
#   gen_repo_fingerprint.sh -p <repo.pub>  [-n <name>] [-o <output file>]
#
#   -c  a SIGNED catalogue archive; the key is taken from its data.pub member
#   -p  the public key directly, as returned by the signing command's CERT block
#   -n  the name of the fingerprint entry (default CloudBSD). pkg looks for it
#       under <fingerprints dir>/trusted/<name>; the name itself is arbitrary.
#   -o  where to write it (default: stdout)
set -eu

PROGRAM="${0##*/}"

PUB=""; CAT=""; NAME="CloudBSD"; OUT=""

while getopts c:p:n:o: o; do
	case "$o" in
	c) CAT=$OPTARG ;;
	p) PUB=$OPTARG ;;
	n) NAME=$OPTARG ;;
	o) OUT=$OPTARG ;;
	*) echo "usage: $PROGRAM {-c <data.pkg> | -p <repo.pub>} [-n name] [-o out]" >&2; exit 2 ;;
	esac
done

if [ -n "$CAT" ] && [ -n "$PUB" ]; then
	echo "$PROGRAM: give -c or -p, not both -- they are two answers to the" >&2
	echo "$PROGRAM: same question and this cannot know which one is right" >&2
	exit 2
fi

TMPPUB=""
TMPD=""
trap 'rm -f "$TMPPUB"; [ -z "$TMPD" ] || rm -rf "$TMPD"' EXIT INT TERM

# A leading "-" makes a filename into an option for tar, grep and sha256 alike.
# `--` covers the operands, but $CAT is the argument to tar's -f and $PUB is an
# operand in three different tools, so the shape is refused outright as well.
for _v in CAT PUB; do
	eval "_val=\${$_v:-}"
	case "$_val" in
	-*) echo "$PROGRAM: the $_v path may not begin with '-': $_val" >&2
	    echo "$PROGRAM: every tool here would read it as an option" >&2
	    exit 2 ;;
	esac
done

if [ -n "$CAT" ]; then
	[ -r "$CAT" ] || { echo "$PROGRAM: cannot read $CAT" >&2; exit 1; }

	# The member names are derived from the archive rather than assumed:
	# data.pkg carries data/data.sig/data.pub, packagesite.pkg carries
	# packagesite.yaml and the same two suffixes. Finding the .sig member and
	# stripping the suffix works for both, and for whatever the next catalogue
	# archive is called.
	_ml=$(tar -tf "$CAT" 2>/dev/null) || {
		echo "$PROGRAM: cannot list $CAT" >&2; exit 1; }
	_sig=$(printf '%s\n' "$_ml" | sed 's#^\./##' | grep -E '\.sig$' | head -1)
	if [ -z "$_sig" ]; then
		echo "$PROGRAM: $CAT carries no signature member." >&2
		echo "$PROGRAM: either it is unsigned, or it was signed with a key file" >&2
		echo "$PROGRAM: (rsa:<key>) rather than a signing command -- and a key-file" >&2
		echo "$PROGRAM: signed repository needs a PUBKEY client config, not a" >&2
		echo "$PROGRAM: fingerprint. Publishing a fingerprint for it would make" >&2
		echo "$PROGRAM: every client see an empty repository." >&2
		exit 1
	fi
	_content=${_sig%.sig}
	_pubm="$_content.pub"

	# Every member name is checked before it is used as anything, and NOTHING
	# is unpacked.
	#
	# An earlier version here ran `tar -xf "$CAT" -C "$TMPD"`, which unpacks
	# whatever the archive says: a member named `../../x`, an absolute path, or
	# a symlink writes outside the temporary directory before a single
	# signature has been checked. The archive is the untrusted thing in this
	# script -- proving it trustworthy is the whole job -- so it must not be
	# able to place a file anywhere. `tar -xOf <archive> -- <member>` writes to
	# stdout and creates nothing, and the redirect names the destination here
	# rather than in the archive.
	for _need in "$_content" "$_sig" "$_pubm"; do
		case "$_need" in
		""|/*|*/*|.|..)
			echo "$PROGRAM: $CAT names a member that is not a plain file in the" >&2
			echo "$PROGRAM: archive root: [$_need]. Refusing to touch it." >&2
			exit 1 ;;
		esac
	done

	TMPD=$(mktemp -d) || exit 1
	trap 'rm -rf "$TMPD"; rm -f "$TMPPUB"' EXIT INT TERM
	for _need in "$_content" "$_sig" "$_pubm"; do
		if ! tar -xOf "$CAT" -- "$_need" > "$TMPD/m.$_need" 2>/dev/null ||
		   [ ! -s "$TMPD/m.$_need" ]; then
			echo "$PROGRAM: $CAT is missing or has an empty $_need" >&2
			exit 1
		fi
	done

	# Prove the embedded key is the key that SIGNED this catalogue, rather than
	# merely a PEM file that happens to be inside it.
	#
	# Without this, a catalogue carrying a mismatched data.pub yields a
	# perfectly well-formed fingerprint that every client installs as trust
	# material and that verifies nothing -- which presents as an empty
	# repository with no error anywhere.
	#
	# What pkg signs, measured on 2.8.4: the ASCII hex SHA-256 of the content
	# member, with no trailing newline. Not the member itself, and not a
	# binary digest.
	command -v openssl >/dev/null 2>&1 || {
		echo "$PROGRAM: openssl is needed to prove the embedded key signed this" >&2
		echo "$PROGRAM: catalogue, and publishing unproven trust material is worse" >&2
		echo "$PROGRAM: than publishing none -- it fails silently on every client." >&2
		exit 1; }
	_csum=$(sha256 -q -- "$TMPD/m.$_content" 2>/dev/null) || _csum=""
	[ -n "$_csum" ] || _csum=$(sha256sum -- "$TMPD/m.$_content" 2>/dev/null | cut -d' ' -f1)
	[ -n "$_csum" ] || _csum=$(shasum -a 256 -- "$TMPD/m.$_content" 2>/dev/null | cut -d' ' -f1)
	[ -n "$_csum" ] || { echo "$PROGRAM: no sha256 tool found" >&2; exit 1; }
	printf '%s' "$_csum" > "$TMPD/.signed-bytes"
	if ! openssl dgst -sha256 -verify "$TMPD/m.$_pubm" \
	    -signature "$TMPD/m.$_sig" "$TMPD/.signed-bytes" >/dev/null 2>&1; then
		echo "$PROGRAM: the key embedded in $CAT does NOT verify its signature." >&2
		echo "$PROGRAM: a fingerprint taken from it would be trust material for a" >&2
		echo "$PROGRAM: key that did not sign this release, and every client would" >&2
		echo "$PROGRAM: silently see an empty repository. Refusing." >&2
		exit 1
	fi
	echo "$PROGRAM: $_pubm verifies $_sig over $_content" >&2

	PUB="$TMPD/m.$_pubm"
fi

[ -n "$PUB" ] || { echo "$PROGRAM: one of -c or -p is required" >&2; exit 2; }
[ -r "$PUB" ] || { echo "$PROGRAM: cannot read $PUB" >&2; exit 1; }

# The name becomes a filename under trusted/. Constrain it rather than trust it.
case "$NAME" in
*[!0-9A-Za-z._-]*|""|.|..)
	echo "$PROGRAM: -n may only contain [0-9A-Za-z._-]: $NAME" >&2; exit 2 ;;
esac

# It must actually be a public key. A truncated download, or the HTML error
# page a site returns for a missing file, hashes perfectly well and produces a
# fingerprint file that is valid in form and wrong in every other way.
grep -q -e "BEGIN PUBLIC KEY" -- "$PUB" || {
	echo "$PROGRAM: $PUB does not look like a PEM public key" >&2
	echo "$PROGRAM: a fingerprint of the wrong bytes is still a valid-looking" >&2
	echo "$PROGRAM: fingerprint file, and the failure it causes is silent" >&2
	exit 1
}

# sha256(1) on FreeBSD and macOS, sha256sum on Linux. This runs on a build host
# and on a developer's machine, and the two do not agree on the tool's name.
sum=$(sha256 -q -- "$PUB" 2>/dev/null) || sum=""
[ -n "$sum" ] || sum=$(sha256sum -- "$PUB" 2>/dev/null | cut -d' ' -f1)
[ -n "$sum" ] || sum=$(shasum -a 256 -- "$PUB" 2>/dev/null | cut -d' ' -f1)
[ -n "$sum" ] || { echo "$PROGRAM: no sha256 tool found" >&2; exit 1; }

# Every character, not just the first: `[0-9a-f]*` constrains only the leading
# one, so a tool emitting "SHA256 (f) = ..." or any other 64-character line
# starting with a hex digit would be written into the fingerprint file -- and a
# malformed fingerprint fails silently on every client.
case "$sum" in
*[!0-9a-f]*|"")
	echo "$PROGRAM: computed digest is not lower-case hex: $sum" >&2; exit 1 ;;
esac
[ "${#sum}" = 64 ] || { echo "$PROGRAM: digest is ${#sum} characters, not 64" >&2; exit 1; }

if [ -n "$OUT" ]; then
	mkdir -p "$(dirname "$OUT")"
	printf 'function: sha256\nfingerprint: "%s"\n' "$sum" > "$OUT.part"
	mv -- "$OUT.part" "$OUT"
	echo "$PROGRAM: wrote $OUT"
	echo "$PROGRAM:   name        $NAME"
	echo "$PROGRAM:   fingerprint $sum"
	echo "$PROGRAM: install it on a client as <fingerprints dir>/trusted/$NAME"
else
	printf 'function: sha256\nfingerprint: "%s"\n' "$sum"
fi
