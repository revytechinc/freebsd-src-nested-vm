#!/usr/bin/env sh
# Record what cloudbsd-pkgbase built: version, commit, package list, sums.
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 REVYTECH, Inc.
#
# Metadata only. The .pkg files are NOT archived to the controller (the set
# is ~1-2G per build); they stay in the workspace on this builder until the
# publish step pulls them as root on the repository host.
set -eu

: "${PKGBASE_REPODIR:?PKGBASE_REPODIR must be set by the job}"
: "${PKGBASE_ARTIFACTS:?PKGBASE_ARTIFACTS must be set by the job}"
: "${NODE_NAME:?NODE_NAME must be set by Jenkins}"

A="${PKGBASE_ARTIFACTS}"
mkdir -p "$A"
version=$(cat "$A/pkgbase-version.txt")
commit=$(cat "$A/pkgbase-commit.txt")

# make packages lays the repository out as REPODIR/<ABI>/<PKG_VERSION>/.
# Exactly one ABI directory is expected; two would mean a stale tree.
set -- "${PKGBASE_REPODIR}"/*/"${version}"
if [ $# -ne 1 ] || [ ! -d "$1" ]; then
	echo "FAIL: expected one ${PKGBASE_REPODIR}/<ABI>/${version} directory, found: $*" >&2
	exit 1
fi
pkgdir=$1
abi=$(basename "$(dirname "$pkgdir")")
case "$abi" in
FreeBSD:[0-9]*:amd64) ;;
*) echo "FAIL: unexpected ABI directory ${abi}" >&2; exit 1 ;;
esac

# The set must be COMPLETE, not merely non-empty: a base without runtime or
# a kernel is a repository that bricks the first host that upgrades from it.
for must in FreeBSD-runtime FreeBSD-kernel-generic FreeBSD-utilities FreeBSD-rc; do
	if ! ls "$pkgdir/${must}-${version}.pkg" >/dev/null 2>&1; then
		echo "FAIL: ${must}-${version}.pkg is missing from ${pkgdir}" >&2
		exit 1
	fi
done

count=0
: > "$A/pkgbase-packages.txt"
: > "$A/pkgbase-SHA256"
for p in "$pkgdir"/FreeBSD-*.pkg; do
	[ -f "$p" ] || continue
	[ -L "$p" ] && continue
	pv=$(pkg query -F "$p" '%v')
	if [ "$pv" != "$version" ]; then
		echo "FAIL: $(basename "$p") carries version ${pv}, not ${version}" >&2
		exit 1
	fi
	pkg query -F "$p" '%n-%v' >> "$A/pkgbase-packages.txt"
	(cd "$pkgdir" && sha256 -r "$(basename "$p")") >> "$A/pkgbase-SHA256"
	count=$((count + 1))
done
[ "$count" -gt 0 ] || { echo "FAIL: no FreeBSD-*.pkg in ${pkgdir}" >&2; exit 1; }

# Which OSVERSION the set declares, for Track #283 bookkeeping.
osv=$(pkg query -F "$pkgdir/FreeBSD-runtime-${version}.pkg" '%At=%Av' | awk -F= '$1=="FreeBSD_version"{print $2}')

{
	echo "version=${version}"
	echo "commit=${commit}"
	echo "short=$(printf '%.12s' "${commit}")"
	echo "abi=${abi}"
	echo "count=${count}"
	echo "builder=${NODE_NAME}"
	echo "pkgdir=${pkgdir}"
	echo "osversion=${osv:-unknown}"
	echo "src_url=$(cat "$A/pkgbase-src-url.txt")"
	echo "src_ref=${BRANCH_NAME:-}"
	echo "dest=${abi}/${BASE_REPO_NAME:-base_latest}"
} > "$A/pkgbase-build.properties"

echo "pkgbase: ${count} packages, ${version}, commit ${commit}, ABI ${abi}, OSVERSION ${osv:-unknown}"
echo "pkgbase: left on ${NODE_NAME} at ${pkgdir}"
du -sh "$pkgdir"
