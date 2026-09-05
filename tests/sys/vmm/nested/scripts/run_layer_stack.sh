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
			# wait(1) only reports a real status for a direct,
			# unreaped child; if it fails, $? is the shell's own
			# error and would be reported as bhyve's.
			if wait "${BHYVE_PID}" 2>/dev/null; then
				_st=0
			else
				_st=$?
				# 127 means either "not a live child" or a real
				# exit 127 from a failed exec; say both.
				[ "${_st}" = 127 ] &&
				    _st="127 (already reaped, or exec failed)"
			fi
			log "L1's bhyve exited (status ${_st}) while waiting for ${_re}"
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
#
# The marker cannot be spelled out in the command, because the guest's tty
# echoes the command line straight back into the console log -- a plain marker
# matches its own echo and reports success before the command has run at all.
# So the guest expands it: what we type carries ${M}, and only the guest's
# output carries the value. MARKER_VALUE is set in the guest once it has a
# shell.
MARKER_VALUE=Zq
guest() { # <marker> <timeout> <command...>
	_marker=$1; _t=$2; shift 2
	_at=$(lines)
	send "$* ; echo \"===\${M}${_marker}===\""
	wait_for "===${MARKER_VALUE}${_marker}===" "${_t}" "${_at}" ||
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
# Wait for the prompt before typing anything else. login(1) runs resizewin,
# which reads from the terminal for several seconds and swallows whatever
# arrives meanwhile -- the marker assignment sent blind was eaten there, and
# every later command then waited for a marker the guest could not produce.
# Anchor on the whole prompt, not a bare "# ": the login banner and boot
# messages contain that sequence, and matching one of those would send the
# assignment blind again -- intermittently, which is worse.
wait_for 'root@[^ ]*:~ #' 120 || fail "L1 never produced a shell prompt"
send "M=${MARKER_VALUE}"
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

# L2 gets its own nmdm console inside L1, and L1 starts it in the background.
# Running the inner bhyve in L1's foreground looked simpler, but when the guest
# does not boot the firmware sits at its boot manager forever holding L1's only
# terminal -- there is no way to interrupt it, so the run cannot even clean up.
# With nmdm, L1's shell stays ours throughout and L2 can be destroyed.
guest L1NMDM 60 'kldload -n nmdm; ls /dev/nmdm0B >/dev/null 2>&1 || echo NONMDM' ||
    fail "L1 could not load nmdm"

# A tty in canonical mode drops everything past MAX_CANON (255 bytes) on a
# line, and the long spawn-and-wait one-liners went over it: the tail of the
# command was lost, the shell sat waiting for a closing quote, and the next
# command was swallowed into it. Give L1 short helpers and short variables
# once, so every line sent afterwards stays well inside the limit.
guest L1VARS 30 "FW=${FW:-/usr/local/share/uefi-firmware/BHYVE_UEFI.fd}; D=/dev/nda1; C=/dev/nmdm0A" ||
    fail "L1 would not take the setup line"
guest L1FN1 30 'sp() { n=0; while [ $n -lt 20 ]; do pgrep -qf "bhyve.* l2$" && return 0; sleep 1; n=$((n+1)); done; return 1; }' ||
    fail "L1 would not take the spawn helper"
guest L1FN2 30 'w1() { grep -aq "login:" /tmp/l2.log && { echo login; return; }; grep -aq "No bootable" /tmp/l2.log && { echo nobootdev; return; }; pgrep -qf "bhyve.* l2$" || echo exited; }' ||
    fail "L1 would not take the poll helper"
guest L1FN3 30 'wl() { n=0; while [ $n -lt '"${BOOT_TIMEOUT}"' ]; do r=$(w1); [ -n "$r" ] && break; sleep 1; n=$((n+1)); done; echo L2RESULT=${r:-timeout}; }' ||
    fail "L1 would not take the watch helper"
guest L1FN4 30 'wm() { n=0; while [ $n -lt $2 ]; do grep -aq "===${M}$1===" /tmp/l2.log && { echo "${M}HIT$1"; return; }; sleep 1; n=$((n+1)); done; echo "${M}MISS$1"; }' ||
    fail "L1 would not take the marker helper"

# Ask L1 to watch L2's console and report the first thing that settles the
# question, rather than polling it over the console one grep at a time.
l2_start() { # <label> <bhyve args...>
	_label=$1; shift
	# The previous attempt's reader must go too: two cats on one nmdm side
	# split the stream between them, so the new log would miss half the
	# console and report a booting guest as a failure.
	guest "L2KILL" 60 'bhyvectl --destroy --vm=l2 >/dev/null 2>&1; pkill -f "bhyve.* l2$"; pkill -f "cat /dev/nmdm0B"; sleep 1; rm -f /tmp/l2.log; true' || true
	guest "L2READER" 30 '(cat /dev/nmdm0B >> /tmp/l2.log &) ; sleep 1; true' ||
	    return 1
	log "L2 attempt: ${_label}"
	_spawn_at=$(lines)
	guest "L2SPAWN" 90 "$* > /tmp/l2.err 2>&1 & sp && echo \"\${M}SPAWNED\" || cat /tmp/l2.err" ||
	    return 1
	tail -n +"$((_spawn_at + 1))" "${CONS}" | tr -d '\015' |
	    grep -aq "${MARKER_VALUE}SPAWNED" || {
		log "  L2's bhyve did not start: $(tail -3 "${CONS}")"
		return 1
	}
	_at=$(lines)
	guest "L2WATCH" $((BOOT_TIMEOUT + 30)) "wl" || return 1
	_res=$(tail -n +"$((_at + 1))" "${CONS}" | tr -d '\015' |
	    grep -ao 'L2RESULT=[a-z]*' | tail -1 | cut -d= -f2)
	log "  result: ${_res:-none}"
	[ "${_res}" = login ]
}

# Three attempts, varying firmware and device model one at a time, so a failure
# names the culprit: UEFI+virtio working means the NVMe model is at fault,
# bhyveload+virtio working means the firmware's own device I/O is, and none
# working means nesting itself.
FW=/usr/local/share/uefi-firmware/BHYVE_UEFI.fd
L2_METHOD=none
if l2_start uefi-nvme \
    'bhyve -c 1 -m 2G -A -H -P -l bootrom,$FW -s 0,hostbridge -s 2,nvme,$D -s 31,lpc -l com1,$C l2'; then
	L2_METHOD=uefi-nvme
elif l2_start uefi-virtio \
    'bhyve -c 1 -m 2G -A -H -P -l bootrom,$FW -s 0,hostbridge -s 3,virtio-blk,$D -s 31,lpc -l com1,$C l2'; then
	L2_METHOD=uefi-virtio
elif l2_start bhyveload-virtio \
    'bhyveload -c $C -m 2G -d $D -e console=comconsole -e autoboot_delay=1 l2 && bhyve -c 1 -m 2G -A -H -P -s 0,hostbridge -s 3,virtio-blk,$D -s 31,lpc -l com1,$C l2'; then
	L2_METHOD=bhyveload-virtio
else
	guest L2DIAG 60 'tail -5 /tmp/l2.err; tail -20 /tmp/l2.log' || true
	fail "L2 never reached a login prompt by any method"
fi
log "L2 reached the login prompt via ${L2_METHOD} -- nested guest is up"

# From here every L2 command goes through L1: we write to L2's console and read
# L2's log, both from L1's shell.
l2() { # <marker> <timeout> <command...>
	_m=$1; _t=$2; shift 2
	# Same echo problem one layer down: L2's tty repeats what we send it, so
	# the marker is assembled inside L2 from a variable it was given.
	guest "L2CMD_${_m}" 60 "printf '%s\\r' '$* ; echo \"===\${M}${_m}===\"' > /dev/nmdm0B" ||
	    return 1
	_at=$(lines)
	guest "L2SEEN_${_m}" $((_t + 30)) "wm ${_m} ${_t}" || return 1
	tail -n +"$((_at + 1))" "${CONS}" | tr -d '\015' |
	    grep -aq "${MARKER_VALUE}HIT${_m}"
}

l2_expect() { # <regex> <timeout>
	_re=$1; _t=$2
	_eat=$(lines)
	guest "L2EXP" $((_t + 30)) \
	    "n=0; while [ \$n -lt ${_t} ]; do grep -aEq '${_re}' /tmp/l2.log && break; sleep 1; n=\$((n+1)); done; grep -aEq '${_re}' /tmp/l2.log && echo \"\${M}EXPOK\" || echo \"\${M}EXPMISS\"" ||
	    return 1
	tail -n +"$((_eat + 1))" "${CONS}" | tr -d '\015' |
	    grep -aq "${MARKER_VALUE}EXPOK"
}

l2_expect 'login:' 120 || fail "L2 never offered a login prompt"
guest L2USER 60 "printf 'root\\r' > /dev/nmdm0B" || true
l2_expect 'assword' 60 || fail "L2 never asked for a password"
guest L2PASS 60 "printf 'root\\r' > /dev/nmdm0B" || true
l2_expect 'root@[^ ]*:~ #' 90 || fail "L2 never produced a shell prompt"
guest L2MARK 60 "printf 'M=${MARKER_VALUE}\\r' > /dev/nmdm0B" || true
l2 L2SHELL 60 'true' || fail "no shell on L2"
log "L2 root shell"
l2 L2UNAME 30 'uname -a' || fail "L2 unresponsive"

# --- ZFS inside L2, two hypervisor layers away from the disk ----------
log "L2: ZFS workload"
l2 L2ZPOOL 60 'zpool status nested2' || fail "L2 cannot see its pool"
l2 L2MKDS 60 'zfs create nested2/stress' || fail "L2 zfs create"
l2 L2WRITE 300 'dd if=/dev/random of=/nested2/stress/blob bs=1m count=256 status=none && sync' ||
    fail "L2 write"
l2 L2SNAP 60 'zfs snapshot nested2/stress@one' || fail "L2 snapshot"
l2 L2SCRUB 600 'zpool scrub -w nested2; zpool status nested2' || fail "L2 scrub"
guest L2COLLECT 60 'grep -aE "errors:|scan: scrub" /tmp/l2.log | tail -5' || true

log "=== scrub results ==="
tr -d '\015' < "${CONS}" | grep -E "errors:|scan: scrub" | tail -10

# A scrub that repaired anything, or reported any error, is a failure however
# cleanly the guests booted.
if tr -d '\015' < "${CONS}" | grep -E "errors:" | grep -qv "No known data errors"
then
	fail "a scrub reported data errors -- see ${CONS}"
fi

log "PASS: L1 and L2 both booted stock and both scrubbed clean"
