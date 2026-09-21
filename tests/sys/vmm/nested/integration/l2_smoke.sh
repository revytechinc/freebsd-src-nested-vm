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
# Only require the -N flags when NFLAG actually asks for them.  They used to
# be unconditional, as a proxy for "these binaries were built from this tree",
# and that proxy was simply false: CloudBSD-bhyve built from this very tree
# advertises no -N at all, so the gate skipped the only test that proves an L2
# runs -- on every host in the fleet, including the ones running this tree's
# kernel, for as long as it has existed.  A skip is reported as a non-failure,
# so nothing ever said so.
#
# hw.vmm.nested.enable immediately below is the check that still carries
# weight: stock vmm(4) has no hw.vmm.nested.* sysctls, so a kernel accepting
# it is necessarily ours.  That is a statement about the KERNEL only -- there
# is deliberately no provenance check left on the bhyve binaries, because
# nesting needs no per-VM flag (see the header) and so a stock bhyve is a
# legitimate way to run this test.
command -v "$BHYVELOAD" >/dev/null 2>&1 || skip "$BHYVELOAD not found"
if [ -n "$NFLAG" ]; then
	# An explicit NFLAG the binaries cannot honour is a FAILURE, not a skip.
	# Skipping a request the caller actually made is the same unreported
	# non-failure this gate was rewritten to stop producing.
	#
	# The usage grep is kept here even though it is a poor proxy for "built
	# from this tree", because that is no longer what it is being asked.
	# The question now is only "does this binary accept -N", which is
	# exactly what a caller passing NFLAG needs to know.  It is still a
	# usage-text match rather than a real acceptance probe, so a binary that
	# accepts -N without documenting it fails here; that is the residue.
	"$BHYVE" -h 2>&1 | grep -q -- '-N' ||
	    fail "NFLAG=$NFLAG but $BHYVE does not accept -N (build usr.sbin/bhyve from this tree)"
	"$BHYVELOAD" 2>&1 | grep -q -- '-NS' ||
	    fail "NFLAG=$NFLAG but $BHYVELOAD does not accept -N (build usr.sbin/bhyveload from this tree)"
fi
# -m, not -n: -n matches the linker FILE, so a vmm compiled into the kernel
# lives in the file "kernel" and -n vmm returns 1.  That failed OPEN here --
# a host with a built-in vmm skipped silently, which is the same class of
# unreported non-failure as the -N gate above.
#
# The module name is "vmm" exactly: sys/dev/vmm/vmm_dev.c has
# DECLARE_MODULE(vmm, ...) and MODULE_VERSION(vmm, 1), so -m vmm names this
# tree's module in both forms.  Measured with vmm loaded as a module
# (`kldstat -q -m vmm` exits 0), and the built-in case demonstrated with ufs,
# which is compiled into GENERIC: -n ufs exits 1 while -m ufs exits 0.
kldstat -q -m vmm || skip "vmm is neither loaded nor built into the kernel"
if [ "$(sysctl -n hw.vmm.nested.enable 2>/dev/null)" != "1" ]; then
	sysctl hw.vmm.nested.enable=1 >/dev/null 2>&1 ||
	    skip "hw.vmm.nested.enable=1 refused (hw.vmm.nested.vmx/svm not 1?)"
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
# NOTE on every sentinel below: the literal is SPLIT with "" so that the
# assembled token appears only in the guest's OUTPUT, never in the command
# text.  The L1 console echoes each command back -- twice, once as typed and
# once by the shell's prompt -- so an unsplit `echo CREATED` puts "CREATED" on
# the console BEFORE the command has run, and wait_for matches that echo.
# Every `&&` guard in this section was therefore inert: `bhyvectl --create &&
# echo CREATED` reported success even when bhyvectl failed, because the test
# was reading the question rather than the answer.  Verified against a real
# console log, where CREATED appears on lines 99 and 108 as command text and
# only on line 109 as output.
#
# The split must be "" and not '': the send argument is itself single-quoted,
# so an inner '' merely closes and reopens THAT string and the guest receives
# the assembled token anyway.  Getting this wrong turns the guard inside out
# -- it was caught here only because the false FAIL was loud.
# Canary for the whole scheme.  Every guard below depends on send() putting
# the quotes on the wire untouched -- it is `printf '%s\r' "$*" >&3` today,
# but an eval, an sh -c or an ssh hop added later would strip them and quietly
# return every sentinel to matching its own echo: a silent false PASS, which
# is the worst direction.  So send a token that is ONLY ever command text and
# must never appear assembled.  If it does, the splitting has stopped working
# and no other guard in this file can be believed.
send ': CAN"ARY"'
sleep 2
if grep -q CANARY "$CONS"; then
	fail "send() is no longer delivering quotes verbatim -- every sentinel below would match the command echo instead of the guest's output, so this run would PASS without proving anything (see $CONS)"
