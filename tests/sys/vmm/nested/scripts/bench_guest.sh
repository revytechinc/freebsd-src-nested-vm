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

# Fixed-string wait. The marker is data, not a pattern: it is matched against a
# line the guest produced, and a MARKER_VALUE or marker containing a regex
# metacharacter would otherwise change what is matched without saying so. The
# whole timing correctness of this script rests on this comparison.
wait_for_lit() {
	_lit=$1; _t=$2; _after=${3:-0}; _n=0
	while [ "${_n}" -lt "${_t}" ]; do
		tail -n +"$((_after + 1))" "${CONS}" | tr -d '\015' |
		    grep -Faq "${_lit}" && return 0
		sleep 1; _n=$((_n + 1))
	done
	return 1
}

wait_for() {
	_re=$1; _t=$2; _after=${3:-0}; _n=0
	while [ "${_n}" -lt "${_t}" ]; do
		tail -n +"$((_after + 1))" "${CONS}" | tr -d '\015' |
		    grep -Eaq "${_re}" && return 0
		sleep 1; _n=$((_n + 1))
	done
	return 1
}

#
# The marker cannot be spelled out in the command, because the guest's tty
# echoes the command line straight back into the console log -- a plain marker
# matches its own echo and reports success before the command has run at all.
# Every timing this script takes was measured against that echo, so the
# workloads were typed into a console that had not reached a shell and the
# numbers were of nothing. So the guest expands it: what we type carries ${M},
# and only the guest's output carries the value. MARKER_VALUE is set in the
# guest once it has a shell.
MARKER_VALUE=Zq
guest() { # <marker> <timeout> <command...>
	_marker=$1; _t=$2; shift 2
	_at=$(lines)
	# Re-assert M on every command. It is set once after login, but any
	# path that re-enters the shell would drop it, and the guest would then
	# emit an unprefixed marker while we waited for the prefixed one -- a
	# timeout that reads like a hypervisor hang rather than harness state.
	send "M=${MARKER_VALUE}; $* ; echo \"===\${M}${_marker}===\""
	wait_for_lit "===${MARKER_VALUE}${_marker}===" "${_t}" "${_at}" ||
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
# bhyve holds the A side open now, so opening B will not block. Open it for
# writing before stty runs: the reader and this descriptor keep the tty open,
# and a last close would reset termios and flush what the guest has printed.
exec 3> "${B}" || fail "cannot open ${B} for writing"
stty -f "${B}" raw -echo clocal || fail "cannot set ${B} raw -echo clocal"

wait_for 'login:' "${BOOT_TIMEOUT}" || fail "guest never reached a login prompt"
result boot_to_login_s "$(( $(date +%s) - start ))"

send 'root'
wait_for 'assword' 30 || fail "no password prompt"
send 'root'
# Wait for the prompt before typing anything else. login(1) runs resizewin,
# which reads from the terminal for several seconds and swallows whatever
# arrives meanwhile -- the marker assignment sent blind is eaten there, and
# every later command then waits for a marker the guest cannot produce.
# Anchor on the whole prompt, not a bare "# ": the login banner and boot
# messages contain that sequence, and matching one of those sends the
# assignment blind again -- intermittently, which is worse.
wait_for 'root@[^ ]*:~ #' 120 || fail "guest never produced a shell prompt"
send "M=${MARKER_VALUE}"
guest READY 60 'true' || fail "no shell"

# Guest-internal timings. Each one is printed by the guest itself, so the
# numbers are not distorted by console latency; we only parse them out.
guest CPUBENCH 300 \
    '_o=$( { /usr/bin/time -p sh -c "i=0; while [ \$i -lt 400000 ]; do i=\$((i+1)); done"; } 2>&1 ); _s=$?; [ $_s -eq 0 ] && echo BENCH_cpu_loop_s=$(printf "%s\n" "$_o" | sed -n "s/^real *//p") || echo BENCH_cpu_loop_s_EXIT=$_s' ||
    log "cpu loop did not finish"
guest SYSCALL 300 \
    '_o=$( { /usr/bin/time -p sh -c "i=0; while [ \$i -lt 4000 ]; do /usr/bin/true; i=\$((i+1)); done"; } 2>&1 ); _s=$?; [ $_s -eq 0 ] && echo BENCH_exec_4000_s=$(printf "%s\n" "$_o" | sed -n "s/^real *//p") || echo BENCH_exec_4000_s_EXIT=$_s' ||
    log "exec loop did not finish"
guest DISKW 600 \
    '_o=$( { /usr/bin/time -p sh -c "dd if=/dev/zero of=/root/blob bs=1m count=1024 status=none; sync"; } 2>&1 ); _s=$?; [ $_s -eq 0 ] && echo BENCH_write_1g_s=$(printf "%s\n" "$_o" | sed -n "s/^real *//p") || echo BENCH_write_1g_s_EXIT=$_s' ||
    log "write did not finish"
guest DISKR 600 \
    '_o=$( { /usr/bin/time -p sh -c "dd if=/root/blob of=/dev/null bs=1m status=none"; } 2>&1 ); _s=$?; [ $_s -eq 0 ] && echo BENCH_read_1g_s=$(printf "%s\n" "$_o" | sed -n "s/^real *//p") || echo BENCH_read_1g_s_EXIT=$_s' ||
    log "read did not finish"

# Host-side view of what the guest cost.
stats=$(bhyvectl --vm="${VMNAME}" --get-stats 2>/dev/null)
for k in "total number of vm exits" "vm exits due to nested page fault" \
    "number of times hlt was intercepted" "vm exits due to external interrupt"; do
	v=$(printf '%s\n' "${stats}" | grep -i "${k}" | tail -1 |
	    tr -s ' \t' ' ' | sed 's/.* \([0-9][0-9]*\).*/\1/')
	if [ -n "${v}" ]; then
		result "$(printf '%s' "${k}" | tr ' ' '_')" "${v}"
	else
		log "MISSING STAT: ${k} -- bhyvectl on this host may name it differently"
	fi
done

#
# One line per key, last value wins. sort -u collapsed duplicates only while
# values were whole seconds; with fractional ones two runs of the same workload
# differ and both would survive, reporting the same key twice.
tr -d '\015' < "${CONS}" | grep -o 'BENCH_[a-z0-9_]*=[0-9][0-9.]*' |
    awk -F= '{ v[$1] = $2 } END { for (k in v) print k "=" v[k] }' | sort |
    while IFS='=' read -r k v; do result "${k#BENCH_}" "${v}"; done

#
# A workload that dies still lets its marker through, so guest() cannot tell.
# Say plainly which numbers are missing rather than leaving a silent gap that
# looks the same as a run nobody asked for that measurement from.
for k in cpu_loop_s exec_4000_s write_1g_s read_1g_s; do
	tr -d '\015' < "${CONS}" |
	    grep -q "BENCH_${k}=[0-9]" || log "MISSING RESULT: ${k}"
done

guest HALT 60 'shutdown -p now' || true
log "done"
