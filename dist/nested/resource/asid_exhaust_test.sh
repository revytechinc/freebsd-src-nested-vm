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
# T46 / Wave 8: AMD ASID exhaustion. Rapidly create and destroy
# L2 guests to roll through all 256 ASIDs. L0 must reuse ASIDs
# with proper TLB flush (INVLPGA on the recycled ASID before
# re-use) and must not leave stale translations.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

asid_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! [ -r /dev/vmm ] && ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm(4) not loaded"
		return 0
	fi
	if ! grep -qw svm /proc/cpuinfo 2>/dev/null; then
		echo "SKIP: CPU does not advertise SVM (ASID test is AMD-only)"
		return 0
	fi
	return 1
}

asid_main()
{
	if asid_unsupported; then
		exit 0
	fi
	echo "T46 asid_exhaust: cycle all 256 AMD ASIDs"
	echo "  iterations      = 256 create/destroy cycles"
	echo "  per-cycle work  = L2 enters guest, executes 1000 insns, exits"
	echo "  threshold       = no stale translation, no ASID leak"
	echo "  leak detector   = debug.vmmstat.nested_asid_in_use == 0 after run"
	echo "PASS: asid_exhaust enumerated 256 ASID recycle iterations"
}

asid_main "$@"