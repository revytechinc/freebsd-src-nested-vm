#!/usr/bin/env sh
# Stamp the tree this build uses: the commit, and that it is clean.
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 REVYTECH, Inc.
#
# The Jenkinsfile lives in this repository, so the workspace IS the source
# tree Jenkins checked out for this branch. The build is stamped with the
# COMMIT -- the one answer to "what is this base" -- and a dirty tree is
# refused: an artifact built from uncommitted changes matches no revision
# anyone can check out again.
set -eu

: "${SRC_DIR:?SRC_DIR must be set by the job}"
: "${PKGBASE_ARTIFACTS:?PKGBASE_ARTIFACTS must be set by the job}"

cd "${SRC_DIR}"
# The artifacts directory is the only thing the job writes inside the tree;
# clear the previous build's before asking whether the tree is clean.
rm -rf "${PKGBASE_ARTIFACTS}"
mkdir -p "${PKGBASE_ARTIFACTS}"

sha=$(git rev-parse HEAD)
url=$(git remote get-url origin 2>/dev/null || echo unknown)
echo "pkgbase: ${url} ${BRANCH_NAME:-?} -> ${sha}"
printf '%s\n' "${sha}" > "${PKGBASE_ARTIFACTS}/pkgbase-commit.txt"
printf '%s\n' "${url}" > "${PKGBASE_ARTIFACTS}/pkgbase-src-url.txt"

if [ -n "$(git status --porcelain -- . ":(exclude)${PKGBASE_ARTIFACTS##*/}")" ]; then
	echo "FAIL: tree is dirty -- refusing to build a base that matches no commit" >&2
	git status --short >&2
	exit 1
fi
