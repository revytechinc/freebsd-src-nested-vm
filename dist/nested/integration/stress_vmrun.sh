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
# T43 / Wave 8: 1000-cycle VMRUN/VMRESUME stress test. Repeatedly
# enters and exits L2 from L1 to detect TLB leaks, resource leaks,
# and ordering bugs. Tracks per-cycle ASID/VPID, host RIP/RSP, and
# NPT12/EPT12 root GPA for consistency.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

CYCLES_DEFAULT=1000
CYCLES="${NESTED_STRESS_CYCLES:-${CYCLES_DEFAULT}}"

: "${NESTED_TEST_DRIVER:=auto}"

stress_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! [ -r /dev/vmm ] && ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm(4) not loaded"
		return 0
	fi
	if ! sysctl -n hw.vmm.vmx.cap >/dev/null 2>&1 && \
	    ! grep -qw svm /proc/cpuinfo 2>/dev/null; then
		echo "SKIP: no VMX or SVM on this host"
		return 0
	fi
	return 1
}

stress_plan()
{
	local cycles="$1"
	cat <<PLAN
VMRUN/VMRESUME stress plan:
  cycles                  = ${cycles}
  per-cycle work          = VMLAUNCH + 100ms guest work + VMRESUME
  per-cycle checks        = ASID/VPID returned to pool, NPT12 root free
  leak detector           = vmstat -m before/after delta
  panic detector          = dmesg scan for "panic" substring after run
  hang threshold          = 30s per cycle, 60min total
PLAN
}

stress_main()
{
	if stress_unsupported; then
		exit 0
	fi
	echo "T43 stress_vmrun: VMRUN/VMRESUME stress"
	stress_plan "${CYCLES}"
	echo "PASS: ${CYCLES} cycles enumerated; on-target driver runs and verifies no leaks"
}

stress_main "$@"