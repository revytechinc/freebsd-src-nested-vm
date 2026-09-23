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
#   SVM_DEBUG    hw.vmm.nested.svm_debug to run L0 with (default 1). The
#                tracer roughly doubles the observed L2 failure rate, so
#                every rate measured here must be reported with this value;
#                set 0 for the other arm. The run reads the sysctl back and
#                ABORTS if it is not what was asked for, since the rate would
#                otherwise be filed under the wrong arm; on a VMX host the
#                OID is absent and the arm is reported as n/a instead.
#   SVM_DEBUG_STRICT=0
#                downgrade that abort to a warning (diagnostic runs only).
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
# Number of L2 guests to boot inside the ONE L1 boot. 1 is the smoke test and
# is the default, so this file behaves exactly as before unless asked. Higher
# values make it the VMRUN/VMRESUME stress that stress_vmrun.sh drives: each
# cycle is a full L2 entry and teardown from the same L1, which is where a
# leaked ASID/VPID or a resource leak in the nested path would show up.
: "${L2_CYCLES:=1}"
# hw.vmm.nested.svm_debug to run L0 with. Applied once L1 has booted, and
# deliberately NOT restored on exit -- the host is left in whichever arm ran
# last, so set it explicitly rather than inheriting it.
#
# This used to be hard-coded to 1 further down, which quietly defeated the one
# control every rate measured with this harness is supposed to name: the
# tracer roughly DOUBLES the observed failure rate (measured 16.5% at 1
# against 9.5% at 0, pooled over 420 launches), so a campaign that sets the
# sysctl beforehand and then runs this script was measuring the 1 arm twice
# and reporting it as a comparison. Default stays 1 so existing results
# remain comparable; set SVM_DEBUG=0 to measure the other arm.
: "${SVM_DEBUG:=1}"
# Refuse to run when the tracer is not the requested value, because the rate
# would be filed under the wrong arm. SVM_DEBUG_STRICT=0 downgrades that to a
# warning for a diagnostic run that does not care about attribution.
: "${SVM_DEBUG_STRICT:=1}"
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

# Validate arguments BEFORE prerequisites. A bad SVM_DEBUG costs nothing to
# catch here, and checking it after L1 boots wasted a full boot to report a
# typo. Ordering it ahead of the root check also makes it testable without
# privileges or hardware.
#
# ORDERING THIS DEPENDS ON: both variables are defaulted in the `: "${X:=}"`
# block near the top, well above this point, and `fail` is defined just above.
# If a default is ever moved below here, `set -u` turns an ordinary unset-
# variable run into an unbound-variable death (exit 2) instead of the
# documented exit 1 -- or, with the default gone entirely, into a spurious
# "must be 0 or 1, got ''" on a run that asked for nothing unusual.
# l2_smoke_args_test.sh's "unset accepted" and "empty -> default" cases are
# what catch that, so keep them.
case "${SVM_DEBUG}" in
0|1) ;;
*)   fail "SVM_DEBUG must be 0 or 1, got '${SVM_DEBUG}' -- values like '01' or ' 1' set the sysctl but then fail the readback comparison and abort as a mismatch that never happened" ;;
esac
case "${SVM_DEBUG_STRICT}" in
0|1) ;;
*)   fail "SVM_DEBUG_STRICT must be 0 or 1, got '${SVM_DEBUG_STRICT}'" ;;
esac

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

# Prune abandoned work directories before making another one.
#
# Each of these holds a COPY OF THE L1 DISK IMAGE, so they are ~1.3G apiece.
# Measured on a test host: 24 of them, 32G in total, dating from runs whose
# EXIT trap never fired -- a kyua timeout sends SIGKILL, and a killed shell
# runs no trap. They are mode 0700 and owned by root, so an unprivileged
# `rm -rf /tmp/l2smoke.*' reports nothing and removes nothing, which is why
# nobody noticed.
#
# This matters more now that a FAILING run keeps its directory deliberately
# (see cleanup): at roughly one failed launch in ten, keeping every one of
# them without pruning would trade a disk leak for a diagnostic. Keep the
# recent ones, which are the ones anybody would still want to read.
: "${WORKDIR_KEEP_DAYS:=2}"
find /tmp -maxdepth 1 -type d -name 'l2smoke.*' \
    -mtime "+${WORKDIR_KEEP_DAYS}" -exec rm -rf {} + 2>/dev/null || true

