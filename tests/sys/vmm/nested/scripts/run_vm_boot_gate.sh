#!/bin/sh
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
# VM boot gate for a candidate GENERIC kernel (and optional vmm.ko).
#
# Mandatory before any bare-metal kernel/vmm.ko install:
#   boot the candidate as a bhyve GUEST on a host that already has a
#   known-good hypervisor.  Do not kldload the candidate vmm.ko on the
#   hypervisor host.
#
# PASS: guest serial shows the kernel identified itself (FreeBSD x.y-CURRENT
# or ---<<BOOT>>---) and reached Timecounter, mountroot, or a login/shell
# prompt.
# Nested features (hw.vmm.nested.*) may be missing or 0 — that is not
# a failure.  A panic after those markers (e.g. missing /sbin/init on
# the throwaway UFS image) is also not a failure: the kernel booted.
#
# FAIL: bhyveload/bhyve error, panic/trap before boot markers, or
# timeout with no boot markers.
#
# Usage:
#   run_vm_boot_gate.sh                  # boot NESTED_GATE_KERNEL (or /boot/kernel/kernel)
#   run_vm_boot_gate.sh classify <log>   # classify a captured serial log
#   run_vm_boot_gate.sh selftest         # classifier fixtures (no VM, any OS)

# shellcheck shell=sh
set -eu

PROGRAM="${0##*/}"

KERNEL="${NESTED_GATE_KERNEL:-}"
VMM_KO="${NESTED_GATE_VMM_KO:-}"
BOOT_SRC="${NESTED_GATE_BOOT_SRC:-/boot}"
MEM_MB="${NESTED_GATE_MEM_MB:-512}"
TIMEOUT="${NESTED_GATE_TIMEOUT:-90}"
: "${NESTED_TEST_DRIVER:=auto}"

# Kernel ident is the uname banner, not getty's "FreeBSD/amd64 (host) (ttyu0)".
IDENT_RE='FreeBSD [0-9]+\.[0-9]+-(CURRENT|STABLE|RELEASE)|FreeBSD/amd64|---<<BOOT>>---'
ALIVE_RE='Timecounter|mountroot>|login:|Welcome to FreeBSD|Entering /bin/sh'
PANIC_RE='panic:|Fatal trap [[:digit:]]+|double fault'

log()
{
	printf '%s\n' "$*"
}

die()
{
	log "FAIL: $*"
	exit 1
}

# First 1-based line matching ERE, or 0.
first_line()
{
	_f="$1"
	_p="$2"
	_n=$(grep -nE -- "$_p" "$_f" 2>/dev/null | head -1 | cut -d: -f1)
	if [ -n "$_n" ]; then
		printf '%s\n' "$_n"
	else
		printf '0\n'
	fi
}

# Classify a serial log. Nested sysctls never decide the result.
# Prints RESULT/REASON/NOTE lines. Exit 0 PASS, 1 FAIL.
classify_boot_log()
{
	_log=$1
	if [ ! -f "$_log" ]; then
		log "RESULT: FAIL"
		log "REASON: serial log missing ($_log)"
		return 1
	fi

	_ident=$(first_line "$_log" "$IDENT_RE")
	_alive=$(first_line "$_log" "$ALIVE_RE")
	_panic=$(first_line "$_log" "$PANIC_RE")

	if grep -qE 'hw\.vmm\.nested' "$_log" 2>/dev/null; then
		log "NOTE: nested sysctl text present (not required for this gate)"
	else
		log "NOTE: nested features absent/unsupported — ignored (boot-only gate)"
	fi

	if [ "$_ident" -gt 0 ] && [ "$_alive" -gt 0 ]; then
		if [ "$_panic" -gt 0 ] && [ "$_panic" -lt "$_ident" ]; then
			log "RESULT: FAIL"
			log "REASON: panic/trap at line $_panic before kernel ident at line $_ident"
			return 1
		fi
		log "RESULT: PASS"
		if [ "$_panic" -gt "$_alive" ]; then
			log "REASON: kernel booted (ident line $_ident, alive line $_alive); later panic is not a boot failure"
		else
			log "REASON: kernel booted (ident line $_ident, alive line $_alive)"
		fi
		return 0
	fi

	if [ "$_panic" -gt 0 ]; then
		log "RESULT: FAIL"
		log "REASON: panic/trap at line $_panic with no boot markers"
		return 1
	fi

	log "RESULT: FAIL"
	log "REASON: no kernel ident + Timecounter/mountroot/login in serial log"
	return 1
}

