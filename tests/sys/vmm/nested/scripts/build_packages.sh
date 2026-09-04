#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Build CloudBSD *base* packages once (pkgbase grammar).
#
# FreeBSD pkgbase already has:
#   PKG_NAME_PREFIX  (bsd.pkg.pre.mk / Makefile.inc1) defaults to FreeBSD
#                    upstream; this script overrides it to CloudBSD locally
#                    (see PKG_NAME_PREFIX below) and never edits those files
#   name = ${PKG_NAME_PREFIX}-${component}
#   origin = base/${PKG_NAME_PREFIX}-${component}
#   repo layout ${REPODIR}/${ABI}/${PKG_VERSION}/ plus a `latest` symlink
#     (Makefile.inc1: REPODIR/${PKG_ABI}/latest -> version dir)
# There is no channel string in the filename. Public pkgbase uses repo
# names (base_latest vs base_release_N) as different URLs, not -dev in
# the pkg name. Ports are not pkgbase: do not set PKG_NAME_PREFIX when
# building third-party ports.
#
#   sudo ./tests/sys/vmm/nested/scripts/build_packages.sh
#   NESTED_SKIP_BUILDKERNEL=1
#
# Output: ${NESTED_PKGDIR}/${ABI}/${VERSION}/CloudBSD-*.pkg
#         ${NESTED_PKGDIR}/${ABI}/latest -> ${VERSION}
# Does not install on any host.

# shellcheck shell=sh
set -eu

PROGRAM="${0##*/}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SRCTOP=$(CDPATH= cd -- "${SCRIPT_DIR}/../../../../.." && pwd)
JOBS=${NESTED_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}
KERNCONF=${NESTED_KERNCONF:-GENERIC}
# Match Makefile.inc1 REPODIR/${ABI}/${VERSION} + latest symlink.
PKGDIR=${NESTED_PKGDIR:-${HOME}/nested-packages}
STAGE=${NESTED_STAGE:-/tmp/nested-pkg-stage}
SKIP_KERN=${NESTED_SKIP_BUILDKERNEL:-0}
# Channel pointer (directory name of the symlink), not a filename tag.
# pkgbase uses "latest"; later release channels can add another symlink.
CHANNEL=${PKG_CHANNEL:-latest}
PKG_NAME_PREFIX=${PKG_NAME_PREFIX:-CloudBSD}

log() { printf '%s: %s\n' "$PROGRAM" "$*"; }
die() { log "FAIL: $*"; exit 1; }

[ -f "${SRCTOP}/sys/conf/kern.pre.mk" ] || die "SRCTOP not a src tree: $SRCTOP"
[ "$(id -u)" -eq 0 ] || die "need root (installkernel DESTDIR + pkg create)"

