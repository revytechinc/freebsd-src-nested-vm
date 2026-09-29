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
# T43 / Wave 8: SMP L1 stress with concurrent VMRUN/VMLAUNCH on
# multiple vCPUs. Tests 8 vCPUs x 8 L2 guests and per-vCPU L2 state
# isolation. Verifies no panics, no deadlocks, no ASID/VPID leaks.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

L1_VCPUS_DEFAULT=8
L2_PER_VCPU_DEFAULT=8
L1_VCPUS="${NESTED_SMP_VCPUS:-${L1_VCPUS_DEFAULT}}"
L2_PER_VCPU="${NESTED_SMP_L2_PER_VCPU:-${L2_PER_VCPU_DEFAULT}}"

: "${NESTED_TEST_DRIVER:=auto}"

smp_unsupported()
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

smp_plan()
{
	local vcpus="$1" l2="$2"
	local total=$((vcpus * l2))
	cat <<PLAN
SMP L1 plan:
  L1 vCPUs                = ${vcpus}
  L2 guests per vCPU      = ${l2}
  total L2 instances      = ${total}
  per-vCPU L2 launch      = concurrent (one L2 launch per vCPU thread)
  per-vCPU state          = VMRUN on vCPU 0, VMRESUME on vCPU 1 of same L2
  ASID/VPID leak check    = tagged-ASID test across vCPU 0 -> vCPU 1
  deadlock detector       = sysctl debug.witness.watch=1 (INVARIANTS kernel)
  failure threshold       = any panic, hang > 60s, or ASID leak = FAIL
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

smp_main()
{
	if smp_unsupported; then
		exit 0
	fi
	echo "T43 smp_l1: SMP L1 multi-vCPU launch"
	smp_plan "${L1_VCPUS}" "${L2_PER_VCPU}"
	local total=$((L1_VCPUS * L2_PER_VCPU))
	echo "SKIP: plan only -- ${total} L2 instances enumerated, none launched."
	echo "SKIP: this file contains no bhyve invocation; the concurrent"
	echo "SKIP: launcher it describes has not been written."
	exit 77
}

smp_main "$@"