WORKDIR=${WORKDIR:-$(mktemp -d /tmp/l2smoke.XXXXXX)}
mkdir -p "$WORKDIR" || fail "cannot create $WORKDIR"
VM="l2smoke$$"
DISK="$WORKDIR/l1.raw"
CONS="$WORKDIR/console.log"
INFIFO="$WORKDIR/console.in"

cleanup()
{
	# FIRST statement: $? is the script's exit status only until something
	# else runs.
	_rc=$?

	exec 3>&- 2>/dev/null
	[ -n "${PROGRESS_PID:-}" ] && kill "$PROGRESS_PID" 2>/dev/null
	[ -n "${BHYVE_PID:-}" ] && kill "$BHYVE_PID" 2>/dev/null
	bhyvectl --vm="$VM" --destroy >/dev/null 2>&1
	# A FAILING run keeps its evidence, whatever KEEP says.
	#
	# This used to delete the work directory on every exit unless KEEP=1 was
	# set in advance -- including the failures. So a run would print
	#
	#	FAIL: only 19 of 20 L2 guests booted (log: /tmp/l2smoke.XXXX/console.log)
	#
	# and then remove that file before anyone could read it. The one message
	# naming the evidence was also the moment the evidence was destroyed, and
	# reproducing an intermittent fault to see it again is expensive: this is
	# a defect that appears roughly one launch in ten.
	#
	# KEEP=1 still means "keep even on success".
	if [ "$KEEP" = 1 ] || [ "$_rc" -ne 0 ]; then
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
# Apply the requested tracer setting, then read back what it ACTUALLY is and
# refuse to continue if they disagree. "I set it" and "the run used it" are
# different claims: a caller that sets this sysctl before invoking the script
# has its value overwritten right here, which is how a campaign ends up
# running one arm twice and reporting it as a comparison.
#
# Three states, not two, and the third is why this cannot simply fail:
# hw.vmm.nested.svm_debug is SVM-only, so on a VMX host the OID is ABSENT.
# That is not a mismatched arm, it is a host with no SVM tracer to set, and
# failing there would break every Intel run.
# What the operator left the sysctl at BEFORE we touch it. Reading this is the
# difference between checking our own work and checking their intent: without
# it, "set the sysctl to 0, then run without SVM_DEBUG=0" still measures arm 1
# and sails through the readback below, because the readback only confirms the
# value this script itself just wrote. That is the very workflow this block
# exists to catch.
_svm_pre=$(sysctl -n hw.vmm.nested.svm_debug 2>/dev/null)

_svm_err=$(sysctl "hw.vmm.nested.svm_debug=${SVM_DEBUG}" 2>&1 >/dev/null)
_svm_dbg=$(sysctl -n hw.vmm.nested.svm_debug 2>/dev/null)
_svm_rerr=$(sysctl -n hw.vmm.nested.svm_debug 2>&1 >/dev/null)

# Only the literal "0" downgrades the abort. Testing for "1" instead would let
# every typo -- "yes", "true", "2" -- silently disable the check, which is the
# same fail-open this whole block exists to remove.
_svm_strict=0
[ "${SVM_DEBUG_STRICT}" != "0" ] && _svm_strict=1

if [ -n "${_svm_dbg}" ] && [ "${_svm_dbg}" = "${SVM_DEBUG}" ]; then
	log "L0 hw.vmm.nested.svm_debug=${_svm_dbg}"
	progress "svm_debug=${_svm_dbg}"
	# The write succeeded, but did the caller MEAN this arm? A host left at
	# the other value, with SVM_DEBUG not passed, is almost certainly someone
	# selecting the arm the old way -- which this script silently overrode
	# for as long as it hard-coded 1. Say so rather than measuring the arm
	# they did not ask for.
	if [ -n "${_svm_pre}" ] && [ "${_svm_pre}" != "${SVM_DEBUG}" ]; then
		log "warning: host had hw.vmm.nested.svm_debug=${_svm_pre}, this run forces ${SVM_DEBUG} -- pass SVM_DEBUG=${_svm_pre} if you meant to measure that arm"
		progress "svm_debug_override=${_svm_pre}->${SVM_DEBUG}"
	fi
elif [ -z "${_svm_dbg}" ]; then
	# Empty readback is THREE states, not one: the OID is genuinely absent
	# (SVM-only, so a VMX host has none), sysctl could not run at all, or
	# the read failed some other way. Only the first is benign, and only an
	# "unknown oid" error establishes it -- an empty stdout does not.
	case "${_svm_rerr}" in
	*"unknown oid"*|*"unknown 'oid'"*)
		# Confirm it really is a VMX host rather than an AMD kernel that
		# is missing the tracer, which would be a finding, not an n/a.
		# hw.vmm.nested.vmx exists on BOTH vendors on this tree -- it
		# reads 1 on Tiger Lake and Ivy Bridge and 0 on Zen+ -- so its
		# absence here would itself be unexpected and falls through to
		# the fail below rather than being read as "not VMX".
		if [ "$(sysctl -n hw.vmm.nested.vmx 2>/dev/null)" = "1" ]; then
			log "L0 has no hw.vmm.nested.svm_debug (SVM-only OID) on a VMX host -- tracer arm: n/a"
			progress "svm_debug=n/a"
		else
			fail "hw.vmm.nested.svm_debug is absent and this is not a VMX host (${_svm_rerr}) -- cannot attribute a tracer arm"
		fi
		;;
	*)
		fail "could not read hw.vmm.nested.svm_debug: ${_svm_rerr:-no error text}${_svm_err:+ (set said: $_svm_err)} -- I could not look, which is not the same as it not being there"
		;;
	esac
