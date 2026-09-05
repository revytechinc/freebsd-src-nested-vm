#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# run_layer_stack.sh — boot a stack of stock FreeBSD guests, one per nesting
# layer, and make each one do real ZFS work while the layer below it is
# running.
#
# The images come from build_layer_images.sh: stock FreeBSD, one distinct pool
# name per layer, bhyve-firmware inside so a layer can host the next, and the
# root/root console login imagine.sh's -u adds. Nothing in the guests is
# modified to make nesting work.
#
# Why ZFS inside and not just "did it boot": a nested guest's I/O crosses every
# hypervisor layer beneath it. ZFS checksums every block it reads, so a scrub
# inside L2 turns silent corruption anywhere in that path into an attributable
# failure. A boot test would not notice it at all.
#
# Requires root. Run detached (nohup) -- an ssh that times out takes the whole
# process group, bhyve included.

# shellcheck shell=sh
set -u

# A guest console emits bytes that are not valid in a UTF-8 locale, and tr(1)
# then fails with "Illegal byte sequence" instead of stripping carriage
# returns -- which silently breaks every wait for guest output.
LC_ALL=C
export LC_ALL

PROGRAM="${0##*/}"

IMAGEDIR=${IMAGEDIR:-/home/mlapointe/nested-layers}
WORKDIR=${WORKDIR:-/home/mlapointe/layer-stack}
VMNAME=${VMNAME:-lstack}
MEM=${MEM:-8G}
CPUS=${CPUS:-2}
BOOTROM=${BOOTROM:-/usr/local/share/uefi-firmware/BHYVE_UEFI.fd}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-420}

A=/dev/nmdm${VMNAME}A
B=/dev/nmdm${VMNAME}B
CONS=${WORKDIR}/console.log

log() { printf '%s: %s\n' "${PROGRAM}" "$*"; }
fail() { log "FAIL: $*"; exit 1; }

[ "$(id -u)" = 0 ] || fail "must be root"
[ -f "${BOOTROM}" ] || fail "${BOOTROM} missing -- pkg install bhyve-firmware"

kldload -n vmm nmdm
[ "$(sysctl -n hw.vmm.nested.enable)" = 1 ] || fail "hw.vmm.nested.enable != 1"

mkdir -p "${WORKDIR}"
L1=${WORKDIR}/l1.raw
L2=${WORKDIR}/l2.raw

bhyvectl --vm="${VMNAME}" --destroy >/dev/null 2>&1
rm -f "${L1}" "${L2}"
log "cloning layer images (the golden images stay untouched)"
cp "${IMAGEDIR}/nested1.raw" "${L1}" || fail "cannot copy nested1.raw"
cp "${IMAGEDIR}/nested2.raw" "${L2}" || fail "cannot copy nested2.raw"

: > "${CONS}"

cleanup() {
	exec 3>&- 2>/dev/null
	[ -n "${BHYVE_PID:-}" ] && kill "${BHYVE_PID}" 2>/dev/null
	[ -n "${READER:-}" ] && kill "${READER}" 2>/dev/null
	bhyvectl --vm="${VMNAME}" --destroy >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

send() { printf '%s\r' "$*" >&3; }

# Wait for a pattern to appear after line ${2:-0} of the console log.
wait_for() {
	_re=$1; _t=$2; _after=${3:-0}; _n=0
	while [ "${_n}" -lt "${_t}" ]; do
		tail -n +"$((_after + 1))" "${CONS}" | tr -d '\015' |
		    grep -Eaq "${_re}" && return 0
		kill -0 "${BHYVE_PID:-$$}" 2>/dev/null || {
			wait "${BHYVE_PID}" 2>/dev/null
			log "L1's bhyve exited (status $?) while waiting for ${_re}"
			log "  bhyve said: $(tail -3 "${WORKDIR}/bhyve.log" |
			    tr '\n' ' ')"
			return 1
		}
		sleep 1; _n=$((_n + 1))
	done
	return 1
}

lines() { wc -l < "${CONS}" | tr -d ' '; }

