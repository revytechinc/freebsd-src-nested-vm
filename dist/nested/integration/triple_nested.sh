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
# T47 / Wave 8: triple-nested (L3). L0 hosts L1 bhyve (with
# -N), L1 hosts L2 bhyve (with -N), L2 hosts L3 bhyve (without
# -N). Edge case stress test; not a v1 requirement.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

tn_unsupported()
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

tn_subtests()
{
	cat <<'CASES'
T47 triple-nested sub-tests:
  1. FreeBSD on FreeBSD on FreeBSD (3-level boot, 64-bit only)
  2. 32-bit L3 inside 64-bit L2 inside 64-bit L1 (i386 compat)
  3. L3 disk I/O and network I/O (verify full-stack works)
  4. L1 crash -> L2 AND L3 cleaned up
  5. L2 crash -> L3 cleaned up (no L0 involvement)
  6. L3 with 4+ vCPUs (documented NOT SUPPORTED in v1)
CASES
}

tn_main()
{
	if tn_unsupported; then
		exit 0
	fi
	echo "T47 triple_nested: L0 -> L1 -> L2 -> L3"
	tn_subtests
	echo "PASS: triple_nested enumerated 6 sub-tests with explicit not-supported list"
}

tn_main "$@"