else
	# Present, and NOT what was asked for. Every rate this harness produces
	# has to name this value, so continuing would mislabel the result.
	progress "svm_debug=${_svm_dbg}-REQUESTED-${SVM_DEBUG}"
	[ "${_svm_strict}" = "0" ] ||
	    fail "hw.vmm.nested.svm_debug is ${_svm_dbg}, not the requested ${SVM_DEBUG}${_svm_err:+ ($_svm_err)} -- results would belong to the ${_svm_dbg} arm. Set SVM_DEBUG_STRICT=0 to run anyway."
	log "warning: tracer is ${_svm_dbg}, NOT the requested ${SVM_DEBUG}${_svm_err:+ ($_svm_err)} -- rates from this run belong to the ${_svm_dbg} arm"
fi
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
# The companion token is what makes this falsifiable.  `sleep; grep` alone
# would be silent when send delivered NOTHING at all, or when the console was
# merely slow -- absence of the canary would read as health, which is the same
# false PASS in a check written to prevent false PASSes.  CANDONE must arrive
# either way (split or not, it is echoed at minimum), so waiting for it proves
# the line was processed BEFORE the canary's absence is allowed to mean
# anything.
send ': CAN"ARY"; echo CANDO"NE"'
wait_for 'CANDONE' 30 ||
    fail "L1 console did not answer the send-integrity probe at all -- nothing below can be believed (see $CONS)"
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

l2_failed()
{
	reason=$(tail -n +"$(($1 + 1))" "$CONS" |
	    grep -E 'vm exit|Abort|error|invalid|failed|===L2EXIT' | head -5)
	fail "L2 kernel did not run within ${L2_TIMEOUT}s: ${reason:-no diagnostic on console} (log: $CONS)"
}