selftest_classifier()
{
	_td=$(mktemp -d "${TMPDIR:-/tmp}/nv-boot-gate-selftest.XXXXXX")
	_fail=0

	# RED fixture: panic, no boot.
	printf '%s\n' \
	    "bhyve: vm created" \
	    "panic: vm_init: NULL deref" \
	    "Fatal trap 12: page fault while in kernel mode" \
	    > "$_td/panic_early.log"
	if classify_boot_log "$_td/panic_early.log" > "$_td/panic_early.out"; then
		log "SELFTEST FAIL: panic_early should be FAIL"
		_fail=1
	elif ! grep -q 'RESULT: FAIL' "$_td/panic_early.out"; then
		log "SELFTEST FAIL: panic_early missing RESULT: FAIL"
		_fail=1
	else
		log "SELFTEST PASS: panic_early -> FAIL"
	fi

	# GREEN fixture: boots, no nested features.
	printf '%s\n' \
	    "Consoles: userboot" \
	    "FreeBSD 16.0-CURRENT #0: test GENERIC" \
	    "FreeBSD/amd64 (guest) (ttyu0)" \
	    "Timecounter \"TSC\" frequency 2600000000 Hz quality 1000" \
	    "Trying to mount root from ufs:/dev/vtbd0 []..." \
	    "mountroot>" \
	    > "$_td/boot_ok.log"
	if ! classify_boot_log "$_td/boot_ok.log" > "$_td/boot_ok.out"; then
		log "SELFTEST FAIL: boot_ok should be PASS"
		_fail=1
	elif ! grep -q 'RESULT: PASS' "$_td/boot_ok.out"; then
		log "SELFTEST FAIL: boot_ok missing RESULT: PASS"
		_fail=1
	elif ! grep -q 'nested features absent' "$_td/boot_ok.out"; then
		log "SELFTEST FAIL: boot_ok should note absent nested features"
		_fail=1
	else
		log "SELFTEST PASS: boot_ok (no nested features) -> PASS"
	fi

	# GREEN: nested sysctls missing AND later init panic still PASS.
	printf '%s\n' \
	    "Copyright (c) 1992-2026 The FreeBSD Project." \
	    "FreeBSD/amd64 (nv-boot-gate) (ttyu0)" \
	    "Timecounter \"ACPI-fast\" frequency 3579545 Hz quality 900" \
	    "mountroot: waiting for device /dev/gpt/rootfs..." \
	    "panic: init died (signal 0, exit 1)" \
	    > "$_td/boot_then_init_panic.log"
	if ! classify_boot_log "$_td/boot_then_init_panic.log" > "$_td/boot_then_init_panic.out"; then
		log "SELFTEST FAIL: boot_then_init_panic should be PASS"
		_fail=1
	else
		log "SELFTEST PASS: boot then missing-init panic -> PASS"
	fi

	# GREEN: login prompt, nested=0 mentioned.
	printf '%s\n' \
	    "FreeBSD/amd64 (guest) (ttyu0)" \
	    "Timecounter \"TSC-low\" frequency 1000000000 Hz quality 1000" \
	    "hw.vmm.nested.vmx: 0" \
	    "hw.vmm.nested.svm: 0" \
	    "login: root" \
	    > "$_td/boot_nested0.log"
	if ! classify_boot_log "$_td/boot_nested0.log" > "$_td/boot_nested0.out"; then
		log "SELFTEST FAIL: boot_nested0 should be PASS"
		_fail=1
	else
		log "SELFTEST PASS: boot with nested.*=0 -> PASS"
	fi

	# GREEN: real GENERIC dmesg (no getty FreeBSD/amd64 line).
	printf '%s\n' \
	    "---<<BOOT>>---" \
	    "Copyright (c) 1992-2026 The FreeBSD Project." \
	    "FreeBSD 16.0-CURRENT #0: Thu Aug 20 01:33:43 UTC 2026" \
	    "    root@freedev005:/usr/obj/.../sys/GENERIC amd64" \
	    "FreeBSD/SMP: Multiprocessor System Detected: 1 CPUs" \
	    "Timecounter \"TSC-low\" frequency 1305603517 Hz quality 1000" \
	    "Trying to mount root from ufs:/dev/vtbd0 []..." \
	    "mountroot>" \
	    > "$_td/boot_real_dmesg.log"
	if ! classify_boot_log "$_td/boot_real_dmesg.log" > "$_td/boot_real_dmesg.out"; then
		log "SELFTEST FAIL: boot_real_dmesg should be PASS"
		_fail=1
	else
		log "SELFTEST PASS: real GENERIC dmesg (no getty) -> PASS"
	fi

	# RED: empty / timeout-like log.
	: > "$_td/empty.log"
	if classify_boot_log "$_td/empty.log" > "$_td/empty.out"; then
		log "SELFTEST FAIL: empty should be FAIL"
		_fail=1
	else
		log "SELFTEST PASS: empty -> FAIL"
	fi

	rm -rf "$_td"
	if [ "$_fail" -ne 0 ]; then
		die "classifier selftest failed"
	fi
	log "SELFTEST: all classifier fixtures passed"
	return 0
}

