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
# disable-vmm-autoload.sh -- ensure /boot/loader.conf does NOT auto-load vmm.ko.
#
# Idempotent. Exits 0 whether or not a change was needed; reports
# SET / UNCHANGED.
#
# DEV/TEST ONLY: operator must explicitly `kldload vmm` after verifying
# the kernel boots cleanly. Especially critical during nested-virt dev
# where vmm panics are possible -- auto-load would create an unbreakable
# panic loop without physical / IPMI access.

# ROOT=/mnt/be edits a mounted boot environment instead of the live root.
ROOT=${ROOT:-}
LOADER_CONF=${ROOT}/boot/loader.conf

# Required loader.conf entry. vmm_load="NO" is the canonical disable form
# for the loader(8) autoboot mechanism.
LINE_VMM_LOAD='vmm_load="NO"'

log() {
	printf 'disable-vmm-autoload.sh: %s\n' "$*"
}

# ensure_loader_line <conf-path> <key="value">
#
# Append the literal key="value" to <conf-path> if it is not already
# present (active or commented). Idempotent.
ensure_loader_line() {
	_file=$1
	_line=$2

	if [ ! -f "$_file" ]; then
		: > "$_file"
	fi

	# Match active or commented form. Anchored regex avoids false
	# matches on substrings of other loader.conf entries. `\$` anchors
	# the end so a trailing comment on the same line does not produce
	# a spurious UNCHANGED report.
	if grep -Eq "^[[:space:]]*#?[[:space:]]*${_line}[[:space:]]*\$" "$_file"; then
		log "${_line} UNCHANGED (already in ${_file})"
		return 0
	fi

	# Capture file state BEFORE we write, so the brace-group append
	# below cannot race with a read on the same file.
	# `$(...)` strips trailing newlines from tail output, so an empty
	# tail result means the file already ends with \n.
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
		printf '# Do not auto-load vmm.ko at boot -- operator must explicitly kldload\n'
		printf '# after verifying the kernel boots cleanly. Critical during nested-virt\n'
		printf '# development where vmm panics are possible.\n'
		printf '%s\n' "$_line"
	} >> "$_file"

	log "${_line} SET (appended to ${_file})"
}

main() {
	log "ensuring vmm is not auto-loaded (checking ${LOADER_CONF})"
	ensure_loader_line "$LOADER_CONF" "$LINE_VMM_LOAD"

	# Live status report. If vmm is currently loaded, the operator can
	# `kldunload vmm` to drop back to a known-clean state. The point of
	# vmm_load="NO" is that on the NEXT boot, vmm will not load.
	if command -v kldstat >/dev/null 2>&1; then
		_loaded=$(kldstat -n vmm 2>/dev/null || true)
		if [ -n "$_loaded" ]; then
			log "live: vmm is currently loaded (kldstat -n vmm returned: ${_loaded})"
		else
			log "live: vmm is NOT loaded (kldstat -n vmm returned empty)"
		fi
	else
		log "kldstat(8) not present; skipping live-status report"
	fi

	exit 0
}

main "$@"
