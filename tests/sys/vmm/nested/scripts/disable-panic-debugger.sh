#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 The FreeBSD Foundation
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
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
# disable-panic-debugger.sh -- ensure /etc/sysctl.conf sets panic-reboot sysctls.
#
# Idempotent: safe to run multiple times. Exits 0 whether or not a change was
# needed; reports SET / UNCHANGED per sysctl line.
#
# DEV/TEST ONLY: this disables the kernel debugger on panic. Production
# systems should keep DDB enabled for fault diagnosis. See the companion
# man page disable-panic-debugger(8).

# ROOT=/mnt/be points the edits at a mounted boot environment instead of
# the running system (live sysctls are then left alone).
ROOT=${ROOT:-}
SYSCTL_CONF=${ROOT}/etc/sysctl.conf

# Required sysctl assignments (key=value form, no trailing whitespace).
LINE_DEBUGGER="debug.debugger_on_panic=0"
LINE_REBOOT_WAIT="kern.panic_reboot_wait_time=5"
# Reboot is not enough if the box is wedged. Power-cycle so firmware
# re-inits devices. A hang with no panic still needs watchdog/IPMI.
LINE_POWERCYCLE="kern.powercycle_on_panic=1"

log() {
	printf 'disable-panic-debugger.sh: %s\n' "$*"
}

# ensure_sysctl_line <conf-path> <key=value>
#
# Append the literal key=value to <conf-path> if it is not already present
# (either as an active assignment or as a commented-out line). Idempotent.
ensure_sysctl_line() {
	_file=$1
	_line=$2

	if [ ! -f "$_file" ]; then
		: > "$_file"
	fi

	# Match either an active assignment or a commented-out version.
	# Anchored regex avoids false matches on substrings of other sysctls.
	# `\$` anchors the end so trailing characters (like a comment on the
	# same line) do not produce a spurious UNCHANGED report.
	if grep -Eq "^[[:space:]]*#?[[:space:]]*${_line}[[:space:]]*\$" "$_file"; then
		log "${_line} UNCHANGED (already in ${_file})"
		return 0
	fi

	# Capture file state BEFORE we write, so the brace-group append below
	# cannot race with a read on the same file.
	#
	# `_needs_sep` is 1 when the file is non-empty: a blank separator line
	# is needed between existing content and our appended block.
	#
	# `_needs_trailing_nl` is 1 when the file is non-empty and does not
	# already end with a newline. $(...) strips trailing newlines, so an
	# empty tail output means the file already ends with \n; anything
	# non-empty means we must add one before our block to avoid run-on.
	_needs_sep=0
	_needs_trailing_nl=0
	if [ -s "$_file" ]; then
		_needs_sep=1
		_last=$(tail -c 1 "$_file" 2>/dev/null || true)
		if [ -n "$_last" ]; then
			_needs_trailing_nl=1
		fi
	fi

	{
		if [ "$_needs_trailing_nl" -eq 1 ]; then
			printf '\n'
		fi
		if [ "$_needs_sep" -eq 1 ]; then
			printf '\n'
		fi
		printf '# Auto-reboot on nested-virt development kernel panics.\n'
		printf '# Do not sit in DDB; reboot so the host can be recovered\n'
		printf '# via SSH or IPMI without physical console access.\n'
		printf '%s\n' "$_line"
	} >> "$_file"

	log "${_line} SET (appended to ${_file})"
}

apply_live()
{
	_kv=$1
	_key=${_kv%%=*}
	_val=${_kv#*=}
	if ! command -v sysctl >/dev/null 2>&1; then
		return 0
	fi
	if [ -n "$ROOT" ]; then
		log "live ${_key} not applied (ROOT=${ROOT})"
		return 0
	fi
	if [ "$(id -u)" -ne 0 ]; then
		log "live ${_key} not applied (not root)"
		return 0
	fi
	if sysctl -n "$_key" >/dev/null 2>&1; then
		sysctl "${_key}=${_val}" >/dev/null || log "live set ${_kv} failed"
	else
		log "live ${_key} not present on this kernel"
	fi
}

main() {
	log "ensuring panic-reboot sysctls in ${SYSCTL_CONF}"
	ensure_sysctl_line "$SYSCTL_CONF" "$LINE_DEBUGGER"
	ensure_sysctl_line "$SYSCTL_CONF" "$LINE_REBOOT_WAIT"
	ensure_sysctl_line "$SYSCTL_CONF" "$LINE_POWERCYCLE"

	# Persist is not enough: a host that already booted with DDB on
	# (freedev002) will sit in the debugger on the *next* panic until
	# the live sysctl is flipped too.
	apply_live "$LINE_DEBUGGER"
	apply_live "$LINE_REBOOT_WAIT"
	apply_live "$LINE_POWERCYCLE"

	if command -v sysctl >/dev/null 2>&1; then
		_live=$(sysctl -n debug.debugger_on_panic 2>/dev/null) || _live=unavailable
		log "live debug.debugger_on_panic=${_live}"
		_live=$(sysctl -n kern.panic_reboot_wait_time 2>/dev/null) || _live=unavailable
		log "live kern.panic_reboot_wait_time=${_live}"
		_live=$(sysctl -n kern.powercycle_on_panic 2>/dev/null) || _live=unavailable
		log "live kern.powercycle_on_panic=${_live}"
	else
		log "sysctl(8) not present; skipping live-value report"
	fi

	exit 0
}

main "$@"
