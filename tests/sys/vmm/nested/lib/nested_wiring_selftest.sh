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
# Build-wiring invariants for tests/sys/vmm/nested.
#
# Two ways a test in this tree becomes invisible without anything
# erroring, both of which have already happened here:
#
# 1. A directory containing test programs listed in SUBDIR instead of
#    TESTS_SUBDIRS.  share/mk/suite.test.mk generates the installed
#    Kyuafile and emits `include("<dir>/Kyuafile")` only for
#    TESTS_SUBDIRS:
#
#	.for _T in ${TESTS_SUBDIRS:N.WAIT}
#		@echo "include(\"${_T}/${.TARGET}\")" >>${.TARGET}.tmp
#	.endfor
#
#    so the files install to /usr/tests and kyua(1) walks straight past
#    them.  bsd.test.mk documents the distinction explicitly: "list here
#    any directories that contain test programs but use SUBDIR for
#    directories that may contain helper binaries and/or data files."
#    The parent tests/sys/vmm/Makefile gets this right; this directory
#    did not.
#
# 2. A script present in the directory but not named in that directory's
#    Makefile.  It is never installed, so it cannot run on any host, and
#    nothing reports an error -- the package simply lacks it.
#    svm_basic.sh was in this state: the only AMD-specific basic test in
#    the tree, in no Makefile, shipped nowhere.

set -u

SELF="${0##*/}"
NESTED="${NESTED:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"

failures=0
checks=0

fail()
{
	printf 'FAIL %s\n' "$1"
	failures=$((failures + 1))
	checks=$((checks + 1))
}
ok()
{
	printf 'ok   %s\n' "$1"
	checks=$((checks + 1))
}

# --- 1. a directory that holds ATF test programs must be reachable by
#        kyua, which means TESTS_SUBDIRS in its PARENT's Makefile.
#
# The signal for "holds test programs" is the directory's own Makefile
# declaring ATF_TESTS_SH, or itself listing TESTS_SUBDIRS.  That is the
# same signal bsd.test.mk uses, so the check cannot drift from the build.

holds_tests()
{
	_m="$1/Makefile"
	[ -r "${_m}" ] || return 1
	LC_ALL=C grep -q '^ATF_TESTS_SH' "${_m}" && return 0
	LC_ALL=C grep -q '^TESTS_SUBDIRS' "${_m}" && return 0
	return 1
}

check_parent()
{
	_parent="$1"
	_mk="${_parent}/Makefile"
	[ -r "${_mk}" ] || return 0

	for _sub in "${_parent}"/*/; do
		_sd=${_sub%/}
		_name=${_sd##*/}
		holds_tests "${_sd}" || continue

		if LC_ALL=C grep -q "^TESTS_SUBDIRS+=[[:space:]]*${_name}\$" "${_mk}"; then
			ok "${_parent#${NESTED}/}/${_name}: reachable by kyua"
		elif LC_ALL=C grep -q "^SUBDIR+=[[:space:]]*${_name}\$" "${_mk}"; then
			fail "${_parent#${NESTED}/}/${_name}: in SUBDIR, not TESTS_SUBDIRS -- installs but kyua never descends"
		else
			fail "${_parent#${NESTED}/}/${_name}: holds ATF tests but is in no SUBDIR at all -- never built"
		fi
	done
}

check_parent "${NESTED}"
check_parent "${NESTED}/hw"

# --- 2. every .sh in a directory is declared in that directory's Makefile
for d in "${NESTED}"/ "${NESTED}"/*/ "${NESTED}"/hw/*/; do
	[ -d "${d}" ] || continue
	dmk="${d}Makefile"
	[ -r "${dmk}" ] || continue
	for f in "${d}"*.sh; do
		[ -e "${f}" ] || continue
		b=${f##*/}
		stem=${b%.sh}
		if LC_ALL=C grep -q -- "${b}" "${dmk}" || \
		   LC_ALL=C grep -q -- "${stem}" "${dmk}"; then
			:
		else
			fail "${d#${NESTED}/}${b} is in no Makefile -- never installed"
		fi
	done
done
ok "checked every script against its directory Makefile"

# --- 3. a bare `FILES+=' installs NOTHING here, silently.
#
# bsd.files.mk:13 is `FILESGROUPS?= FILES', but bsd.test.mk:23 has
# already done `FILESGROUPS+= ${PACKAGE}FILES', so the `?=' is a no-op
# and the plain FILES group is never iterated.  A Makefile that says
# `FILES+= foo.sh' therefore installs foo.sh nowhere, builds cleanly and
# reports no error.  perf/Makefile was in exactly this state on both
# branches.  Raised by Fable in review; verified against share/mk.
for d in "${NESTED}"/ "${NESTED}"/*/ "${NESTED}"/hw/*/; do
	[ -d "${d}" ] || continue
	dmk="${d}Makefile"
	[ -r "${dmk}" ] || continue
	if LC_ALL=C grep -q '^FILES[+:]*=' "${dmk}"; then
		fail "${d#${NESTED}/}Makefile uses a bare FILES+= -- installs nothing (use \${PACKAGE}FILES+=)"
	fi
done
ok "no Makefile relies on the bare FILES group"

printf '\n%s: %d checks, %d failures\n' "${SELF}" "${checks}" "${failures}"
[ "${failures}" -eq 0 ] || exit 1
exit 0
