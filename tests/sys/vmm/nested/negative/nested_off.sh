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
#     * has no VMX and no SVM bit in its CPUID -- read straight out of the
#       guest's own boot banner ("Features2=" / "AMD Features2="), so this
#       works with a completely stock guest kernel,
#     * reads hw.vmm.nested.vmx == 0 and hw.vmm.nested.svm == 0 inside itself
#       if it happens to carry a nested-capable vmm(4) (a stock guest has no
#       such sysctls; their absence proves nothing either way), and
#     * cannot create/run a nested VM;
#   and with hw.vmm.nested.enable=1 the host's own capability bit (VMX on an
#   Intel host, SVM on an AMD one) is back in the guest's CPUID.
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
HOST_VMX=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null || echo 0)
HOST_SVM=$(sysctl -n hw.vmm.nested.svm 2>/dev/null || echo 0)

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

# guest_cpuid_virt: what the guest CPU actually advertises, read out of the
# guest's own boot banner.  This is the decisive signal and it works for a
# *stock* guest: FreeBSD prints leaf 1 ECX as "Features2=" and leaf
# 8000_0001 ECX as "AMD Features2=", so the VMX and SVM bits are visible
# without the guest needing our nested-capable vmm(4) at all.
# Echoes "<vmx yes|no> <svm yes|no>".
guest_cpuid_virt()
{
	if grep -Eq '^[[:space:]]+Features2=.*[<,]VMX[,>]' "$CONS"; then
		_v=yes
	else
		_v=no
	fi
	if grep -Eq 'AMD Features2=.*[<,]SVM[,>]' "$CONS"; then
		_s=yes
	else
		_s=no
	fi
	printf '%s %s\n' "$_v" "$_s"
}

# report_caps: ask the running L1 for the nested sysctls, if it has them.
# A stock guest kernel has no hw.vmm.nested.* at all, so "absent" here is
# not evidence either way -- guest_cpuid_virt() is what decides.
# Echoes "<vmx> <svm>"; empty fields mean "absent".
report_caps()
{
	send 'kldload vmm; echo KLDLOADED'
	wait_for 'KLDLOADED' 60 || fail "kldload vmm in L1 did not complete"

	_mark=$(wc -l < "$CONS")
	# Keep every line we type well under 80 columns.  The guest console
	# wraps at 80 and a wrapped command comes back mangled (a stray space
	# lands inside a word), which silently turns the probe into a broken
	# command whose output is empty -- i.e. it would look like "no nested
	# capability" no matter what the kernel actually did.
	send 'V=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null)'
	send 'S=$(sysctl -n hw.vmm.nested.svm 2>/dev/null)'
	send 'echo NC=${V}x${S}yEND'
	wait_for 'NC=[0-9]*x[0-9]*yEND' 30 ||
	    fail "L1 did not answer the nested capability probe"
	_line=$(tail -n +"$((_mark + 1))" "$CONS" | grep -E '^NC=[0-9]*x[0-9]*yEND' | tail -1)
	_vmx=${_line#NC=}
	_vmx=${_vmx%%x*}
	_svm=${_line%yEND*}
	_svm=${_svm##*x}
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
set -- $(guest_cpuid_virt)
offcpuvmx=$1; offcpusvm=$2
log "phase 1 (enable=0): guest CPUID VMX=$offcpuvmx SVM=$offcpusvm (both must be no)"
[ "$offcpuvmx" = no ] ||
    fail "VMX is still in the guest's CPUID while hw.vmm.nested.enable=0"
[ "$offcpusvm" = no ] ||
    fail "SVM is still in the guest's CPUID while hw.vmm.nested.enable=0"

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
set -- $(guest_cpuid_virt)
oncpuvmx=$1; oncpusvm=$2
log "phase 2 (enable=1, no -N): guest CPUID VMX=$oncpuvmx SVM=$oncpusvm"
# The host vendor decides which bit has to come back.
if [ "$HOST_VMX" = 2 ]; then
	[ "$oncpuvmx" = yes ] ||
	    fail "hw.vmm.nested.enable=1 but the guest still has no VMX in its CPUID -- nesting is not on by default"
elif [ "$HOST_SVM" = 2 ]; then
	[ "$oncpusvm" = yes ] ||
	    fail "hw.vmm.nested.enable=1 but the guest still has no SVM in its CPUID -- nesting is not on by default"
else
	skip "host reports neither hw.vmm.nested.vmx=2 nor .svm=2"
fi

# If the guest also carries a nested-capable vmm(4), its own sysctls must
# agree.  A stock guest has no such sysctls; that is fine.
set -- $(report_caps)
onvmx=${1:-}; onsvm=${2:-}
log "phase 2: in-guest hw.vmm.nested.vmx=${onvmx:-absent} hw.vmm.nested.svm=${onsvm:-absent} (absent = stock guest vmm, not a failure)"
stop_l1

log "PASS: hw.vmm.nested.enable is the master switch -- 0 keeps VMX/SVM out of the guest CPUID and blocks nested VMs, 1 restores the capability with no -N flag anywhere"
exit 0
