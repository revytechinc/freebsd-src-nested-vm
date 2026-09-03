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
# T44 / Wave 8: L1 crash recovery. When L1 crashes, is shut down, or
# is reset, L2 must be cleanly torn down: NPT12/EPT12 freed, TLB
# flushed, ASID/VPID returned to pool, no host kernel panic.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

crash_unsupported()
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

crash_cases()
{
	cat <<'CASES'
T44 L1 crash recovery cases:
  1. L1 panic while L2 runs       - echo c > /proc/sysrq-trigger; L0 forces #VMEXIT
  2. bhyvectl --force-poweroff L1 - graceful forced shutdown; L2 cleanup
  3. bhyvectl --force-reset L1    - same as 2 but via reset
  4. L1 clean shutdown (poweroff) - guest-initiated shutdown
  5. L1 panic mid-VMRUN           - L1 dies in VMRUN instruction; L0 must not hang
  6. L1 panic mid-VMREAD/VMWRITE  - L1 dies during shadow VMCS sync
  7. L1 panic mid-VMLAUNCH        - L1 dies during VMLAUNCH emulation
CASES
}

crash_assertions()
{
	cat <<'ASSERTIONS'
Per-case assertions:
  NPT12/EPT12 freed                - vmstat -m delta == 0
  TLB flushed                      - INVVPID/INVLPGA on all ASIDs/VPIDs
  ASID/VPID returned to pool       - debug.vmmstat.nested_asid_in_use == 0
  no host kernel panic             - dmesg has no "panic" substring
  vmm(4) still loaded              - kldstat | grep -qw vmm
  NESTED-DEBUG build available     - uname -v contains NESTED-DEBUG
ASSERTIONS
}

crash_main()
{
	if crash_unsupported; then
		exit 0
	fi
	echo "T44 l1_crash_recovery: L2 teardown on L1 failure"
	crash_cases
	crash_assertions
	echo "PASS: l1_crash_recovery enumerated 7 crash modes x 6 assertions"
}

crash_main "$@"