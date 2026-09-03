#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 The FreeBSD Project
#
# nested_off.sh: prove that nested virtualization is genuinely OFF when a
# user has not opted into it. Nesting must be strictly opt-in: a guest is
# only given VMX/SVM when bhyve is asked for it with -N *and* the host has
# hw.vmm.nested.enable=1. This test does the opposite of the l2_smoke.sh
# positive case: it boots an ordinary L1 guest WITHOUT -N and requires that
# inside that guest the CPU exposes no virtualization at all -- both
# hw.vmm.nested.vmx and hw.vmm.nested.svm read 0, and a nested VM cannot be
# created. A regression that leaks nested capability into guests by default
# makes this test FAIL.
#
# Environment (same shape as l2_smoke.sh):
#   L1_IMAGE     raw UFS FreeBSD image (required)
#   BHYVE        bhyve binary (default: bhyve in PATH); -N is deliberately NOT used
#   BHYVELOAD    bhyveload binary (default: bhyveload)
#   L1_MEM       default 2G; L1_CPUS default 1
#   L1_TIMEOUT   seconds to wait for the L1 shell (default 300)
#   WORKDIR/KEEP as in l2_smoke.sh
#
# Exit status: 0 PASS (nested confirmed off), 1 FAIL (nested leaked), 77 SKIP.

set -u

: "${L1_IMAGE:=}"
: "${BHYVE:=bhyve}"
: "${BHYVELOAD:=bhyveload}"
: "${L1_MEM:=2G}"
: "${L1_CPUS:=1}"
: "${L1_TIMEOUT:=300}"
: "${KEEP:=0}"

log()  { printf 'nested_off: %s\n' "$*"; }
skip() { log "SKIP: $*"; exit 77; }
fail() { log "FAIL: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || skip "must run as root"
[ -n "$L1_IMAGE" ] && [ -r "$L1_IMAGE" ] || skip "L1_IMAGE not set or unreadable"
command -v "$BHYVE" >/dev/null 2>&1 || skip "$BHYVE not found"
kldstat -q -n vmm || skip "vmm.ko not loaded"

WORKDIR=${WORKDIR:-$(mktemp -d /tmp/nestedoff.XXXXXX)}
mkdir -p "$WORKDIR" || fail "cannot create $WORKDIR"
VM="nestedoff$$"
DISK="$WORKDIR/l1.raw"
CONS="$WORKDIR/console.log"
INFIFO="$WORKDIR/console.in"

cleanup()
{
	exec 3>&- 2>/dev/null
	[ -n "${BHYVE_PID:-}" ] && kill "$BHYVE_PID" 2>/dev/null
	bhyvectl --vm="$VM" --destroy >/dev/null 2>&1
	[ "$KEEP" = 1 ] && log "kept $WORKDIR" || rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

send() { printf '%s\r' "$*" >&3; }
wait_for()
{
	_re=$1; _t=$2; _after=${3:-0}; _n=0
	while [ $_n -lt "$_t" ]; do
		if tail -n +"$((_after + 1))" "$CONS" | grep -Eq "$_re"; then return 0; fi
		sleep 1; _n=$((_n + 1))
	done
	return 1
}

log "copying $L1_IMAGE -> $DISK"
cp "$L1_IMAGE" "$DISK" || fail "copy failed"
: > "$CONS"
mkfifo "$INFIFO" || fail "mkfifo $INFIFO"

bhyvectl --vm="$VM" --destroy >/dev/null 2>&1
# NOTE: deliberately NO -N here -- an ordinary guest, no nested opt-in.
"$BHYVELOAD" -c stdio -m "$L1_MEM" -d "$DISK" \
    -e console=comconsole -e autoboot_delay=1 -e boot_single=YES "$VM" \
    >"$WORKDIR/bhyveload.log" 2>&1 </dev/null ||
    fail "bhyveload failed: $(tail -3 "$WORKDIR/bhyveload.log")"

log "starting L1 WITHOUT -N ($L1_CPUS vCPU, $L1_MEM)"
"$BHYVE" -c "$L1_CPUS" -m "$L1_MEM" -A -H -P \
    -s 0,hostbridge -s 3,virtio-blk,"$DISK" -s 31,lpc \
    -l com1,stdio "$VM" <"$INFIFO" >>"$CONS" 2>"$WORKDIR/bhyve.log" &
BHYVE_PID=$!
exec 3>"$INFIFO"

wait_for 'RETURN for /bin/sh' "$L1_TIMEOUT" ||
    fail "L1 did not reach the single-user prompt in ${L1_TIMEOUT}s (see $CONS)"
log "L1 booted (single user)"
send ''
wait_for '# $' 30 || fail "no root shell on L1"

send 'mount -u -o rw / && mount -t tmpfs tmpfs /tmp && echo TMPOK'
wait_for 'TMPOK' 30 || fail "could not make L1 root writable"
send 'kldload vmm; echo KLDLOADED'
wait_for 'KLDLOADED' 60 || fail "kldload vmm in L1 did not complete"

# The decisive check: with no -N, the guest CPU must expose no virtualization.
mark=$(wc -l < "$CONS")
send 'echo NESTEDOFF_VMX=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null)_SVM=$(sysctl -n hw.vmm.nested.svm 2>/dev/null)_END'
wait_for 'NESTEDOFF_VMX=.*_END' 30 || fail "L1 did not report the nested capability sysctls"
line=$(tail -n +"$((mark + 1))" "$CONS" | grep -E 'NESTEDOFF_VMX=.*_END' | tail -1)
vmxv=$(printf '%s\n' "$line" | sed -E 's/.*NESTEDOFF_VMX=([0-9]*)_SVM=([0-9]*)_END.*/\1/')
svmv=$(printf '%s\n' "$line" | sed -E 's/.*NESTEDOFF_VMX=([0-9]*)_SVM=([0-9]*)_END.*/\2/')
# An un-opted-in guest exposes no virtualization: the capability sysctls are
# either absent (the guest CPU has no VMX/SVM at all) or read 0. Any real
# "available" value (e.g. 2) means nested capability leaked into the guest.
log "inside L1 (no -N): hw.vmm.nested.vmx=${vmxv:-absent} hw.vmm.nested.svm=${svmv:-absent} (absent or 0 = off)"
case "${vmxv}" in ""|0) : ;; *) fail "nested VMX exposed to an un-opted-in guest (vmx=$vmxv; expected absent or 0)";; esac
case "${svmv}" in ""|0) : ;; *) fail "nested SVM exposed to an un-opted-in guest (svm=$svmv; expected absent or 0)";; esac

# Belt and suspenders: creating and running a nested guest must not succeed.
mark=$(wc -l < "$CONS")
send 'bhyveload -m 256M -h / -e autoboot_delay=0 nog 2>&1 | tail -1; echo ===NOGDONE==='
wait_for '===NOGDONE===' 60 || true
if tail -n +"$((mark + 1))" "$CONS" | grep -Eq 'Copyright \(c\) 1992-20[0-9][0-9] The FreeBSD Project'; then
	fail "a nested guest actually ran without -N -- nested is NOT off"
fi

log "PASS: nested virtualization is off in an un-opted-in guest (vmx=0, svm=0, no nested guest)"
exit 0
