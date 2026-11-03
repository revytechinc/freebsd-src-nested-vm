#!/bin/sh
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
# End-to-end self-test for nested-test(8).
#
# This drives the real runner against a synthetic suite whose members are
# known-good, known-bad and known-unrunnable, and asserts the runner's
# EXIT CODE -- not its output.  The runners this replaces printed
# "PASS (all device classes enumerated)" and exited 0 with a planted
# `exit 1` test in the suite; that was demonstrated, not inferred.

set -u

SELF="${0##*/}"
HERE="${HERE:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
RUNNER="${HERE}/../nested-test"

failures=0
checks=0

check()
{
	checks=$((checks + 1))
	if [ "$2" = "$3" ]; then
		printf 'ok   %s (got %s)\n' "$1" "$3"
	else
		printf 'FAIL %s: wanted %s, got %s\n' "$1" "$2" "$3"
		failures=$((failures + 1))
	fi
}

if [ ! -x "${RUNNER}" ]; then
	printf '%s: %s is not executable\n' "${SELF}" "${RUNNER}" >&2
	printf '%s: red state -- the runner does not exist yet\n' "${SELF}" >&2
	exit 1
fi

WORK=$(mktemp -d) || { printf '%s: mktemp -d failed\n' "${SELF}" >&2; exit 2; }
trap 'rm -rf "${WORK}"' EXIT INT TERM HUP

mksuite()
{
	SUITE="${WORK}/$1"
	mkdir -p "${SUITE}"
}

# --- a suite where everything passes exits 0 -----------------------------
mksuite allgood
printf '#!/bin/sh\nexit 0\n' > "${SUITE}/a_test.sh"
printf '#!/bin/sh\nexit 0\n' > "${SUITE}/b_test.sh"
chmod +x "${SUITE}"/*.sh
"${RUNNER}" run --suite-dir "${SUITE}" >/dev/null 2>&1
check "suite of passes exits 0" 0 $?

# --- ONE failing member must make the whole run fail.  This is the exact
#     case that shipped: the old runner exited 0 here.
mksuite onebad
printf '#!/bin/sh\nexit 0\n' > "${SUITE}/a_test.sh"
printf '#!/bin/sh\nexit 1\n' > "${SUITE}/b_test.sh"
chmod +x "${SUITE}"/*.sh
"${RUNNER}" run --suite-dir "${SUITE}" >/dev/null 2>&1
check "suite with one FAIL exits 1" 1 $?

# --- a member that cannot run must be ERROR (2), outranking FAIL --------
mksuite unrunnable
printf '#!/bin/sh\nexit 1\n' > "${SUITE}/a_test.sh"
printf '#!/bin/sh\nexit 0\n' > "${SUITE}/b_test.sh"
chmod +x "${SUITE}/a_test.sh"
# b is not executable: it cannot run.  That is not a failing test.
chmod 000 "${SUITE}/b_test.sh"
"${RUNNER}" run --suite-dir "${SUITE}" >/dev/null 2>&1
check "unrunnable member exits 2 (ERROR outranks FAIL)" 2 $?

# --- an EMPTY suite must not exit 0.  Selecting nothing is not passing. --
mksuite empty
"${RUNNER}" run --suite-dir "${SUITE}" >/dev/null 2>&1
check "empty suite does not exit 0" 2 $?

# --- a suite directory that does not exist is ERROR, not PASS -----------
"${RUNNER}" run --suite-dir "${WORK}/no-such-dir" >/dev/null 2>&1
check "absent suite dir exits 2" 2 $?

# --- a member that hangs must be ERROR on timeout, not hang the run -----
mksuite hang
printf '#!/bin/sh\nsleep 60\n' > "${SUITE}/a_test.sh"
chmod +x "${SUITE}"/*.sh
NV_TIMEOUT=2 "${RUNNER}" run --suite-dir "${SUITE}" >/dev/null 2>&1
check "hanging member exits 2 under NV_TIMEOUT" 2 $?

# --- the runner must never print the word PASS for a run that did not
#     pass.  The replaced runners printed it unconditionally.
mksuite saypass
printf '#!/bin/sh\nexit 1\n' > "${SUITE}/a_test.sh"
chmod +x "${SUITE}"/*.sh
out=$("${RUNNER}" run --suite-dir "${SUITE}" 2>&1)
if printf '%s' "${out}" | LC_ALL=C grep -q 'verdict=PASS'; then
	check "failing run never reports verdict=PASS" clean dirty
else
	check "failing run never reports verdict=PASS" clean clean
fi

# --- machine-readable rows for the fleet MCP to aggregate ---------------
mksuite rows
printf '#!/bin/sh\nexit 0\n' > "${SUITE}/a_test.sh"
printf '#!/bin/sh\nexit 1\n' > "${SUITE}/b_test.sh"
chmod +x "${SUITE}"/*.sh
rows=$("${RUNNER}" run --suite-dir "${SUITE}" --rows 2>/dev/null | LC_ALL=C grep -c '^\(PASS\|FAIL\|ERROR\|NA\|GAP\)	')
check "--rows emits one row per case" 2 "${rows}"

printf '\n%s: %d checks, %d failures\n' "${SELF}" "${checks}" "${failures}"
[ "${failures}" -eq 0 ] || exit 1
exit 0
