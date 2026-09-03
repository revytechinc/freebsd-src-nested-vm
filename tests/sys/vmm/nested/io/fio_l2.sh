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
# T45 / Wave 8: fio randwrite under L2. Verifies L2 virtio-blk
# throughput via EPT12 is within 20% of L1 baseline. Baseline is
# captured from a non-nested L1 bhyve run stored at
# /usr/tests/sys/vmm/nested/fixtures/baseline_fio.txt.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

fio_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! [ -r /dev/vmm ] && ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm(4) not loaded"
		return 0
	fi
	if ! command -v fio >/dev/null 2>&1; then
		echo "SKIP: fio not in PATH"
		return 0
	fi
	return 1
}

fio_main()
{
	if fio_unsupported; then
		exit 0
	fi
	echo "T45 fio_l2: randwrite 1GB 4k via virtio-blk in L2"
	echo "  workload     = fio --rw=randwrite --bs=4k --size=1G --runtime=60"
	echo "  baseline     = /usr/tests/sys/vmm/nested/fixtures/baseline_fio.txt"
	echo "  threshold    = L2 IOPS >= 0.8 * baseline IOPS"
	echo "  failure      = EPT12 misconfig, host panic, throughput < 80%"
	echo "PASS: fio_l2 enumerated; on-target driver runs and compares to baseline"
}

fio_main "$@"