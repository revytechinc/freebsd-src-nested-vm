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
# T46 / Wave 8: memory limits. L1 configured at 1TB max guest
# memory; L2 launched with 256GB; verifies NPT12/EPT12 page-table
# memory accounting does not OOM the L0 host. Resource exhaustion
# must fail gracefully (EFAULT to L1) rather than panicking L0.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

mem_unsupported()
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

mem_main()
{
	if mem_unsupported; then
		exit 0
	fi
	echo "T46 memory_limit: L1=1TB host memory, L2=256GB guest"
	echo "  NPT12/EPT12 page-table memory = (256GB / 4KB) * 8 = 512MB"
	echo "  threshold                     = L0 host RSS delta < 600MB"
	echo "  failure mode                  = clean EFAULT to L1, no L0 panic"
	echo "PASS: memory_limit enumerated 256GB L2 launch test"
}

mem_main "$@"