if [ "$L2_CYCLES" -le 1 ]; then
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

	# SINGLE SHOT -- unchanged, and deliberately kept separate from the
	# stress path below. This is the form proven on all six fleet hosts;
	# it runs bhyve in the FOREGROUND with com1 on stdio, which is why it
	# cannot be looped: once L2 boots it owns L1's console, so anything
	# typed next goes to the L2's mountroot> prompt rather than to L1's
	# shell. That is not a theory -- the first version of the loop sent
	# `bhyvectl --destroy' and L2 answered "Invalid file system
	# specification."
	if wait_for 'Copyright \(c\) 1992-20[0-9][0-9] The FreeBSD Project' "$L2_TIMEOUT" "$mark"; then
		log "L2 kernel banner seen"
		if wait_for 'mountroot>' 60 "$mark"; then
			log "L2 reached mountroot>"
		fi
		log "PASS: L2 guest executed inside nested L1"
		exit 0
	fi
	l2_failed "$mark"
fi

# STRESS -- N L2 entries from the one L1, which is what exercises repeated
# VMRUN/VMRESUME and shows up an ASID/VPID or resource leak in the nested path.
#
# The whole loop is handed to L1 as ONE command and reports ONE total, rather
# than being driven a cycle at a time from here. Driving it from here needs
# L1's shell to stay reachable between cycles, and it is not: com1 on stdio
# gives the console to the guest. So each L2 is backgrounded with its console
# redirected to a file inside L1, and L1 greps that file itself.
#
# The count comes back as seen/attempted. Reporting only "seen" would let a
# loop that ran three cycles instead of N look like a pass.
#
# kill -9 and no `wait'. A guest sitting at mountroot> does not necessarily
# act on SIGTERM, and `wait' on a process that will not die blocks the loop
# for ever -- which presents as "L1 wedged or died" and is indistinguishable
# from a real nested-virt hang, i.e. the harness would have blamed the kernel
# for its own teardown bug. bhyvectl --destroy at the top of each cycle is
# what actually reclaims the VM.
log "stress: ${L2_CYCLES} L2 cycles inside one L1"

# The loop is WRITTEN TO A FILE in L1 a line at a time, then run -- not typed
# as one long command. Two reasons, both learned here: a single 500-character
# line is awkward to reason about when it goes wrong, and it gives no way to
# see WHICH step blocked, because a shell busy in a loop prints nothing and
# returns no prompt. The per-step STEP= markers below are what make a hang
# diagnosable instead of just "L1 wedged or died".
_w() {
	mark=$(wc -l < "$CONS")
	send "printf '%s\\n' $1 >> /tmp/stress.sh; echo WROTE\"LINE\""
	wait_for 'WROTELINE' 30 "$mark" ||
	    fail "L1 stopped accepting input while writing the stress script (log: $CONS)"
}

mark=$(wc -l < "$CONS")
send 'rm -f /tmp/stress.sh /tmp/l2c; echo CLEAR"ED"'
wait_for 'CLEARED' 30 "$mark" || fail "L1 unresponsive before the stress loop (log: $CONS)"

