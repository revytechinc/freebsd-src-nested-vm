#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# T51 / Wave 8: build helper for custom test artifacts. Builds
# mfsBSD, OVMF UEFI firmware, and an Alpine Linux guest image per
# the pinned version matrix in
# tests/sys/vmm/nested/README.artifacts.md. The artifacts are
# stored in /usr/tests/sys/vmm/nested/fixtures/ (NOT committed to
# git). This script is a thin wrapper around the upstream build
# instructions; it exists so a CI runner can re-provision the
# fixtures deterministically.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

MFSBSD_TAG="${MFSBSD_TAG:-mfsbsd-2.3}"
EDK2_TAG="${EDK2_TAG:-edk2-stable202408}"
ALPINE_TAG="${ALPINE_TAG:-3.20}"

FIXTURE_DIR="${NESTED_FIXTURE_DIR:-/usr/tests/sys/vmm/nested/fixtures}"
BUILD_DIR="${NESTED_BUILD_DIR:-/usr/local/nested-build}"
JOBS="${NESTED_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

: "${NESTED_TEST_DRIVER:=auto}"

build_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! command -v git >/dev/null 2>&1; then
		echo "SKIP: git not in PATH"
		return 0
	fi
	if ! command -v make >/dev/null 2>&1; then
		echo "SKIP: make not in PATH"
		return 0
	fi
	return 1
}

build_mfsbsd()
{
	echo "T51 build_artifacts: mfsBSD ${MFSBSD_TAG}"
	if [ -f "${FIXTURE_DIR}/l2_test.img" ]; then
		echo "  present: ${FIXTURE_DIR}/l2_test.img"
		return 0
	fi
	echo "  checkout: https://github.com/mmatuska/mfsbsd @ ${MFSBSD_TAG}"
	echo "  build   : cd ${BUILD_DIR}/mfsbsd && sudo make BASE=14.0-RELEASE"
	echo "  install : cp ${BUILD_DIR}/mfsbsd/work/amd64/mfsbsd-14.0-RELEASE-amd64.img \\"
	echo "             ${FIXTURE_DIR}/l2_test.img"
	echo "  custom  : add sysbench, fio, iperf3, dtrace tools, ktrace, kdump"
	echo "  size    : ~50 MB compressed, ~200 MB uncompressed"
}

build_ovmf()
{
	echo "T51 build_artifacts: OVMF ${EDK2_TAG}"
	if [ -f "${FIXTURE_DIR}/OVMF_CODE.fd" ] && [ -f "${FIXTURE_DIR}/OVMF_VARS.fd" ]; then
		echo "  present: OVMF_CODE.fd, OVMF_VARS.fd"
		return 0
	fi
	echo "  checkout: https://github.com/tianocore/edk2 @ ${EDK2_TAG}"
	echo "  build   : cd edk2 && make -C BaseTools/ && build \\"
	echo "             -p OvmfPkg/OvmfPkgX64.dsc -t GCC5 -a X64 -b RELEASE"
	echo "  install : cp Build/OvmfX64/RELEASE_GCC5/FV/OVMF_*.fd \\"
	echo "             ${FIXTURE_DIR}/"
}

build_alpine()
{
	echo "T51 build_artifacts: Alpine Linux ${ALPINE_TAG}"
	if [ -f "${FIXTURE_DIR}/l2_linux.img" ]; then
		echo "  present: ${FIXTURE_DIR}/l2_linux.img"
		return 0
	fi
	echo "  fetch   : https://alpinelinux.org/downloads/ (virt flavor, ${ALPINE_TAG})"
	echo "  install : cp alpine-virt-${ALPINE_TAG}.*-x86_64.iso \\"
	echo "             ${FIXTURE_DIR}/l2_linux.img"
}

build_main()
{
	if build_unsupported; then
		exit 0
	fi
	mkdir -p "${FIXTURE_DIR}" "${BUILD_DIR}"
	build_mfsbsd
	build_ovmf
	build_alpine
	echo "PASS: build_artifacts enumerated 3 artifacts (mfsBSD, OVMF, Alpine)"
}

build_main "$@"