# Wait for a login prompt, but give up at once on the firmware's own "there is
# nothing to boot here" message rather than sitting out the whole boot timeout.
wait_for_l2_login() { # <after-line>
	_at=$1; _n=0
	while [ "${_n}" -lt "${BOOT_TIMEOUT}" ]; do
		_tail=$(tail -n +"$((_at + 1))" "${CONS}" | tr -d '\015')
		printf '%s' "${_tail}" | grep -Eaq 'login:' && return 0
		printf '%s' "${_tail}" |
		    grep -Eaq 'No bootable option or device was found' && {
			log "  firmware found nothing to boot on that device"
			return 1
		}
		sleep 1; _n=$((_n + 1))
	done
	return 1
}

# Run a command in the guest and wait for its marker, so we never guess whether
# a long-running command has finished.
guest() { # <marker> <timeout> <command...>
	_marker=$1; _t=$2; shift 2
	_at=$(lines)
	send "$* ; echo ===${_marker}==="
	wait_for "===${_marker}===" "${_t}" "${_at}" ||
	    { log "guest command timed out: $*"; return 1; }
	return 0
}

# The reader must start before bhyve: an nmdm side blocks in ttydcd until its
# peer opens, so it parks there and captures from the first byte -- and it is
# still holding the tty when stty runs, which matters because the last close
# resets termios and flushes everything the guest has printed.
( cat "${B}" >> "${CONS}" ) &
READER=$!

log "starting L1 (${CPUS} vCPUs, ${MEM}); L2's disk is attached to it"
bhyve -c "${CPUS}" -m "${MEM}" -A -H -P \
    -l bootrom,"${BOOTROM}" \
    -s 0,hostbridge \
    -s 2,nvme,"${L1}" \
    -s 3,nvme,"${L2}" \
    -s 31,lpc \
    -l com1,"${A}" "${VMNAME}" > "${WORKDIR}/bhyve.log" 2>&1 &
BHYVE_PID=$!

sleep 2
kill -0 "${BHYVE_PID}" 2>/dev/null ||
    fail "bhyve exited immediately: $(cat "${WORKDIR}/bhyve.log")"
# bhyve holds the A side open now, so opening B will not block. Open it for
# writing before stty runs: the reader and this descriptor keep the tty open,
# and a last close would reset termios and flush what the guest has printed.
exec 3> "${B}" || fail "cannot open ${B} for writing"
stty -f "${B}" raw -echo clocal || fail "cannot set ${B} raw -echo clocal"

wait_for 'login:' "${BOOT_TIMEOUT}" || fail "L1 never reached a login prompt"
log "L1 reached the login prompt"
send 'root'
wait_for 'assword' 30 || fail "no password prompt on L1"
send 'root'
guest L1SHELL 60 'true' || fail "no shell on L1"
log "L1 root shell"

guest L1UNAME 30 'uname -a' || fail "L1 unresponsive"

# --- ZFS inside L1 ----------------------------------------------------
log "L1: ZFS workload on its own pool"
guest L1ZPOOL 60 'zpool status nested1 | head -20' ||
    fail "L1 cannot see its pool"
guest L1MKDS 60 'zfs create nested1/stress' || fail "L1 zfs create"
guest L1WRITE 300 \
    'dd if=/dev/random of=/nested1/stress/blob bs=1m count=512 status=none && sync' ||
    fail "L1 write"
guest L1SNAP 60 'zfs snapshot nested1/stress@one' || fail "L1 snapshot"
guest L1SCRUB 600 \
    'zpool scrub -w nested1; zpool status nested1 | grep -E "errors:|scan:"' ||
    fail "L1 scrub"

# --- L2, launched by L1's own stock bhyve -----------------------------
log "L1: loading vmm and launching L2 from the second disk"
guest L1VMM 90 'kldload -n vmm; sysctl -n hw.vmm.nested.enable' ||
    fail "L1 could not load vmm"
guest L1DISKS 30 'ls /dev/nda* /dev/nvd* 2>/dev/null' || true
guest L1GEOM 30 'gpart show nda1; diskinfo -v /dev/nda1 | head -6' || true
guest L1FW 30 'ls /usr/local/share/uefi-firmware/BHYVE_UEFI.fd' ||
    fail "L1 has no bhyve-firmware -- rebuild the image with -p bhyve-firmware"

