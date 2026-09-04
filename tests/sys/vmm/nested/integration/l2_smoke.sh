#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# l2_smoke.sh: boot an L1 FreeBSD guest with nested virtualization
# enabled, run bhyve *inside* it, and require that the L2 kernel
# executes. This is the only test in the tree that proves an L2 guest
# actually ran; everything under hw/preflight is static.
#
# Requirements on the L0 host (run as root):
#   - vmm.ko from this tree loaded, hw.vmm.nested.enable=1 accepted
#     (see vmm_nested(9));
#   - a bhyve(8) built from this tree.  No -N flag is used: nesting is on by
#     default and controlled solely by hw.vmm.nested.enable.  Set NFLAG=-N to
#     exercise the backwards-compatible no-op form of the old option.;
#   - a FreeBSD VM image with a UFS root, e.g. the official
#     FreeBSD-*-amd64-ufs.raw snapshot, as L1_IMAGE. The image is copied
#     first; the original is never modified.
#
# The L2 guest is the L1's own kernel, loaded with bhyveload -h /,
# with no disk: it boots to the mountroot> prompt, which is all the
# evidence needed. The unique marker printed by L2 is its copyright
# banner appearing after our L2START marker on the L1 console.
#
# Environment:
#   L1_IMAGE     path to the raw UFS image (required)
#   BHYVE        bhyve binary (default: bhyve in PATH)
#   BHYVELOAD    bhyveload binary (default: bhyveload)
#   NFLAG        empty by default -- the point of the test is that nesting
#                needs no per-VM flag.  Set NFLAG=-N to check that the
#                deprecated option is still accepted as a harmless no-op.
#   L1_MEM       L1 memory (default 4G); L1_CPUS (default 2)
#   L1_TIMEOUT   seconds to wait for the L1 login prompt (default 300)
#   L2_TIMEOUT   seconds to wait for the L2 banner (default 120)
#   WORKDIR      scratch directory (default: mktemp -d)
#   KEEP=1       keep WORKDIR and the console log on exit
#   PROGRESS     file that receives a fsync'd line per step plus the L0
#                dmesg tail while L2 runs (survives a host reset)
#
# Exit status: 0 PASS, 1 FAIL, 77 SKIP (prerequisite missing).

set -u

: "${L1_IMAGE:=}"
: "${BHYVE:=bhyve}"
: "${BHYVELOAD:=bhyveload}"
: "${NFLAG:=}"
: "${L1_MEM:=4G}"
: "${L1_CPUS:=2}"
: "${L1_TIMEOUT:=300}"
: "${L2_TIMEOUT:=120}"
: "${KEEP:=0}"
: "${PROGRESS:=}"

