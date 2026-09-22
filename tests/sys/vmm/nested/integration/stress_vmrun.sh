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
# T43 / Wave 8: 1000-cycle VMRUN/VMRESUME stress test. Repeatedly
# enters and exits L2 from L1 to detect TLB leaks, resource leaks,
# and ordering bugs. Tracks per-cycle ASID/VPID, host RIP/RSP, and
# NPT12/EPT12 root GPA for consistency.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

# 10, not the 1000 in the header. Each cycle is a full L2 boot of roughly
# ten seconds, so 1000 cycles is hours of wall clock -- a default nobody runs
# is the same as no test. Raise it with NESTED_STRESS_CYCLES for a long soak.
CYCLES_DEFAULT=10
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


# WHAT THIS FILE DOES, PLAINLY: it enumerates a plan. It does not launch a
# guest, and it never did -- there is no bhyve invocation anywhere in it.
#
# It used to end by echoing "PASS: ... enumerated ...". The word "enumerated"
# was honest; reporting it as PASS was not. A plan that prints itself cannot
# fail, so this reported success on every host, on every build, including ones
# where nested virtualization was completely broken -- and it was counted as
# nested coverage the fleet did not have.
#
# It exits 77 (SKIP) until the driver exists. A skip is a gap you can see; a
# PASS is a gap that looks like coverage.

stress_main()
{
	if stress_unsupported; then
		exit 0
	fi

	# REAL now. This used to print a plan and echo PASS; see the git log.
	# It drives l2_smoke.sh, which boots N L2 guests inside ONE L1 -- that
	# is the repeated VMRUN/VMRESUME path this test is named for, and
	# reusing the one implementation avoids a second copy of the console
	# plumbing drifting away from the first.
	#
	# The cycle default here is deliberately far below the 1000 in the
	# header: each cycle is a full L2 boot, so 1000 is hours. Ask for more
	# with NESTED_STRESS_CYCLES when you have the wall clock to spend.
	_smoke="$(dirname "$0")/l2_smoke.sh"
	[ -r "$_smoke" ] || { echo "SKIP: l2_smoke.sh not beside this script"; exit 77; }
	[ -n "${L1_IMAGE:-}" ] || {
		echo "SKIP: L1_IMAGE not set -- this test needs a full FreeBSD"
		echo "SKIP: UFS image for L1 (the fixtures/ image is the L2 guest)."
		exit 77
	}

	echo "T43 stress_vmrun: ${CYCLES} L2 entries from one L1"
	L2_CYCLES="${CYCLES}" exec /bin/sh "$_smoke"
}

stress_main "$@"