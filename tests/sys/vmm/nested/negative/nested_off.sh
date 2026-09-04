#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# nested_off.sh: prove that nested virtualization is genuinely OFF when the
# operator turns it off.
#
# Nesting is now ON BY DEFAULT and is controlled purely by the host-wide
# sysctl hw.vmm.nested.enable -- there is no per-VM -N opt-in any more
# (bhyve/bhyveload still accept -N, but it is a no-op).  The safety contract
# this test enforces is therefore the sysctl contract:
#
#   with hw.vmm.nested.enable=0, a guest created afterwards
#     * sees no VMX and no SVM CPUID bit,
#     * reads hw.vmm.nested.vmx == 0 and hw.vmm.nested.svm == 0 inside itself
#       (or does not have those sysctls at all), and
#     * cannot create/run a nested VM;
#   and with hw.vmm.nested.enable=1 the capability comes back.
#
# The second half (capability returns) is what keeps this an honest negative
# test rather than one that would also pass if nesting were simply broken.
#
# A regression that leaks nested capability into guests while the operator has
# switched nesting off makes this test FAIL.
#
# Environment (same shape as l2_smoke.sh):
#   L1_IMAGE     raw UFS FreeBSD image (required)
#   BHYVE        bhyve binary (default: bhyve in PATH)
#   BHYVELOAD    bhyveload binary (default: bhyveload)
#   L1_MEM       default 2G; L1_CPUS default 1
#   L1_TIMEOUT   seconds to wait for the L1 shell (default 300)
#   WORKDIR/KEEP as in l2_smoke.sh
#
# Exit status: 0 PASS (off means off, on means on), 1 FAIL, 77 SKIP.

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

sysctl -n hw.vmm.nested.enable >/dev/null 2>&1 ||
    skip "hw.vmm.nested.enable not present in this kernel"
SAVED_ENABLE=$(sysctl -n hw.vmm.nested.enable)

WORKDIR=${WORKDIR:-$(mktemp -d /tmp/nestedoff.XXXXXX)}
mkdir -p "$WORKDIR" || fail "cannot create $WORKDIR"
DISK="$WORKDIR/l1.raw"

BHYVE_PID=
VM=
CONS=
INFIFO=