fi

send 'mount -u -o rw / && mount -t tmpfs tmpfs /tmp && echo TMP"OK"'
wait_for 'TMPOK' 30 || fail "could not mount tmpfs on /tmp in L1"
progress "L1 kldload vmm"
# Assert the STATE, not the command.  `kldload vmm; echo KLDLOADED` printed
# the sentinel whatever happened, so an L1 image with no vmm.ko reported
# "kldload: can't load vmm: No such file or directory" and then KLDLOADED on
# the next line, and the test sailed past it.  kldstat is the question worth
# asking anyway -- it is also satisfied when vmm is built into the kernel or
# was already loaded, both of which make a bare `kldload &&` fail wrongly.
send 'kldload vmm 2>&1; if kldstat -q -m vmm; then echo KLD"LOADED"; else echo KLD"MISSING"; fi'
wait_for 'KLDLOADED|KLDMISSING' 60 ||
    fail "L1 shell never answered the kldload probe -- hung or dead, see $CONS"
grep -q KLDMISSING "$CONS" &&
    fail "vmm is not loaded in L1 and is not built in (no vmm.ko in the L1 image?) -- see $CONS"
progress "L1 vmm loaded"
send 'sysctl hw.vmm.nested.vmx hw.vmm.nested.svm; echo VMM"LOADED"'
wait_for 'VMMLOADED' 30 || fail "L1 shell unresponsive after kldload"
# vmm(4) initializes SVM lazily on the first VM creation; do that as a
# separate step so a failure here is distinguishable from L2 execution.
progress "L1 first vm_create (svm_enable in L1)"
send 'bhyvectl --vm=probe --create && echo CRE"ATED"; bhyvectl --vm=probe --destroy'
wait_for 'CREATED' 60 || fail "vm_create inside L1 failed (see $CONS)"
progress "L1 vm_create done"
if grep -q 'vmm: .*not available\|SVM: not available\|VMX .*not available' "$CONS"; then
	fail "L1 kernel says virtualization is not available: hw.vmm.nested.enable=1 did not expose VMX/SVM to the guest"
fi

mark=$(wc -l < "$CONS")
send 'bhyveload -m 512M -h / -e console=comconsole -e autoboot_delay=1 l2 && echo ===L2"START"=== && bhyve -c 1 -m 512M -A -H -P -s 0,hostbridge -s 31,lpc -l com1,stdio l2; echo ===L2"EXIT"=$?==='
wait_for '===L2START===' 60 "$mark" || fail "bhyveload inside L1 failed (see $CONS)"
# Deliberately NOT re-marked here.  A second mark taken after wait_for returns
# races the L2 output: wait_for polls once a second, bhyve starts the instant
# bhyveload finishes, and any banner emitted inside that window would land
# BEFORE the new mark and be invisible to the searches below -- a false
# timeout.  It was safe only while ===L2START=== matched the command echo and
# so fired before L2 produced anything; splitting the sentinel removed that
# accident.  The pre-send mark is correct and sufficient: nothing between it
# and here can contain an L2 kernel banner.
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
