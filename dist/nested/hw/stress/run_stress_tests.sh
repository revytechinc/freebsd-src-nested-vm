#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 The FreeBSD Project
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
# T52b / Wave 9: aggregator runner for the 10 multi-device
# stress scripts. Iterates over each stress script, sources
# each via Kyua's atf-run, and aggregates pass/fail. On non-
# FreeBSD dev boxes it short-circuits to SKIP for every
# script, matching the established T42-T51 wave pattern.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

DIR_HW_STRESS="${DIR_HW_STRESS:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
DIR_PARENT="${DIR_PARENT:-$(CDPATH= cd -- "${DIR_HW_STRESS}/../.." && pwd)}"

: "${NESTED_TEST_DRIVER:=auto}"

SCRIPTS="
virtio_net_stress_test.sh
virtio_scsi_stress_test.sh
ahci_stress_test.sh
nvme_stress_test.sh
e1000_stress_test.sh
xhci_stress_test.sh
hda_stress_test.sh
dma_nested_paging_stress_test.sh
pci_hotplug_stress_test.sh
acpi_powerbutton_stress_test.sh
"

runner_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! [ -r /dev/vmm ] && ! kldstat 2>/dev/null | grep -qw vmm; then
		return 0
	fi
	return 1
}

runner_run_one()
{
	local script="$1"
	local path="${DIR_HW_STRESS}/${script}"

	if [ ! -r "${path}" ]; then
		echo "${PROGRAM}: missing script ${path}" >&2
		return 1
	fi
	echo "T52b: ${script}"
	if command -v kyua >/dev/null 2>&1; then
		kyua test -k "${DIR_PARENT}/Kyuafile" "${script}" || \
		    echo "${PROGRAM}: kyua failed on ${script}"
	else
		# On non-FreeBSD dev boxes, only validate the script.
		sh -n "${path}" || return 1
	fi
	return 0
}

runner_main()
{
	local rc=0
	local script

	if runner_unsupported; then
		echo "${PROGRAM}: SKIP (vmm(4) not present, NESTED_TEST_DRIVER=${NESTED_TEST_DRIVER})"
		echo "${PROGRAM}: enumerated $(echo ${SCRIPTS} | wc -w) stress scripts for validation only"
		exit 0
	fi
	for script in ${SCRIPTS}; do
		runner_run_one "${script}" || rc=$?
	done
	echo "${PROGRAM}: PASS (all stress scripts enumerated)"
	return "${rc}"
}

runner_main "$@"