_w "'kldload nmdm >/dev/null 2>&1'"
_w "'i=0; ok=0'"
_w "'while [ \$i -lt ${L2_CYCLES} ]; do'"
_w "'echo STEP=destroy:\$i'"
_w "'bhyvectl --vm=l2 --destroy >/dev/null 2>&1'"
_w "'echo STEP=load:\$i'"
_w "': > /tmp/l2c'"
# The reader starts BEFORE the guest. Started afterwards it races the
# banner: cycle 8 of a 10-cycle run missed for exactly that reason while
# every other cycle passed. Opening the B side first also creates the
# nmdm pair, so the A side is there when bhyve wants it.
_w "'( cat /dev/nmdm_l2\${i}B > /tmp/l2c 2>/dev/null & echo \$! > /tmp/catpid )'"
_w "'sleep 1'"
_w "'bhyveload -m 512M -h / -e console=comconsole -e autoboot_delay=0 l2 >/tmp/l2load 2>&1'"
_w "'echo STEP=loadrc:\$?'"
# A FRESH nmdm pair per cycle -- nmdm_l2${i}, not a single nmdm_l2. Reusing
# one pair across cycles leaves a race: kill -9 on bhyve can leave the A side
# held for a moment, so the next cycle's guest attaches its console to nothing
# and its banner is never seen. That produced 44/50 on a soak whose failures
# fell on cycles 9, 13, 15, 27, 31 and 32 -- scattered, with the LAST ten
# clean, which is the shape of a race and rules out the resource leak this
# loop is looking for. A leak degrades monotonically.
#
# com1 on an nmdm(4) pair, NOT on stdio redirected into a file. bhyve's
# stdout is block-buffered when it is not a tty, so the L2 banner sits in
# bhyve's own 4K buffer and may never reach the file while the guest is
# still running -- which reads exactly like "L2 did not boot". Measured:
# 6/10 and 8/10 on runs where bhyveload returned 0 every time and the
# failures fell on scattered cycles. nmdm is a tty, so `cat' of the B side
# delivers each line as it arrives. This is the trap nested-regression-matrix
# already warns about under "nmdm console rules".
# bhyve's OWN stderr is kept, not sent to /dev/null. It aborts on a small
# fraction of nested launches -- "pid N (bhyve) exited on signal 6" -- and
# signal 6 is abort(), which this loop's kill -9 cannot produce. The first
# two soaks recorded the abort and NOT the reason, because stderr had been
# discarded: the evidence that would name the assertion was thrown away by
# the harness watching for it.
_w "'bhyve -c 1 -m 512M -A -H -P -s 0,hostbridge -s 31,lpc -l com1,/dev/nmdm_l2\${i}A l2 >/tmp/l2err.\${i} 2>&1 &'"
_w "'p=\$!'"
_w "'echo STEP=started:\$p'"
# POLL, do not sleep a fixed time. A flat `sleep 15' makes the test ask
# "did L2 boot within exactly 15 seconds", and L1 is itself a guest whose
# timing varies with host load: a first run scored 8/10 with the two
# failures at cycles 1 and 7 -- scattered rather than clustering at the
# end, which is the shape of a timing artifact and NOT of the resource
# leak this loop is looking for. Reported as a kernel result that would
# have been a fabricated defect.
_w "'n=0'"
_w "'while [ \$n -lt 60 ]; do grep -q \"Copyright (c) 199\" /tmp/l2c && break; sleep 1; n=\$((n+1)); done'"
_w "'grep -q \"Copyright (c) 199\" /tmp/l2c && ok=\$((ok+1))'"
_w "'echo STEP=checked:\$ok'"
# On a miss, show what bhyve said. Silence here is what turned a real abort
# into an unexplained cycle for two whole soaks.
_w "'grep -q \"Copyright (c) 199\" /tmp/l2c || { echo BHYVE\"ERR\":\$i; cat /tmp/l2err.\${i} 2>/dev/null | tail -5; }'"
# On a miss, ASK WHETHER THE GUEST IS EXECUTING rather than guessing. An exit
# count above zero means the vcpu has been entered and the console is the
# broken part; a count of zero means it never ran at all. Those are different
# bugs, and three soaks have been unable to tell them apart because nothing
# looked.
_w "'if grep -q \"Copyright (c) 199\" /tmp/l2c; then :; else'"
_w "'echo VMSTAT\"S\":\$i'"
# Is the console READER still alive? A guest spinning in ns8250_putc is
# waiting for a UART transmitter that never drains, and a dead cat(1) on the
# nmdm B side produces exactly that -- in which case the freeze is this
# harness, not the nested path. Ask before claiming otherwise.
_w "'echo CATALIV\"E\":\$(ps -p \$(cat /tmp/catpid 2>/dev/null) >/dev/null 2>&1 && echo yes || echo NO)'"
_w "'echo L2CBYTES:\$(wc -c < /tmp/l2c 2>/dev/null)'"
_w "'bhyvectl --vm=l2 --get-stats 2>&1 | grep -i \"total number of vm exits\"'"
_w "'bhyvectl --vm=l2 --cpu=0 --get-rip 2>&1 | head -1'"
_w "'sleep 3'"
_w "'echo RIPAGAI\"N\"'"
_w "'bhyvectl --vm=l2 --cpu=0 --get-rip 2>&1 | head -1'"
_w "'bhyvectl --vm=l2 --get-stats 2>&1 | grep -i \"total number of vm exits\"'"
_w "'fi'"
_w "'kill -9 \$p >/dev/null 2>&1'"
_w "'kill -9 \$(cat /tmp/catpid) >/dev/null 2>&1'"
_w "'i=\$((i+1))'"
_w "'done'"
_w "'bhyvectl --vm=l2 --destroy >/dev/null 2>&1'"
_w "'echo CYCLES\"RESULT\"=\$ok/\$i'"