need_freebsd_hypervisor()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 0
	fi
	if [ "$(uname -s 2>/dev/null || true)" != "FreeBSD" ]; then
		log "SKIP: not FreeBSD (classifier selftest still runs via: $PROGRAM selftest)"
		return 1
	fi
	if ! command -v bhyve >/dev/null 2>&1 || ! command -v bhyveload >/dev/null 2>&1; then
		log "SKIP: bhyve/bhyveload not in PATH"
		return 1
	fi
	return 0
}

elevate_root()
{
	if [ "$(id -u)" -eq 0 ]; then
		return 0
	fi
	if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
		exec sudo -n -- "$0" "$@"
	fi
	if command -v doas >/dev/null 2>&1 && doas -n true 2>/dev/null; then
		exec doas -n -- "$0" "$@"
	fi
	die "need root (sudo -n or doas -n) to create the throwaway disk and run bhyve"
}

sha_file()
{
	if command -v sha256 >/dev/null 2>&1; then
		sha256 -q "$1"
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		printf 'unknown\n'
	fi
}

ensure_host_vmm()
{
	if kldstat -q -n vmm 2>/dev/null; then
		return 0
	fi
	log "host vmm.ko not loaded; kldload host module (not the candidate)"
	if [ -f /boot/kernel/vmm.ko ]; then
		kldload /boot/kernel/vmm.ko || die "kldload host /boot/kernel/vmm.ko failed"
	else
		kldload vmm || die "kldload vmm failed"
	fi
}