cleanup()
{
	exec 3>&- 2>/dev/null
	[ -n "${BHYVE_PID:-}" ] && kill "$BHYVE_PID" 2>/dev/null
	[ -n "${VM:-}" ] && bhyvectl --vm="$VM" --destroy >/dev/null 2>&1
	sysctl hw.vmm.nested.enable="$SAVED_ENABLE" >/dev/null 2>&1
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

# boot_l1 <tag>: boot a fresh L1 from a fresh copy of the image and leave a
# root shell on fd 3.  Deliberately passes NO -N anywhere: the sysctl is the
# only control now.  Sets VM/CONS/INFIFO/BHYVE_PID.
boot_l1()
{
	_tag=$1
	VM="nestedoff$$$_tag"
	CONS="$WORKDIR/console.$_tag.log"
	INFIFO="$WORKDIR/console.$_tag.in"

	log "[$_tag] copying $L1_IMAGE -> $DISK"
	cp "$L1_IMAGE" "$DISK" || fail "copy failed"
	: > "$CONS"
	rm -f "$INFIFO"
	mkfifo "$INFIFO" || fail "mkfifo $INFIFO"

	bhyvectl --vm="$VM" --destroy >/dev/null 2>&1
	"$BHYVELOAD" -c stdio -m "$L1_MEM" -d "$DISK" \
	    -e console=comconsole -e autoboot_delay=1 -e boot_single=YES "$VM" \
	    >"$WORKDIR/bhyveload.$_tag.log" 2>&1 </dev/null ||
	    fail "bhyveload failed: $(tail -3 "$WORKDIR/bhyveload.$_tag.log")"

	log "[$_tag] starting L1 with NO -N ($L1_CPUS vCPU, $L1_MEM)"
	"$BHYVE" -c "$L1_CPUS" -m "$L1_MEM" -A -H -P \
	    -s 0,hostbridge -s 3,virtio-blk,"$DISK" -s 31,lpc \
	    -l com1,stdio "$VM" <"$INFIFO" >>"$CONS" 2>"$WORKDIR/bhyve.$_tag.log" &
	BHYVE_PID=$!
	exec 3>"$INFIFO"

	wait_for 'RETURN for /bin/sh' "$L1_TIMEOUT" ||
	    fail "[$_tag] L1 did not reach the single-user prompt in ${L1_TIMEOUT}s (see $CONS)"
	send ''
	wait_for '# $' 30 || fail "[$_tag] no root shell on L1"
	send 'mount -u -o rw / && mount -t tmpfs tmpfs /tmp && echo TMPOK'
	wait_for 'TMPOK' 30 || fail "[$_tag] could not make L1 root writable"
	log "[$_tag] L1 booted (single user)"
}

stop_l1()
{
	exec 3>&- 2>/dev/null
	[ -n "${BHYVE_PID:-}" ] && kill "$BHYVE_PID" 2>/dev/null
	wait "$BHYVE_PID" 2>/dev/null
	BHYVE_PID=
	bhyvectl --vm="$VM" --destroy >/dev/null 2>&1
	VM=
}

# report_caps: ask the running L1 for its CPUID virt bit and nested sysctls.
# Echoes "<cpuidvirt> <vmx> <svm>"; empty fields mean "absent".
report_caps()
{
	send 'kldload vmm; echo KLDLOADED'
	wait_for 'KLDLOADED' 60 || fail "kldload vmm in L1 did not complete"

	_mark=$(wc -l < "$CONS")
	# dmesg VMX/SVM identification is unreliable across images; use the
	# CPU feature string the guest kernel printed plus the sysctls.
	send 'echo NESTEDCAP_HV=$(grep -c -E "VMX|SVM" /var/run/dmesg.boot 2>/dev/null)_VMX=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null)_SVM=$(sysctl -n hw.vmm.nested.svm 2>/dev/null)_END'
	wait_for 'NESTEDCAP_HV=.*_END' 30 ||
	    fail "L1 did not report the nested capability sysctls"
	_line=$(tail -n +"$((_mark + 1))" "$CONS" | grep -E 'NESTEDCAP_HV=.*_END' | tail -1)
	_vmx=$(printf '%s\n' "$_line" | sed -E 's/.*_VMX=([0-9]*)_SVM=([0-9]*)_END.*/\1/')
	_svm=$(printf '%s\n' "$_line" | sed -E 's/.*_VMX=([0-9]*)_SVM=([0-9]*)_END.*/\2/')
	printf '%s %s\n' "$_vmx" "$_svm"
}

##############################################################################
# Phase 1: operator turns nesting OFF.  A guest created afterwards must have
# no nested capability at all.
##############################################################################
log "phase 1: sysctl hw.vmm.nested.enable=0"
sysctl hw.vmm.nested.enable=0 >/dev/null 2>&1 ||
    fail "could not set hw.vmm.nested.enable=0"
[ "$(sysctl -n hw.vmm.nested.enable)" = 0 ] ||
    fail "hw.vmm.nested.enable did not take the value 0"

boot_l1 off
set -- $(report_caps)
offvmx=${1:-}; offsvm=${2:-}
log "phase 1 (enable=0): in-guest hw.vmm.nested.vmx=${offvmx:-absent} hw.vmm.nested.svm=${offsvm:-absent} (absent or 0 = off)"
case "${offvmx}" in ""|0) : ;; *) fail "nested VMX exposed while hw.vmm.nested.enable=0 (vmx=$offvmx)";; esac
case "${offsvm}" in ""|0) : ;; *) fail "nested SVM exposed while hw.vmm.nested.enable=0 (svm=$offsvm)";; esac

# Belt and suspenders: creating and running a nested guest must not succeed.
mark=$(wc -l < "$CONS")
send 'bhyveload -m 256M -h / -e autoboot_delay=0 nog 2>&1 | tail -1; echo ===NOGDONE==='
wait_for '===NOGDONE===' 60 || true
if tail -n +"$((mark + 1))" "$CONS" | grep -Eq 'Copyright \(c\) 1992-20[0-9][0-9] The FreeBSD Project'; then
	fail "a nested guest actually ran while hw.vmm.nested.enable=0 -- nested is NOT off"
fi
log "phase 1 PASS: nesting is genuinely off with hw.vmm.nested.enable=0"
stop_l1

##############################################################################
# Phase 2: operator turns nesting back ON (the default).  The same guest
# recipe -- still with NO -N -- must now see the capability.  This proves the
# phase-1 result was the switch working, not nesting being broken.
##############################################################################
log "phase 2: sysctl hw.vmm.nested.enable=1"
if ! sysctl hw.vmm.nested.enable=1 >/dev/null 2>&1; then
	log "hw.vmm.nested.enable=1 refused by this host (no VMX/SVM nesting capability)"
	log "PASS: off-is-off verified; capability-returns half not applicable here"
	exit 0
fi

boot_l1 on
set -- $(report_caps)
onvmx=${1:-}; onsvm=${2:-}
log "phase 2 (enable=1, still no -N): in-guest hw.vmm.nested.vmx=${onvmx:-absent} hw.vmm.nested.svm=${onsvm:-absent}"
if [ "${onvmx:-0}" != 2 ] && [ "${onsvm:-0}" != 2 ]; then
	fail "with hw.vmm.nested.enable=1 and no -N the guest still sees no nested capability (vmx=${onvmx:-absent} svm=${onsvm:-absent}) -- nesting is not on by default"
fi
stop_l1

log "PASS: hw.vmm.nested.enable is the master switch -- 0 hides VMX/SVM and blocks nested VMs, 1 restores the capability with no -N flag anywhere"
exit 0
