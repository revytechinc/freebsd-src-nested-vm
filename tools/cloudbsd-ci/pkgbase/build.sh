#!/usr/bin/env sh
# Build the base system and package it (pkgbase), unprivileged.
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 REVYTECH, Inc.
#
#   make buildworld buildkernel
#   make packages               (stages with -DNO_ROOT; no root needed)
#
# Everything lands beside the workspace (<workspace>@pkgbase): objects under
# MAKEOBJDIRPREFIX, the repository under PKGBASE_REPODIR/${ABI}/${PKG_VERSION}. The job user owns
# all of it, which is the same reasoning as nested-media -- the build should
# need nothing it does not already own.
#
# The catalogue `make packages` writes here is UNSIGNED and is not what
# clients read: publish-internal-repo.sh re-runs pkg repo over the published
# directory with the InternalPkg key, on the host where that key lives.
set -eu

: "${SRC_DIR:?SRC_DIR must be set by the job}"
: "${MAKEOBJDIRPREFIX:?MAKEOBJDIRPREFIX must be set by the job}"
: "${PKGBASE_REPODIR:?PKGBASE_REPODIR must be set by the job}"
: "${PKGBASE_ARTIFACTS:?PKGBASE_ARTIFACTS must be set by the job}"
KERNCONF="${KERNCONF:-GENERIC}"
CLEAN_OBJ="${CLEAN_OBJ:-true}"
TARGET="${TARGET:-amd64}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"

case "${KERNCONF}" in
"" | *[!A-Z0-9_-]*) echo "FAIL: KERNCONF is not usable: ${KERNCONF}" >&2; exit 1 ;;
esac

# Parallelism is capped by cores AND memory. The builders are shared, and
# freedev005 also hosts the Jenkins controller jail: on 2026-09-29 a
# -j<ncpu> world build followed by `make packages` (-j<ncpu>, each pkg create
# compressing with one zstd thread per core) ran freedev005 out of swap and the
# OOM killer took the controller. Auto: min(cores/2, RAM GiB/4); a big C++
# translation unit in clang/LLVM wants well over 1 GiB.
PKGBASE_MAKE_JOBS="${PKGBASE_MAKE_JOBS:-0}"
case "${PKGBASE_MAKE_JOBS}" in
"" | *[!0-9]*) echo "FAIL: PKGBASE_MAKE_JOBS is not a number: ${PKGBASE_MAKE_JOBS}" >&2; exit 1 ;;
esac
NCPU=$(sysctl -n hw.ncpu)
MEM_GIB=$(( $(sysctl -n hw.physmem) / 1073741824 ))
if [ "${PKGBASE_MAKE_JOBS}" -gt 0 ]; then
	JOBS=${PKGBASE_MAKE_JOBS}
else
	JOBS=$(( NCPU / 2 ))
	[ $(( MEM_GIB / 4 )) -lt "${JOBS}" ] && JOBS=$(( MEM_GIB / 4 ))
fi
[ "${JOBS}" -ge 1 ] || JOBS=1
# Packaging is I/O and compression, not compilation: few jobs, few threads
# each (Makefile.inc1 passes -T${PKG_CTHREADS} to every pkg create; its
# default 0 means one thread per core, per package).
PKG_JOBS=$(( JOBS < 8 ? JOBS : 8 ))
PKG_CTHREADS=2

# LLVM targets in the shipped toolchain. host-only drops the other targets
# from clang/lld (WITHOUT_LLVM_TARGET_ALL); buildworld still bootstraps its
# own cross toolchain when TARGET differs, so the fleet loses nothing it
# builds with. A command-line make variable, since SRCCONF is /dev/null.
set --
case "${PKGBASE_LLVM_TARGETS:-host-only}" in
host-only) set -- WITHOUT_LLVM_TARGET_ALL=yes ;;
all) ;;
*) echo "FAIL: PKGBASE_LLVM_TARGETS must be host-only or all" >&2; exit 1 ;;
esac

# The host's /etc/src.conf and /etc/make.conf are NOT part of the base we
# ship. Two builders behind one label must produce the same packages, and a
# knob someone left in one host's src.conf would make the result depend on
# which one the scheduler picked.
export SRCCONF=/dev/null
export __MAKE_CONF=/dev/null
export SRC_ENV_CONF=/dev/null
unset WITH_META_MODE || :

if [ "${CLEAN_OBJ}" = true ]; then
	echo "pkgbase: CLEAN_OBJ=true -- removing ${MAKEOBJDIRPREFIX}"
	if [ -d "${MAKEOBJDIRPREFIX}" ]; then
		chflags -R 0 "${MAKEOBJDIRPREFIX}" 2>/dev/null || :
		rm -rf "${MAKEOBJDIRPREFIX}"
	fi
elif kldstat -q -m filemon 2>/dev/null; then
	# Incremental only makes sense with META_MODE, and META_MODE needs filemon.
	export WITH_META_MODE=yes
	echo "pkgbase: CLEAN_OBJ=false -- incremental build with META_MODE"
fi
mkdir -p "${MAKEOBJDIRPREFIX}"

# Always a fresh repository directory: a package left from the last build must
# not be published as part of this one.
rm -rf "${PKGBASE_REPODIR}"
mkdir -p "${PKGBASE_REPODIR}"

cd "${SRC_DIR}"

# FreeBSD's own snapshot version format (Makefile.inc1: MAJOR.snapYYYYMMDDHHMMSS),
# fixed ONCE here so every package in the set carries the same version and the
# job knows it without parsing make's output.
REVISION=$(sed -n 's/^REVISION="\(.*\)"$/\1/p' sys/conf/newvers.sh)
MAJOR=${REVISION%%.*}
case "${MAJOR}" in
"" | *[!0-9]*) echo "FAIL: cannot read REVISION from sys/conf/newvers.sh" >&2; exit 1 ;;
esac
PKG_VERSION="${MAJOR}.snap$(date -u +%Y%m%d%H%M%S)"
echo "pkgbase: PKG_VERSION=${PKG_VERSION} KERNCONF=${KERNCONF} -j${JOBS} (cores ${NCPU}, RAM ${MEM_GIB}G) packages -j${PKG_JOBS} -T${PKG_CTHREADS} llvm=${PKGBASE_LLVM_TARGETS:-host-only}"
printf '%s\n' "${PKG_VERSION}" > "${PKGBASE_ARTIFACTS}/pkgbase-version.txt"

# nice: the builders are shared. A world build yields to whatever else is on
# the node rather than starving it; it still gets every idle core.
t0=$(date +%s)
nice -n 10 make -j"${JOBS}" buildworld buildkernel \
	TARGET="${TARGET}" TARGET_ARCH="${TARGET_ARCH}" KERNCONF="${KERNCONF}" "$@"
t1=$(date +%s)
echo "pkgbase: buildworld+buildkernel took $(( (t1 - t0) / 60 )) min"

nice -n 10 make -j"${PKG_JOBS}" packages \
	TARGET="${TARGET}" TARGET_ARCH="${TARGET_ARCH}" KERNCONF="${KERNCONF}" "$@" \
	PKG_VERSION="${PKG_VERSION}" REPODIR="${PKGBASE_REPODIR}" \
	PKG_CTHREADS="${PKG_CTHREADS}"
t2=$(date +%s)
echo "pkgbase: make packages took $(( (t2 - t1) / 60 )) min"