# Two ways to start L2, tried in order, because they exercise different paths
# and we want to know which one a failure belongs to:
#   1. UEFI bootrom + emulated NVMe -- what a user reaches for, and what the
#      generated boot scripts use;
#   2. UEFI bootrom + virtio-blk -- same firmware, different device model;
#   3. bhyveload + virtio-blk -- the loader reads the kernel out of the disk
#      from L1 userspace before L2 ever runs, so it exercises far less of the
#      device path.
# Which one first succeeds names the culprit: 2 working means the NVMe model
# is at fault, 3 working means the firmware's own device I/O is, and none
# working means nesting itself. Reporting a bare "L2 failed" says none of that.
L2_METHOD=none
_at=$(lines)
send 'bhyve -c 1 -m 2G -A -H -P -l bootrom,/usr/local/share/uefi-firmware/BHYVE_UEFI.fd -s 0,hostbridge -s 2,nvme,/dev/nda1 -s 31,lpc -l com1,stdio l2 ; echo ===L2EXIT==='
if wait_for_l2_login "${_at}"; then
	L2_METHOD=uefi-nvme
else
	log "L2 did not boot via UEFI+NVMe; retrying with UEFI+virtio-blk"
	guest L2CLEAN 60 'bhyvectl --destroy --vm=l2 >/dev/null 2>&1; true' || true
	_at=$(lines)
	send 'bhyve -c 1 -m 2G -A -H -P -l bootrom,/usr/local/share/uefi-firmware/BHYVE_UEFI.fd -s 0,hostbridge -s 3,virtio-blk,/dev/nda1 -s 31,lpc -l com1,stdio l2 ; echo ===L2EXIT==='
	if wait_for_l2_login "${_at}"; then
		L2_METHOD=uefi-virtio
	else
		log "L2 did not boot via UEFI either; retrying with bhyveload+virtio-blk"
		guest L2CLEAN2 60 'bhyvectl --destroy --vm=l2 >/dev/null 2>&1; true' || true
		_at=$(lines)
		send 'bhyveload -c stdio -m 2G -d /dev/nda1 -e console=comconsole -e autoboot_delay=1 l2 && bhyve -c 1 -m 2G -A -H -P -s 0,hostbridge -s 3,virtio-blk,/dev/nda1 -s 31,lpc -l com1,stdio l2 ; echo ===L2EXIT==='
		wait_for 'login:' "${BOOT_TIMEOUT}" "${_at}" ||
		    fail "L2 never reached a login prompt by any method"
		L2_METHOD=bhyveload-virtio
	fi
fi
log "L2 reached the login prompt via ${L2_METHOD} -- nested guest is up"
send 'root'
wait_for 'assword' 30 "${_at}" || fail "no password prompt on L2"
send 'root'
guest L2SHELL 60 'true' || fail "no shell on L2"
log "L2 root shell"

guest L2UNAME 30 'uname -a' || fail "L2 unresponsive"

# --- ZFS inside L2, three hypervisor layers away from the disk --------
log "L2: ZFS workload"
guest L2ZPOOL 60 'zpool status nested2 | head -20' || fail "L2 cannot see its pool"
guest L2MKDS 60 'zfs create nested2/stress' || fail "L2 zfs create"
guest L2WRITE 300 \
    'dd if=/dev/random of=/nested2/stress/blob bs=1m count=256 status=none && sync' ||
    fail "L2 write"
guest L2SNAP 60 'zfs snapshot nested2/stress@one' || fail "L2 snapshot"
guest L2SCRUB 600 \
    'zpool scrub -w nested2; zpool status nested2 | grep -E "errors:|scan:"' ||
    fail "L2 scrub"

log "=== scrub results ==="
tr -d '\015' < "${CONS}" | grep -E "errors:|scan: scrub" | tail -10

# A scrub that repaired anything, or reported any error, is a failure however
# cleanly the guests booted.
if tr -d '\015' < "${CONS}" | grep -E "errors:" | grep -qv "No known data errors"
then
	fail "a scrub reported data errors -- see ${CONS}"
fi

log "PASS: L1 and L2 both booted stock and both scrubbed clean"