populate_boot_image()
{
	_img=$1
	_root=$2

	mkdir -p "$_root/boot/kernel" "$_root/dev" "$_root/tmp" "$_root/mnt"
	# Loader + lua from the hypervisor so userboot can find the kernel.
	# Do not copy host *.ko — KBI may not match the candidate.
	if [ -d "${BOOT_SRC}/lua" ]; then
		cp -a "${BOOT_SRC}/lua" "$_root/boot/"
	fi
	if [ -d "${BOOT_SRC}/defaults" ]; then
		cp -a "${BOOT_SRC}/defaults" "$_root/boot/"
	fi
	for f in loader loader.conf loader.conf.local loader.rc device.hints \
	    userboot.so userboot_4th.so boot boot1 boot2 gptboot gptzfsboot; do
		if [ -e "${BOOT_SRC}/$f" ]; then
			cp -a "${BOOT_SRC}/$f" "$_root/boot/"
		fi
	done

	cp "$KERNEL" "$_root/boot/kernel/kernel"
	chmod 555 "$_root/boot/kernel/kernel"
	if [ -n "$VMM_KO" ] && [ -f "$VMM_KO" ]; then
		cp "$VMM_KO" "$_root/boot/kernel/vmm.ko"
		chmod 555 "$_root/boot/kernel/vmm.ko"
	fi

	{
		echo 'autoboot_delay="-1"'
		echo 'beastie_disable="YES"'
		echo 'console="comconsole"'
		echo 'boot_multicons="YES"'
		echo 'boot_serial="YES"'
		echo 'comconsole_speed="115200"'
		echo 'kern.vty="vt"'
	} > "$_root/boot/loader.conf"

	if command -v makefs >/dev/null 2>&1; then
		makefs -t ffs -o label=nvboot -s 1g "$_img" "$_root" || die "makefs failed"
		return 0
	fi

	# Fallback when makefs is missing: mdconfig + newfs.
	truncate -s 1G "$_img"
	_md=$(mdconfig -a -t vnode -f "$_img") || die "mdconfig failed"
	mdunit=${_md#md}
	if ! newfs -U -L nvboot "/dev/${_md}" >/dev/null; then
		mdconfig -d -u "$mdunit" || true
		die "newfs failed"
	fi
	_mnt=$(dirname "$_root")/mnt
	mkdir -p "$_mnt"
	if ! mount "/dev/${_md}" "$_mnt"; then
		mdconfig -d -u "$mdunit" || true
		die "mount throwaway UFS failed"
	fi
	cp -a "$_root"/. "$_mnt"/
	sync
	umount "$_mnt" || die "umount throwaway UFS failed"
	mdconfig -d -u "$mdunit" || die "mdconfig -d failed"
}

wait_for_boot()
{
	_log=$1
	_pid=$2
	_i=0
	while [ "$_i" -lt "$TIMEOUT" ]; do
		if [ -f "$_log" ]; then
			if classify_boot_log "$_log" >/dev/null 2>&1; then
				return 0
			fi
			# Hard fail early if we already panicked with no ident.
			_ident=$(first_line "$_log" "$IDENT_RE")
			_panic=$(first_line "$_log" "$PANIC_RE")
			if [ "$_panic" -gt 0 ] && [ "$_ident" -eq 0 ]; then
				return 1
			fi
		fi
		if ! kill -0 "$_pid" 2>/dev/null; then
			wait "$_pid" || true
			if classify_boot_log "$_log" >/dev/null 2>&1; then
				return 0
			fi
			return 1
		fi
		sleep 1
		_i=$((_i + 1))
	done
	return 1
}

cleanup_vm()
{
	_name=$1
	_pid=${2:-}
	if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
		kill "$_pid" 2>/dev/null || true
		sleep 1
		kill -9 "$_pid" 2>/dev/null || true
		wait "$_pid" 2>/dev/null || true
	fi
	if command -v bhyvectl >/dev/null 2>&1; then
		bhyvectl --vm="$_name" --destroy >/dev/null 2>&1 || true
	fi
}

run_gate()
{
	if [ -z "$KERNEL" ]; then
		if [ -f /boot/kernel/kernel ]; then
			KERNEL=/boot/kernel/kernel
		else
			die "set NESTED_GATE_KERNEL to the candidate kernel"
		fi
	fi
	[ -f "$KERNEL" ] || die "candidate kernel not a file: $KERNEL"

	WORKDIR="${NESTED_GATE_WORKDIR:-/tmp/nv-boot-gate.$$}"
	VM_NAME="${NESTED_GATE_VM:-nvboot$$}"
	IMAGE="${WORKDIR}/boot.img"
	ROOT="${WORKDIR}/root"
	LOG="${WORKDIR}/serial.log"
	LOADER_LOG="${WORKDIR}/bhyveload.log"
	mkdir -p "$WORKDIR" "$ROOT"

	log "=== VM boot gate ==="
	log "  kernel    = $KERNEL"
	log "  sha256    = $(sha_file "$KERNEL")"
	log "  vmm.ko    = ${VMM_KO:-none (not loaded on host)}"
	log "  vm        = $VM_NAME"
	log "  mem_mb    = $MEM_MB"
	log "  timeout_s = $TIMEOUT"
	log "  workdir   = $WORKDIR"
	log "  log       = $LOG"
	log "  rule      = PASS on kernel boot; nested features not required"

	ensure_host_vmm
	populate_boot_image "$IMAGE" "$ROOT"

	cleanup_vm "$VM_NAME" ""

	# userboot on the hypervisor loads KERNEL from the throwaway disk.
	if ! bhyveload \
	    -c stdio \
	    -m "$MEM_MB" \
	    -d "$IMAGE" \
	    -e autoboot_delay=-1 \
	    -e console=comconsole \
	    "$VM_NAME" > "$LOADER_LOG" 2>&1; then
		log "---- bhyveload ----"
		cat "$LOADER_LOG" || true
		cleanup_vm "$VM_NAME" ""
		die "bhyveload failed (see $LOADER_LOG)"
	fi
	cat "$LOADER_LOG" > "$LOG"

	bhyve \
	    -c 1 \
	    -m "${MEM_MB}M" \
	    -A -H -P \
	    -s 0,hostbridge \
	    -s 1,lpc \
	    -s 2,virtio-blk,"$IMAGE" \
	    -l com1,stdio \
	    "$VM_NAME" >> "$LOG" 2>&1 &
	bpid=$!

	set +e
	wait_for_boot "$LOG" "$bpid"
	wrc=$?
	set -e

	cleanup_vm "$VM_NAME" "$bpid"

	log "---- serial (tail) ----"
	tail -n 80 "$LOG" || true
	log "---- classify ----"
	set +e
	classify_boot_log "$LOG"
	crc=$?
	set -e

	if [ "$crc" -eq 0 ]; then
		log "VM BOOT GATE: PASS"
		# Keep the serial log; drop the 1G image.
		rm -f "$IMAGE"
		rm -rf "$ROOT"
		exit 0
	fi
	if [ "$wrc" -ne 0 ] && [ "$crc" -ne 0 ]; then
		die "kernel did not boot within ${TIMEOUT}s (serial $LOG)"
	fi
	die "kernel did not boot (serial $LOG)"
}

cmd=${1:-run}
case "$cmd" in
classify)
	shift
	[ "${1:-}" ] || die "usage: $PROGRAM classify <serial.log>"
	classify_boot_log "$1"
	;;
selftest)
	selftest_classifier
	;;
run|"")
	if ! need_freebsd_hypervisor; then
		exit 0
	fi
	elevate_root "$@"
	run_gate
	;;
*)
	die "usage: $PROGRAM [run|classify <log>|selftest]"
	;;
esac
