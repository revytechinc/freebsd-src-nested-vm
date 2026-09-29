#!/usr/bin/env sh
# Publish a cloudbsd-pkgbase build into InternalPkg <ABI>/base_latest.
# Runs on the node carrying the `pkgrepo` role label (the InternalPkg host).
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 REVYTECH, Inc.
#
# Same shape as the ports handoff (SH_HANDOFF in cloudbsd-ci Jenkinsfile.ports): root on
# the repository host pulls the packages from the builder into a ROOT-OWNED
# staging directory -- never a Jenkins workspace on this host -- and calls the
# same publish-internal-repo.sh, with -d pointing at the SEPARATE base
# repository. The signing key is used where it already lives and is never
# read, copied or passed by this script.
#
# Inputs (environment, set by the pipeline from the build stage's record):
#   PKGBASE_BUILDER  Jenkins NODE_NAME of the builder; must be an ssh name
#                    root on this host can reach
#   PKGBASE_SRCDIR   <workspace>@pkgbase/repo/<ABI>/<version> on that builder
#   PKGBASE_VERSION  e.g. 16.snap20260929083000
#   PKGBASE_ABI      e.g. FreeBSD:16:amd64
#   PKGBASE_COUNT    number of FreeBSD-*.pkg the build recorded
#   BASE_REPO_NAME   base_latest
set -eu

die() { echo "pkgbase-publish: $*" >&2; exit 1; }

case "${PKGBASE_BUILDER:-}" in
"" | *[!A-Za-z0-9._-]* | .* | -*) die "builder name is not usable: ${PKGBASE_BUILDER:-}" ;;
esac
case "${PKGBASE_VERSION:-}" in
[0-9]*.snap[0-9]*) ;;
*) die "version is not a snapshot version: ${PKGBASE_VERSION:-}" ;;
esac
case "${PKGBASE_VERSION}" in *[!A-Za-z0-9.]*) die "version has unexpected characters" ;; esac
case "${PKGBASE_ABI:-}" in
FreeBSD:[0-9]*:amd64) ;;
*) die "ABI is not a FreeBSD amd64 ABI: ${PKGBASE_ABI:-}" ;;
esac
case "${PKGBASE_ABI}" in *[!A-Za-z0-9:]*) die "ABI has unexpected characters" ;; esac
case "${BASE_REPO_NAME:-}" in
base_latest | base_release_[0-9]*) ;;
*) die "refusing destination ${BASE_REPO_NAME:-}: base goes to base_latest or base_release_N, never the ports repo" ;;
esac
case "${PKGBASE_COUNT:-}" in "" | *[!0-9]*) die "PKGBASE_COUNT is not a number" ;; esac
# The source must be the job's own repository directory, nothing else a
# caller could point root at.
case "${PKGBASE_SRCDIR:-}" in
/home/jenkins/agent/workspace/*@pkgbase/repo/"${PKGBASE_ABI}"/"${PKGBASE_VERSION}") ;;
*) die "source is not a cloudbsd-pkgbase repository directory: ${PKGBASE_SRCDIR:-}" ;;
esac
case "${PKGBASE_SRCDIR}" in *..* | *[!A-Za-z0-9/:._@-]*) die "source path has unexpected characters" ;; esac

PUBLISH=/usr/local/sbin/publish-internal-repo.sh
JAIL_ROOT=/usr/local/bastille/jails/pkgrepo/root
REPO="${JAIL_ROOT}/usr/local/www/pkgrepo/${PKGBASE_ABI}/${BASE_REPO_NAME}"
STAGING="/var/db/pkgbase-handoff/${PKGBASE_VERSION}"

[ -x "$PUBLISH" ] || die "${PUBLISH} is not installed on ${NODE_NAME:-this node}: this is not the repository host"
if [ ! -f "${REPO}/meta.conf" ]; then
	echo "pkgbase-publish: no base repository at ${REPO}" >&2
	echo "  Bootstrapping it is a one-off, done by hand (tools/cloudbsd-ci/pkgbase/README.md, 'Bootstrap')." >&2
	exit 1
fi

echo "pkgbase-publish: ${PKGBASE_BUILDER}:${PKGBASE_SRCDIR} -> ${STAGING} -> ${REPO}"

# One doas, so the tar stream never sits in an unprivileged pipe.
doas env B="$PKGBASE_BUILDER" SRC="$PKGBASE_SRCDIR" STAGING="$STAGING" sh -c '
	set -eu
	rm -rf "$STAGING"
	install -d -o root -g wheel -m 0755 "$STAGING"
	ssh -o BatchMode=yes -o ConnectTimeout=30 "$B" \
	    "test -d \"$SRC\" && tar -C \"$SRC\" -cf - ." | tar -C "$STAGING" -xf -
	n=0
	for f in "$STAGING"/*.pkg; do
		[ -e "$f" ] || [ -L "$f" ] || continue
		if [ -L "$f" ] || [ ! -f "$f" ]; then
			echo "refusing to publish: $f is not a regular file" >&2
			exit 1
		fi
		n=$((n + 1))
	done
	echo "$n" > "$STAGING/.count"
'
got=$(doas cat "${STAGING}/.count")
[ "$got" = "$PKGBASE_COUNT" ] ||
	die "staged ${got} packages but the build recorded ${PKGBASE_COUNT}; not publishing"

doas "$PUBLISH" -s "$STAGING" -d "$REPO"

# Belt and braces over publish-internal-repo.sh's own check: the catalogue
# clients read names this build's runtime and kernel.
for n in FreeBSD-runtime FreeBSD-kernel-generic; do
	tar xOzf "${REPO}/packagesite.pkg" packagesite.yaml |
	    grep -F "\"name\":\"${n}\"" | grep -qF "\"version\":\"${PKGBASE_VERSION}\"" ||
	    die "catalogue does not list ${n}-${PKGBASE_VERSION} after publish"
done
echo "pkgbase-publish: PUBLISHED ${PKGBASE_COUNT} packages ${PKGBASE_VERSION} into ${PKGBASE_ABI}/${BASE_REPO_NAME}"
