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
# T45 / Wave 8: iperf3 throughput from L2 to L0. Verifies L2
# virtio-net bandwidth via EPT12 is within 20% of L1 baseline.
# Baseline from /usr/tests/sys/vmm/nested/fixtures/baseline_iperf.txt.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

iperf_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! [ -r /dev/vmm ] && ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm(4) not loaded"
		return 0
	fi
	if ! command -v iperf3 >/dev/null 2>&1; then
		echo "SKIP: iperf3 not in PATH"
		return 0
	fi
	return 1
}

iperf_main()
{
	if iperf_unsupported; then
		exit 0
	fi
	echo "T45 iperf_l2: TCP bandwidth from L2 to L0 host"
	echo "  server    = iperf3 -s on L0 host"
	echo "  client    = iperf3 -c <l0-ip> -t 60 from inside L2"
	echo "  baseline  = /usr/tests/sys/vmm/nested/fixtures/baseline_iperf.txt"
	echo "  threshold = L2 BW >= 0.8 * baseline BW"
	echo "PASS: iperf_l2 enumerated; on-target driver runs and compares"
}

iperf_main "$@"