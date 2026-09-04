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
# T51 / Wave 8: non-EFI text-capture smoke test for L2 mfsBSD.
# Boots mfsBSD in bhyve without UEFI firmware (BIOS/legacy path),
# captures text output via serial console, parses for PASS/FAIL
# markers emitted by the mfsBSD autorun script. This is the
# headless/CI-friendly test path required by the plan.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##/*}"

L2_IMAGE="${NESTED_L2_IMAGE:-/usr/tests/sys/vmm/nested/fixtures/l2_test.img}"
L2_NAME="${NESTED_L2_NAME:-l2-test}"
L2_VCPUS="${NESTED_L2_VCPUS:-1}"
L2_MEMORY="${NESTED_L2_MEMORY:-1G}"
LOG_DIR="${NESTED_L2_LOG_DIR:-/tmp}"
BOOT_TIMEOUT="${NESTED_L2_BOOT_TIMEOUT:-60}"

: "${NESTED_TEST_DRIVER:=auto}"

smoke_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! command -v bhyve >/dev/null 2>&1; then
		echo "SKIP: bhyve not in PATH (non-FreeBSD host)"
		return 0
	fi
	if ! [ -r /dev/vmm ] && ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm(4) not loaded"
		return 0
	fi
	if ! [ -f "${L2_IMAGE}" ]; then
		echo "SKIP: ${L2_IMAGE} not present (build per tests/sys/vmm/nested/README.artifacts.md)"
		return 0
	fi
	return 1
}

smoke_launch()
{
	echo "T51 run_l2_smoke: non-EFI text-capture boot"
	echo "  image       = ${L2_IMAGE}"
	echo "  vm name     = ${L2_NAME}"
	echo "  vcpus       = ${L2_VCPUS}"
	echo "  memory      = ${L2_MEMORY}"
	echo "  boot mode   = BIOS/legacy (no -l bootrom)"
	echo "  serial out  = stdio (text captured)"
	echo "  logfile     = ${LOG_DIR}/l2_smoke_$(date +%s).log"

	local logfile="${LOG_DIR}/l2_smoke_$$_${L2_NAME}_$(date +%s).log"

	bhyve \
	    -c "${L2_VCPUS}" \
	    -m "${L2_MEMORY}" \
	    -l com1,stdio \
	    -s 0,hostbridge \
	    -s 1,lpc \
	    -s 2,virtio-blk,"${L2_IMAGE}" \
	    "${L2_NAME}" 2>&1 | tee "${logfile}"

	if grep -q 'ALL TESTS PASSED' "${logfile}"; then
		echo "L2 SMOKE TEST: PASS"
		rm -f "${logfile}"
		return 0
	elif grep -q 'TESTS FAILED' "${logfile}"; then
		echo "L2 SMOKE TEST: FAIL"
		grep '^FAIL:' "${logfile}" || true
		return 1
	else
		echo "L2 SMOKE TEST: INCONCLUSIVE (no PASS/FAIL marker in ${logfile})"
		return 2
	fi
}

smoke_main()
{
	if smoke_unsupported; then
		exit 0
	fi
	smoke_launch
}

smoke_main "$@"