log() { printf 'l2_smoke: %s\n' "$*"; }
progress()
{
	[ -n "${PROGRESS:-}" ] || return 0
	{
		printf '%s %s\n' "$(date +%T)" "$*"
		dmesg | grep svm_nested | tail -300
		[ -n "${BHYVE_PID:-}" ] && for c in $(seq 0 $((L1_CPUS - 1))); do
			printf 'cpu%s ' "$c"; timeout 3 bhyvectl --vm="$VM" --cpu="$c" --get-rip 2>&1 | tr '\n' ' '; echo
		done
		timeout 3 bhyvectl --vm="$VM" --get-stats 2>/dev/null | grep -E 'total number of vm exits|wrmsr|rdmsr|cpuid|nested page fault' | tr -s ' \t' ' '
	} >> "$PROGRESS" 2>&1
	sync
}
skip() { log "SKIP: $*"; exit 77; }
fail() { log "FAIL: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || skip "must run as root"
[ -n "$L1_IMAGE" ] && [ -r "$L1_IMAGE" ] || skip "L1_IMAGE not set or unreadable"
command -v "$BHYVE" >/dev/null 2>&1 || skip "$BHYVE not found"
"$BHYVE" -h 2>&1 | grep -q -- '-N' || skip "$BHYVE does not accept -N (build usr.sbin/bhyve from this tree)"
"$BHYVELOAD" 2>&1 | grep -q -- '-NS' || skip "$BHYVELOAD does not accept -N (build usr.sbin/bhyveload from this tree)"
kldstat -q -n vmm || skip "vmm.ko not loaded"
if [ "$(sysctl -n hw.vmm.nested.enable 2>/dev/null)" != "1" ]; then
	sysctl hw.vmm.nested.enable=1 >/dev/null 2>&1 ||
	    skip "hw.vmm.nested.enable=1 refused (hw.vmm.nested.vmx/svm not 2?)"
fi

WORKDIR=${WORKDIR:-$(mktemp -d /tmp/l2smoke.XXXXXX)}
mkdir -p "$WORKDIR" || fail "cannot create $WORKDIR"
VM="l2smoke$$"
DISK="$WORKDIR/l1.raw"
CONS="$WORKDIR/console.log"
INFIFO="$WORKDIR/console.in"

cleanup()
{
	exec 3>&- 2>/dev/null
	[ -n "${PROGRESS_PID:-}" ] && kill "$PROGRESS_PID" 2>/dev/null
	[ -n "${BHYVE_PID:-}" ] && kill "$BHYVE_PID" 2>/dev/null
	bhyvectl --vm="$VM" --destroy >/dev/null 2>&1
	if [ "$KEEP" = 1 ]; then
		log "kept $WORKDIR (console log: $CONS)"
	else
		rm -rf "$WORKDIR"
	fi
}
trap cleanup EXIT INT TERM

log "copying $L1_IMAGE -> $DISK"
cp "$L1_IMAGE" "$DISK" || fail "copy failed"

# Console: the L1 uart is bhyve's stdio backend. bhyve reads its input
# from a FIFO we keep open for writing (so it never sees EOF) and its
# output is appended to CONS; nothing depends on tty carrier state.
: > "$CONS"
mkfifo "$INFIFO" || fail "mkfifo $INFIFO"

send() { printf '%s\r' "$*" >&3; }

# wait_for <regex> <timeout-seconds> [<must-appear-after-line>]
wait_for()
{
	_re=$1; _t=$2; _after=${3:-0}
	_n=0
	while [ $_n -lt "$_t" ]; do
		if tail -n +"$((_after + 1))" "$CONS" | grep -Eq "$_re"; then
			return 0
		fi
		sleep 1
		_n=$((_n + 1))
	done
	return 1
}

bhyvectl --vm="$VM" --destroy >/dev/null 2>&1
log "loading L1 kernel from $DISK"
# The stock images default to the video console; force the kernel onto
# the serial port we are reading, skip the loader menu delay, and boot
# single-user so a root shell appears without going through getty.
# shellcheck disable=SC2086 -- NFLAG is intentionally word-split (usually empty)
"$BHYVELOAD" $NFLAG -c stdio -m "$L1_MEM" -d "$DISK" \
    -e console=comconsole -e autoboot_delay=1 -e boot_single=YES "$VM" \
    >"$WORKDIR/bhyveload.log" 2>&1 </dev/null ||
    fail "bhyveload failed: $(tail -3 "$WORKDIR/bhyveload.log")"

log "starting L1 ($L1_CPUS vCPU, $L1_MEM, nesting via sysctl, NFLAG='${NFLAG}')"
# shellcheck disable=SC2086
"$BHYVE" $NFLAG -c "$L1_CPUS" -m "$L1_MEM" -A -H -P \
    -s 0,hostbridge -s 3,virtio-blk,"$DISK" -s 31,lpc \
    -l com1,stdio "$VM" <"$INFIFO" >>"$CONS" 2>"$WORKDIR/bhyve.log" &
BHYVE_PID=$!
exec 3>"$INFIFO"

wait_for 'RETURN for /bin/sh' "$L1_TIMEOUT" ||
    fail "L1 did not reach the single-user prompt in ${L1_TIMEOUT}s (see $CONS)"
log "L1 booted (single user)"
progress "L1 booted"
sysctl hw.vmm.nested.svm_debug=1 >/dev/null 2>&1 || true
send ''
wait_for '# $' 30 || fail "no root shell on L1"
progress "L1 shell"
if [ -n "$PROGRESS" ]; then
	(while kill -0 "$BHYVE_PID" 2>/dev/null; do progress "tick"; sleep 0.5; done) &
	PROGRESS_PID=$!
fi

# Inside L1: confirm the CPU advertises virtualization, load vmm, run L2.
# bhyve in L1 needs writable /tmp (ACPI tables) and /var/run (IPC socket);
# the disk is a scratch copy, so make the single-user root read-write.
send 'mount -u -o rw / && mount -t tmpfs tmpfs /tmp && echo TMPOK'
wait_for 'TMPOK' 30 || fail "could not mount tmpfs on /tmp in L1"
progress "L1 kldload vmm"
send 'kldload vmm; echo KLDLOADED'
wait_for 'KLDLOADED' 60 || fail "kldload vmm in L1 did not complete"
progress "L1 vmm loaded"
send 'sysctl hw.vmm.nested.vmx hw.vmm.nested.svm; echo VMMLOADED'
wait_for 'VMMLOADED' 30 || fail "L1 shell unresponsive after kldload"
# vmm(4) initializes SVM lazily on the first VM creation; do that as a
# separate step so a failure here is distinguishable from L2 execution.
progress "L1 first vm_create (svm_enable in L1)"
send 'bhyvectl --vm=probe --create && echo CREATED; bhyvectl --vm=probe --destroy'
wait_for 'CREATED' 60 || fail "vm_create inside L1 failed (see $CONS)"
progress "L1 vm_create done"
if grep -q 'vmm: .*not available\|SVM: not available\|VMX .*not available' "$CONS"; then
	fail "L1 kernel says virtualization is not available: hw.vmm.nested.enable=1 did not expose VMX/SVM to the guest"
fi

mark=$(wc -l < "$CONS")
send 'bhyveload -m 512M -h / -e console=comconsole -e autoboot_delay=1 l2 && echo ===L2START=== && bhyve -c 1 -m 512M -A -H -P -s 0,hostbridge -s 31,lpc -l com1,stdio l2; echo ===L2EXIT=$?==='
wait_for '===L2START===' 60 "$mark" || fail "bhyveload inside L1 failed (see $CONS)"
mark=$(wc -l < "$CONS")
progress "L2 loaded, starting bhyve in L1"

if wait_for 'Copyright \(c\) 1992-20[0-9][0-9] The FreeBSD Project' "$L2_TIMEOUT" "$mark"; then
	log "L2 kernel banner seen"
	# Give it a moment to reach the mountroot prompt for extra evidence.
	if wait_for 'mountroot>' 60 "$mark"; then
		log "L2 reached mountroot>"
	fi
	log "PASS: L2 guest executed inside nested L1"
	exit 0
fi

reason=$(tail -n +"$((mark + 1))" "$CONS" | grep -E 'vm exit|Abort|error|invalid|failed|===L2EXIT' | head -5)
fail "L2 kernel did not run within ${L2_TIMEOUT}s: ${reason:-no diagnostic on console} (log: $CONS)"
