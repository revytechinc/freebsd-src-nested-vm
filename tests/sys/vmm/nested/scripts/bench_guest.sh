#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# bench_guest.sh — measure what running a guest costs on this host.
#
# The point is an A/B: run this against a stock FreeBSD boot environment, then
# against ours, on the same machine with the same image, and compare. Nesting
# changes code on the hot path of every VM exit, so "it still works" is not
# enough -- we have to be able to say what it costs.
#
# Everything measured here is host-visible or guest-internal timing; nothing
# depends on our sysctls, so the identical script runs on a stock kernel.
#
# Requires root. Writes a machine-readable summary to stdout.

# shellcheck shell=sh
set -u

# A guest console emits bytes that are not valid in a UTF-8 locale, and tr(1)
# then fails with "Illegal byte sequence" instead of stripping carriage
# returns -- which silently breaks every wait for guest output.
LC_ALL=C
export LC_ALL

PROGRAM="${0##*/}"

IMAGE=${IMAGE:-/home/mlapointe/nested-layers/nested1.raw}
WORKDIR=${WORKDIR:-/home/mlapointe/bench}
VMNAME=${VMNAME:-bench}
MEM=${MEM:-4G}
CPUS=${CPUS:-2}
BOOTROM=${BOOTROM:-/usr/local/share/uefi-firmware/BHYVE_UEFI.fd}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-420}
LABEL=${LABEL:-$(uname -v | sed 's/.*#/#/;s/ .*//')}

A=/dev/nmdm${VMNAME}A
B=/dev/nmdm${VMNAME}B
CONS=${WORKDIR}/console.log
DISK=${WORKDIR}/bench.raw

log() { printf '%s: %s\n' "${PROGRAM}" "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }
result() { printf '%s\t%s\t%s\n' "${LABEL}" "$1" "$2"; }

[ "$(id -u)" = 0 ] || fail "must be root"
[ -f "${BOOTROM}" ] || fail "${BOOTROM} missing -- pkg install bhyve-firmware"
[ -f "${IMAGE}" ] || fail "${IMAGE} missing -- run build_layer_images.sh"

kldload -n vmm nmdm
mkdir -p "${WORKDIR}"

bhyvectl --vm="${VMNAME}" --destroy >/dev/null 2>&1
rm -f "${DISK}"
cp "${IMAGE}" "${DISK}" || fail "cannot copy the image"
: > "${CONS}"

cleanup() {
	exec 3>&- 2>/dev/null
	[ -n "${BHYVE_PID:-}" ] && kill "${BHYVE_PID}" 2>/dev/null
	[ -n "${READER:-}" ] && kill "${READER}" 2>/dev/null
	bhyvectl --vm="${VMNAME}" --destroy >/dev/null 2>&1
	rm -f "${DISK}"
}
trap cleanup EXIT INT TERM

send() { printf '%s\r' "$*" >&3; }
lines() { wc -l < "${CONS}" | tr -d ' '; }

wait_for() {
	_re=$1; _t=$2; _after=${3:-0}; _n=0
	while [ "${_n}" -lt "${_t}" ]; do
		tail -n +"$((_after + 1))" "${CONS}" | tr -d '\015' |
		    grep -Eaq "${_re}" && return 0
		sleep 1; _n=$((_n + 1))
	done
	return 1
}

guest() { # <marker> <timeout> <command...>
	_marker=$1; _t=$2; shift 2
	_at=$(lines)
	send "$* ; echo ===${_marker}==="
	wait_for "===${_marker}===" "${_t}" "${_at}" ||
	    { log "guest command timed out: $*"; return 1; }
	return 0
}

# Reader first -- see the console rules in the nested-regression-matrix skill.
( cat "${B}" >> "${CONS}" ) &
READER=$!

start=$(date +%s)
bhyve -c "${CPUS}" -m "${MEM}" -A -H -P \
    -l bootrom,"${BOOTROM}" \
    -s 0,hostbridge -s 2,nvme,"${DISK}" -s 31,lpc \
    -l com1,"${A}" "${VMNAME}" > "${WORKDIR}/bhyve.log" 2>&1 &
BHYVE_PID=$!

sleep 2
kill -0 "${BHYVE_PID}" 2>/dev/null ||
    fail "bhyve exited immediately: $(cat "${WORKDIR}/bhyve.log")"
stty -f "${B}" raw -echo clocal || fail "cannot set ${B} raw -echo clocal"

wait_for 'login:' "${BOOT_TIMEOUT}" || fail "guest never reached a login prompt"
result boot_to_login_s "$(( $(date +%s) - start ))"

send 'root'
wait_for 'assword' 30 || fail "no password prompt"
send 'root'
guest READY 60 'true' || fail "no shell"

# Guest-internal timings. Each one is printed by the guest itself, so the
# numbers are not distorted by console latency; we only parse them out.
guest CPUBENCH 300 \
    'S=$(date +%s); i=0; while [ $i -lt 400000 ]; do i=$((i+1)); done; echo BENCH_cpu_loop_s=$(( $(date +%s) - S ))' ||
    log "cpu loop did not finish"
guest SYSCALL 300 \
    'S=$(date +%s); i=0; while [ $i -lt 4000 ]; do /usr/bin/true; i=$((i+1)); done; echo BENCH_exec_4000_s=$(( $(date +%s) - S ))' ||
    log "exec loop did not finish"
guest DISKW 600 \
    'S=$(date +%s); dd if=/dev/zero of=/root/blob bs=1m count=1024 status=none; sync; echo BENCH_write_1g_s=$(( $(date +%s) - S ))' ||
    log "write did not finish"
guest DISKR 600 \
    'S=$(date +%s); dd if=/root/blob of=/dev/null bs=1m status=none; echo BENCH_read_1g_s=$(( $(date +%s) - S ))' ||
    log "read did not finish"

# Host-side view of what the guest cost.
stats=$(bhyvectl --vm="${VMNAME}" --get-stats 2>/dev/null)
for k in "Number of VM exits" "vm exits due to nested page fault" \
    "number of times hlt was intercepted" "vm exits due to external interrupt"; do
	v=$(printf '%s\n' "${stats}" | grep -i "${k}" | tail -1 |
	    tr -s ' \t' ' ' | sed 's/.* \([0-9][0-9]*\).*/\1/')
	[ -n "${v}" ] && result "$(printf '%s' "${k}" | tr ' ' '_')" "${v}"
done

tr -d '\015' < "${CONS}" | grep -o 'BENCH_[a-z0-9_]*=[0-9]*' | sort -u |
    while IFS='=' read -r k v; do result "${k#BENCH_}" "${v}"; done

guest HALT 60 'shutdown -p now' || true
log "done"