GITREV=$(git -C "$SRCTOP" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
GITFULL=$(git -C "$SRCTOP" rev-parse HEAD 2>/dev/null || echo unknown)
DATEUTC=$(date -u +%Y%m%d)
VERSION=${PKG_VERSION:-${NESTED_PKG_VERSION:-16.0.${DATEUTC}.${GITREV}}}
ABI=$(pkg config ABI 2>/dev/null || echo FreeBSD:16:amd64)
OUTDIR="${PKGDIR}/${ABI}/${VERSION}"

log "srctop=$SRCTOP git=$GITFULL"
log "PKG_NAME_PREFIX=$PKG_NAME_PREFIX version=$VERSION abi=$ABI channel=$CHANNEL"
log "outdir=$OUTDIR"

rm -rf "$STAGE"
mkdir -p "$OUTDIR" \
	"$STAGE/kernel" \
	"$STAGE/bhyve/usr/lib" "$STAGE/bhyve/usr/sbin" "$STAGE/bhyve/usr/include" \
	"$STAGE/bhyve/usr/libexec" \
	"$STAGE/bhyve/usr/share/man/man5" "$STAGE/bhyve/usr/share/man/man8" \
	"$STAGE/bhyve/usr/lib/debug/usr/lib" \
	"$STAGE/bhyve/usr/lib/debug/usr/sbin" \
	"$STAGE/bhyve/usr/lib/debug/usr/libexec"

if [ "$SKIP_KERN" != 1 ]; then
	log "buildkernel $KERNCONF"
	make -C "$SRCTOP" -j"$JOBS" buildkernel KERNCONF="$KERNCONF"
else
	log "skip buildkernel (NESTED_SKIP_BUILDKERNEL=1)"
fi

log "installkernel DESTDIR=$STAGE/kernel"
make -C "$SRCTOP" installkernel KERNCONF="$KERNCONF" DESTDIR="$STAGE/kernel"
find "$STAGE/kernel" \( -name '*.debug' -o -name '*.full' -o -name '*.symbols' \) -delete
rm -rf "$STAGE/kernel/usr/lib/debug" || true

log "libvmmapi + bhyve"
make -C "${SRCTOP}/lib/libvmmapi" -j"$JOBS" all
make -C "${SRCTOP}/usr.sbin/bhyve" -j"$JOBS" all
make -C "${SRCTOP}/usr.sbin/bhyvectl" -j"$JOBS" all
make -C "${SRCTOP}/usr.sbin/bhyveload" -j"$JOBS" all
make -C "${SRCTOP}/lib/libvmmapi" install DESTDIR="$STAGE/bhyve"
make -C "${SRCTOP}/usr.sbin/bhyve" install DESTDIR="$STAGE/bhyve"
make -C "${SRCTOP}/usr.sbin/bhyvectl" install DESTDIR="$STAGE/bhyve"
# bhyveload -N is required to CREATE/load a nested guest (stock bhyveload has no
# -N); ship it in the package so an installed system can actually run nested VMs.
make -C "${SRCTOP}/usr.sbin/bhyveload" install DESTDIR="$STAGE/bhyve"

# bhyve links libprivate9p.so.1 (lib9p), which is newer than any published stock
# base snapshot -- bundle it so the package installs standalone on a stock
# FreeBSD 16. libuvmem.so.1 IS in stock base (FreeBSD-runtime), so leave that one.
make -C "${SRCTOP}/lib/lib9p" -j"$JOBS" all
# Copy just the runtime shared object (not headers/man, which would need
# staging dirs and aren't part of a base package) into the bhyve stage.
_l9p_obj=$(make -C "${SRCTOP}/lib/lib9p" -V .OBJDIR)
mkdir -p "$STAGE/bhyve/usr/lib"
cp -a "${_l9p_obj}/libprivate9p.so.1" "$STAGE/bhyve/usr/lib/libprivate9p.so.1"
# Drop bhyve-slirp-helper: on a stock system it is owned by the un-removable
# FreeBSD-utilities base package, so bundling it makes `pkg add` conflict.
rm -f "$STAGE/bhyve/usr/libexec/bhyve-slirp-helper" \
      "$STAGE/bhyve/usr/lib/debug/usr/libexec/bhyve-slirp-helper.debug"

write_manifest() {
	_pkg=$1
	_comment=$2
	_m=$3
	_shlibs=${4:-}
	_name="${PKG_NAME_PREFIX}-${_pkg}"
	cat > "$_m" <<MAN
name: ${_name}
version: "${VERSION}"
origin: base/${_name}
comment: "${_comment}"
desc: "${_comment}. Git ${GITFULL}. Built $(date -u +%Y-%m-%dT%H:%M:%SZ)."
maintainer: mark@cloudbsd.org
www: https://www.cloudbsd.org
abi: "${ABI}"
arch: "${ABI}"
prefix: /
licenselogic: single
licenses: [BSD2CLAUSE]
MAN
	if [ -n "$_shlibs" ]; then
		printf 'shlibs_provided: [%s]\n' "$_shlibs" >> "$_m"
	fi
}

# Base packages only. Maps to FreeBSD-kernel-generic / FreeBSD-bhyve.
# Do not emit CloudBSD-* names for ports or extra test scripts.
pkg_from_stage() {
	_pkg=$1
	_comment=$2
	_root=$3
	_shlibs=${4:-}
	_name="${PKG_NAME_PREFIX}-${_pkg}"
	_man=$(mktemp /tmp/cbsd-manifest.XXXXXX)
	_plist=$(mktemp /tmp/cbsd-plist.XXXXXX)
	write_manifest "$_pkg" "$_comment" "$_man" "$_shlibs"
	(cd "$_root" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort) > "$_plist"
	[ -s "$_plist" ] || die "empty plist for $_name under $_root"
	pkg create -M "$_man" -p "$_plist" -r "$_root" -o "$OUTDIR"
	rm -f "$_man" "$_plist"
	log "created $_name"
}

pkg_from_stage kernel-generic \
	"CloudBSD GENERIC kernel + modules (incl. vmm.ko, zfs.ko)" \
	"$STAGE/kernel"

pkg_from_stage bhyve \
	"CloudBSD bhyve + bhyveload + bhyvectl + libvmmapi (nested -N)" \
	"$STAGE/bhyve" \
	"libprivate9p.so.1"

# Generate the pkg(8) repository catalog (meta.conf + packagesite + data) in the
# version directory so clients can `pkg update` / `pkg install` from this repo.
# Without it the repo has only raw .pkg files and the pkg-install path
# (install.sh) fails. Run it BEFORE the stable-alias symlinks below so the
# packages are not double-indexed under two filenames.
if pkg repo "$OUTDIR" >/dev/null 2>&1; then
	log "pkg repo: catalog generated in $OUTDIR"
else
	log "WARNING: 'pkg repo $OUTDIR' failed -- no catalog; pkg update/install will not work"
fi

# pkgbase: ${REPODIR}/${ABI}/latest -> version directory (Makefile.inc1).
ln -sfn "$VERSION" "${PKGDIR}/${ABI}/${CHANNEL}"

# Stable, version-independent package filenames so published install URLs do not
# change every build (e.g. .../latest/CloudBSD-bhyve.pkg).
for _p in "${PKG_NAME_PREFIX}-kernel-generic" "${PKG_NAME_PREFIX}-bhyve"; do
	_f=$(cd "$OUTDIR" && ls "${_p}"-*.pkg 2>/dev/null | head -1)
	[ -n "$_f" ] && ln -sfn "$_f" "${OUTDIR}/${_p}.pkg"
done

log "packages:"
ls -lh "$OUTDIR"/"${PKG_NAME_PREFIX}"-*.pkg
log "channel pointer: ${PKGDIR}/${ABI}/${CHANNEL} -> $VERSION"
log "DONE git=$GITREV (base packages only; not installed on other hosts)"
