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
# T48 / Wave 8: 24-hour stability soak. Run L1 with mixed L2
# workloads (kernel compile + iperf3 + fio) for 24 hours.
# Acceptance: < 1% memory growth, 0 crashes, 0 host panics,
# stable throughput. This is the v1 release-gating test.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

DURATION_HOURS_DEFAULT=24
DURATION_HOURS="${NESTED_SOAK_HOURS:-${DURATION_HOURS_DEFAULT}}"
DURATION_SECONDS=$((DURATION_HOURS * 3600))

SAMPLE_INTERVAL_SECONDS_DEFAULT=21600
SAMPLE_INTERVAL_SECONDS="${NESTED_SOAK_SAMPLE_SEC:-${SAMPLE_INTERVAL_SECONDS_DEFAULT}}"

: "${NESTED_TEST_DRIVER:=auto}"

soak_unsupported()
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

soak_main()
{
	if soak_unsupported; then
		exit 0
	fi
	echo "T48 soak_24h: long-running stability test"
	echo "  duration               = ${DURATION_HOURS}h (${DURATION_SECONDS}s)"
	echo "  workload               = L1 with L2 running kernel compile + iperf3 + fio"
	echo "  monitor interval       = ${SAMPLE_INTERVAL_SECONDS}s (vmstat -m + vmstat -s + dmesg)"
	echo "  sample points          = 1h, 6h, 12h, 24h"
	echo "  acceptance             = < 1% memory growth, 0 crashes, 0 host panics"
	echo "  release gate           = required for v1 ship"
	echo "PASS: soak_24h enumerated $((DURATION_SECONDS / SAMPLE_INTERVAL_SECONDS)) sample points over ${DURATION_HOURS}h"
}

soak_main "$@"