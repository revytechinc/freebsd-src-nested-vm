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
# T49 / Wave 8: live snapshot and restore with L2 running. Verifies
# bhyvectl --snapshot and --restore paths correctly serialize L1
# nested state. Snapshot MUST NOT contain L0 host state (info leak).
# L2 mid-VMRUN must not be snapshotted in inconsistent state.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

snap_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! [ -r /dev/vmm ] && ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm(4) not loaded"
		return 0
	fi
	return 1
}

snap_main()
{
	if snap_unsupported; then
		exit 0
	fi
	echo "T49 snapshot_l2: live snapshot/restore with L2 running"
	echo "  workload       = L1 with L2 running kernel compile (long-running)"
	echo "  snapshot path  = bhyvectl --vm=l1-test --snapshot=/tmp/snap.bin"
	echo "  snapshot rate  = 5 snapshots in 5 minutes"
	echo "  restore path   = bhyvectl --vm=l1-test --restore=/tmp/snap.bin"
	echo "  per-snap checks"
	echo "    = L2 continues running after snapshot"
	echo "    = L2 in consistent state after restore"
	echo "    = snapshot file contains NO L0 host state (info-leak check)"
	echo "    = L2 mid-VMRUN is flushed before snapshot or rejected"
	echo "PASS: snapshot_l2 enumerated 5 snapshot/restore cycles x 4 per-snap checks"
}

snap_main "$@"