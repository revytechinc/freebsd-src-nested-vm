#!/usr/bin/env sh
# Publish this pkgbase build into InternalPkg <ABI>/base_latest.
# Runs on the `pkgrepo` Jenkins agent, INSIDE the pkgrepo jail on freedev008
# (cloudbsd-ci #46, Track #396 option B). Its only privilege is one doas rule
# per builder:
#   permit nopass jenkins as root cmd /usr/local/sbin/publish-internal-repo.sh args -H <builder> -a FreeBSD:16:amd64 -B
# publish-internal-repo.sh (cloudbsd-ci jenkins/scripts/, -B from #49) then,
# as root, pulls exactly the names given on stdin from the builder's fixed
# export directory /var/db/pkgbase-export/<ABI>/latest into a root-only
# staging directory, refuses anything that is not a base package, refuses
# downgrades, publishes into base_latest and checks the catalogue. This script
# chooses no path, repository or key; the signing key stays unreadable here.
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 REVYTECH, Inc.
#
# Inputs (environment, set by the pipeline from the build stage's record):
#   PKGBASE_BUILDER  Jenkins NODE_NAME of the builder that built the set
#   PKGBASE_VERSION  e.g. 16.snap20260929130756
#   PKGBASE_ABI      FreeBSD:16:amd64
#   PKGBASE_COUNT    number of packages the build recorded
#   BASE_REPO_NAME   base_latest
# and ci-artifacts/pkgbase-packages.txt (unstashed): one name-version per line.
set -eu

die() { echo "pkgbase-publish: $*" >&2; exit 1; }

LIST=ci-artifacts/pkgbase-packages.txt
PUBLISH=/usr/local/sbin/publish-internal-repo.sh

case "${PKGBASE_BUILDER:-}" in
"" | *[!A-Za-z0-9._-]* | .* | -*) die "builder name is not usable: ${PKGBASE_BUILDER:-}" ;;
esac
case "${PKGBASE_VERSION:-}" in
[0-9]*.snap[0-9]*) ;;
*) die "version is not a snapshot version: ${PKGBASE_VERSION:-}" ;;
esac
case "${PKGBASE_VERSION}" in *[!A-Za-z0-9.]*) die "version has unexpected characters" ;; esac
case "${PKGBASE_ABI:-}" in
FreeBSD:16:amd64) ;;
*) die "ABI is not wired for the base handoff: ${PKGBASE_ABI:-}" ;;
esac
[ "${BASE_REPO_NAME:-}" = base_latest ] || die "the handoff publishes base_latest only, not ${BASE_REPO_NAME:-}"
REPO="/usr/local/www/pkgrepo/${PKGBASE_ABI}/${BASE_REPO_NAME}"

if [ ! -x "$PUBLISH" ] || [ ! -d /usr/local/www/pkgrepo ]; then
	die "not the pkgrepo jail: ${PUBLISH} or /usr/local/www/pkgrepo is missing on ${NODE_NAME:-?}; nothing published (packages are still on ${PKGBASE_BUILDER})"
fi

# The script AND its directory must be root-owned and not group/world
# writable: otherwise the file could be replaced before doas runs it.
require_root_owned() {
	[ -e "$1" ] || die "refusing: $1 does not exist"
	[ "$(stat -f '%Su' "$1")" = root ] || die "refusing: $1 is not owned by root"
	m=$(stat -f '%Lp' "$1")
	[ $(( 0$m & 022 )) -eq 0 ] || die "refusing: $1 is group- or world-writable (mode $m)"
}
require_root_owned "$PUBLISH"
require_root_owned "$(dirname "$PUBLISH")"

[ -f "${REPO}/meta.conf" ] || die "no repository at ${REPO} (meta.conf missing); bootstrapping is a documented one-off (cloudbsd-ci docs/PKGBASE.md)"

# The list is this build's record: every line FreeBSD-<name>-<version>.
[ -s "$LIST" ] || die "no package list ($LIST) from the build stage"
n=0
while IFS= read -r line; do
	[ -n "$line" ] || continue
	case "$line" in
	FreeBSD-*-"${PKGBASE_VERSION}") ;;
	*) die "unexpected entry in the package list: $line" ;;
	esac
	n=$((n + 1))
done < "$LIST"
[ "$n" = "${PKGBASE_COUNT:-}" ] || die "package list has $n entries, the build recorded ${PKGBASE_COUNT:-?}"

echo "pkgbase-publish: ${n} packages ${PKGBASE_VERSION} from ${PKGBASE_BUILDER} -> ${REPO}"
# -n: never prompt. A doas that wants a password is a misconfigured rule and
# must fail here rather than hang the stage.
doas -n "$PUBLISH" -H "$PKGBASE_BUILDER" -a "$PKGBASE_ABI" -B < "$LIST"

# Independent check, as the unprivileged agent, of what clients will read.
cat=$(mktemp)
trap 'rm -f "$cat"' EXIT
tar -xOf "${REPO}/packagesite.pkg" packagesite.yaml > "$cat" || die "cannot read ${REPO}/packagesite.pkg"
listed=$(grep -cF "\"version\":\"${PKGBASE_VERSION}\"" "$cat" || :)
[ "${listed:-0}" -eq "$n" ] || die "catalogue lists ${listed:-0} packages at ${PKGBASE_VERSION}, expected ${n}"
for must in FreeBSD-runtime FreeBSD-kernel-generic FreeBSD-utilities FreeBSD-rc; do
	grep -F "\"name\":\"${must}\"" "$cat" | grep -qF "\"version\":\"${PKGBASE_VERSION}\"" ||
		die "catalogue does not list ${must}-${PKGBASE_VERSION}"
done
echo "pkgbase-publish: PUBLISHED ${n} packages ${PKGBASE_VERSION} into InternalPkg ${PKGBASE_ABI}/${BASE_REPO_NAME}"