mark=$(wc -l < "$CONS")
send 'sh /tmp/stress.sh'
wait_for 'CYCLESRESULT=' $((L2_CYCLES * 80 + 120)) "$mark" || {
	_last=$(tail -n +"$((mark + 1))" "$CONS" | grep -o 'STEP=[a-z]*:[0-9-]*' | tail -1)
	fail "the stress loop stopped after ${_last:-no step at all} (log: $CONS)"
}

_res=$(tail -n +"$((mark + 1))" "$CONS" | grep -o 'CYCLESRESULT=[0-9]*/[0-9]*' | tail -1)
_ok=${_res#CYCLESRESULT=}; _ok=${_ok%%/*}
_tried=${_res##*/}

[ -n "$_ok" ] && [ -n "$_tried" ] ||
    fail "could not read the cycle result off the console (log: $CONS)"
log "stress result: ${_ok}/${_tried} L2 boots seen"

# Re-read the tracer AFTER the cycles. The earlier check proved the value for
# one instant; this sysctl is host-global and nothing restores it, so a second
# invocation running concurrently on this host (the natural way to run "the
# other arm") can move it out from under a run that already validated it. The
# rate below would then be filed under an arm it did not run in.
_svm_end=$(sysctl -n hw.vmm.nested.svm_debug 2>/dev/null)
progress "svm_debug_end=${_svm_end:-n/a}"
if [ -n "${_svm_dbg}" ] && [ "${_svm_end:-}" != "${_svm_dbg}" ]; then
	fail "hw.vmm.nested.svm_debug changed under this run: ${_svm_dbg} at start, ${_svm_end:-unreadable} at end -- the ${_ok}/${_tried} result cannot be attributed to a tracer arm (another run on this host?)"
fi
log "tracer arm held: hw.vmm.nested.svm_debug=${_svm_end:-n/a}"
[ "$_tried" -eq "$L2_CYCLES" ] ||
    fail "loop attempted ${_tried} cycles, not ${L2_CYCLES} (log: $CONS)"
if [ "$_ok" -ne "$L2_CYCLES" ]; then
	# Capture L0's OWN view before failing. The guest-side probe says the
	# L2 vcpu is frozen; this says what L0 was doing about it. On the runs
	# so far the tail is a tight repeating pair of SVM IOIO exits (0x7b)
	# being reflected to L1 at two alternating L1 RIPs, over and over --
	# reflects are normal traffic, so it is the repetition WITHOUT progress
	# that is the signal. Recording it automatically rather than relying on
	# somebody thinking to look at dmesg afterwards, by which time the ring
	# buffer may have moved on.
	{
		echo "--- L0 svm_nested tail at failure ---"
		dmesg | grep svm_nested | tail -40
	} >> "$CONS" 2>&1
	fail "only ${_ok} of ${L2_CYCLES} L2 guests booted (log: $CONS)"
fi

log "PASS: ${L2_CYCLES} L2 guests executed inside one nested L1"
exit 0
