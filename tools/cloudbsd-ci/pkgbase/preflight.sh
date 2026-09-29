#!/usr/bin/env sh
# Preflight for cloudbsd-pkgbase: can this node build a base system at all?
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 REVYTECH, Inc.
set -eu

: "${SRC_DIR:?SRC_DIR must be set by the job}"
: "${MAKEOBJDIRPREFIX:?MAKEOBJDIRPREFIX must be set by the job}"
: "${WORKSPACE:?WORKSPACE must be set by Jenkins}"

fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

[ "$(uname -s)" = FreeBSD ] || bad "not a FreeBSD host: $(uname -s)"
[ "$(uname -m)" = amd64 ] || bad "not an amd64 host: $(uname -m)"
[ -f "${SRC_DIR}/sys/conf/newvers.sh" ] || bad "${SRC_DIR} is not a src tree"
# make packages bootstraps pkg if ${LOCALBASE}/sbin/pkg is missing, which as
# an unprivileged user means failing an hour in. Ask now.
[ -x /usr/local/sbin/pkg ] || bad "/usr/local/sbin/pkg is not installed"

# World + kernel objects (~25G) + staging (~10G) + packages (~2G), with room.
NEED_GB=${PKGBASE_NEED_GB:-80}
mkdir -p "${MAKEOBJDIRPREFIX}"
avail_kb=$(df -k "${MAKEOBJDIRPREFIX}" | awk 'NR==2 {print $4}')
avail_gb=$((avail_kb / 1024 / 1024))
if [ "${avail_gb}" -lt "${NEED_GB}" ]; then
	bad "only ${avail_gb}G free under ${MAKEOBJDIRPREFIX}; a base build wants ${NEED_GB}G"
else
	echo "pkgbase: ${avail_gb}G free under ${MAKEOBJDIRPREFIX} (need ${NEED_GB}G)"
fi

# Say which OSVERSION this base will carry against the host building it.
# Informational: buildworld bootstraps across versions. The fleet question of
# which hosts may take a newer OSVERSION is Track #283, decided elsewhere.
tree_ver=$(awk '/^#define[[:space:]]+__FreeBSD_version/ {print $3}' "${SRC_DIR}/sys/sys/param.h")
echo "pkgbase: tree __FreeBSD_version=${tree_ver} host kern.osreldate=$(sysctl -n kern.osreldate) host=$(hostname)"
REVISION=$(sed -n 's/^REVISION="\(.*\)"$/\1/p' "${SRC_DIR}/sys/conf/newvers.sh")
BRANCH=$(sed -n 's/^BRANCH="\(.*\)"$/\1/p' "${SRC_DIR}/sys/conf/newvers.sh")
case "${BRANCH:-}" in
CURRENT* | STABLE* | PRERELEASE*) echo "pkgbase: branch ${REVISION:-?}-${BRANCH} (snapshot versioning)" ;;
*) bad "branch ${REVISION:-?}-${BRANCH:-?}: this job versions base as a -CURRENT/-STABLE snapshot only" ;;
esac

[ "$fail" -eq 0 ] || exit 1
echo "pkgbase: preflight ok"
