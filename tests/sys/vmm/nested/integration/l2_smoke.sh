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
#   L2_CPUS      vCPUs for the L2 guest (default 1). Must not exceed L1_CPUS
#                -- bhyve inside L1 cannot use more CPUs than L1 has, and a
#                run that quietly tested a narrower guest than asked for is a
#                measurement about a guest nobody requested.
#   L1_TIMEOUT   seconds to wait for the L1 login prompt (default 300)
#   L2_TIMEOUT   seconds to wait for the L2 banner (default 120)
#   WORKDIR      scratch directory (default: mktemp -d)
#   SVM_DEBUG    hw.vmm.nested.svm_debug to run L0 with (default 1). The
#                tracer roughly doubles the observed L2 failure rate, so
#                every rate measured here must be reported with this value;
#                set 0 for the other arm. The run reads the sysctl back and
#                ABORTS if it is not what was asked for, since the rate would
#                otherwise be filed under the wrong arm. Despite the name the
#                OID is present on both vendors in this tree; where it is
#                genuinely absent (stock or older vmm) the arm is reported
#                as n/a rather than guessed.
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
# vCPUs for the L2 guest. Was hard-coded to 1 in both the single-shot and the
# stress paths, which is fine for "does an L2 run at all" but makes the width
# question unaskable -- and width claims are published. An L2 wider than L1 is
# refused rather than silently clamped: bhyve inside L1 cannot exceed the CPUs
# L1 itself was given, and a run that quietly tested 2 when asked for 8 is a
# measurement about a guest nobody requested.
: "${L2_CPUS:=1}"
# Memory for the L2 guest. Was hard-coded to 512M in four places -- the
# bhyveload and the bhyve of each of the two paths -- and bhyveload must get
# the same size as bhyve, or the loader lays the guest out for a different
# machine than the one it then runs on.
#
# Parameterised to test one hypothesis, and it has now been run: every captured
# nested-page-fault abort reported the SAME faulting GPA, 0x3ffff000, which is
# 1GB minus a page, in a guest that owns 512M.
#
# Result of four alternating 50-cycle runs, all with L1_MEM=4G and L1_CPUS=2
# (512M: 46,50 -- 1G: 30,43): at 1G
# the abort signature -- 0x3ffff000, an all-ones RIP, a bhyve SIGABRT and an
# instruction-emulation failure -- is absent from ALL 27 failures, while at
# 512M it is present. The other failure shape, in which bhyve stays alive and
# the guest freezes at or near btext, occurs in both arms. So the two shapes
# are two distinct bugs, not one event seen twice.
#
# The failure RATE difference between the arms is NOT established: the spread
# within the 1G arm (30 vs 43) exceeds the gap the comparison would rest on,
# and this measurement is roughly threefold overdispersed. Keep this knob for
# reproducing the split, not for quoting a rate.
: "${L2_MEM:=512M}"
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
# Snapshot L0's accumulated nested counters. Two sysctl reads, taken either
# side of the stress loop, so every run's log carries the host state it ran
# against.
#
# This exists because the run-to-run failure rate on this defect is
# OVERDISPERSED -- six identical 50-cycle runs gave 0 to 24%, about 3.4x the
# spread independent sampling allows (p about 0.004). Something differs
# between runs and nothing identifies what. Accumulated nested state is the
# obvious candidate and is free to read, so record it rather than guess later:
# a campaign can then correlate a bad run against the counters instead of
# theorising. Retrofitting it is impossible, which is the whole point.
# Both vendors' counters: svm_l2inj is SVM-side and reads all zeros on a VMX
# host, l2stats is the VMX-side equivalent. Emitting only the first made this
# useless on Intel, which is half the fleet -- and an all-zero line looks like
# "nothing happened" rather than "wrong counter for this CPU".
#
# Four states are kept APART rather than collapsed into one label. Discarding
# stderr and printing "<absent on this kernel>" for every empty read asserts a
# specific cause for four different ones -- a missing oid, a permission error,
# no sysctl(8) at all, and an oid that exists but printed nothing -- and a
# campaign correlating against these lines could not tell "this host has no
# counter" from "this harness could not read it". That is the same shape as a
# check that cannot fail: an answer-looking string covering a non-answer.
nested_counters()
{
	for _oid in svm_l2inj l2stats; do
		# stderr goes to its own file, NOT merged into $_v. Merging
		# on the success path folds any warning sysctl(8) prints into
		# the recorded counter value, so a campaign correlating these
		# lines would be parsing a warning as data.
		_e=0
		# Per-oid path, and truncated before each use. One shared
		# file, left behind by an earlier read, is a trap on the very
		# error path this function exists to keep honest: if the
		# redirect fails THIS time but the stale file is still
		# readable, the failure branch reports the PREVIOUS oid's
		# error under the current one's name.
		_err=$WORKDIR/.sysctl.${_oid}.err
		# If the scratch file cannot be truncated, fall back to
		# DISCARDING stderr -- never to a path outside WORKDIR.
		# Redirecting to /nonexistent was tried and is worse in both
		# directions: as root with a writable / the shell CREATES
		# that file and the harness litters the host root, and with /
		# unwritable the redirect fails before sysctl runs, losing a
		# counter value the read would have returned perfectly well.
		# Losing the reading to protect the error text inverts this
		# function's whole purpose.
		_errok=1
		if : > "$_err" 2>/dev/null; then
			_v=$(sysctl -n "hw.vmm.nested.${_oid}" 2>"$_err") || _e=$?
		else
			_errok=0
			_v=$(sysctl -n "hw.vmm.nested.${_oid}" 2>/dev/null) || _e=$?
		fi
		_v=$(printf '%s' "$_v" | tr '\n' ' ' | tr -s ' ')
		if [ "$_e" -ne 0 ]; then
			# The stderr file may not exist: if the redirect
			# itself failed -- unwritable or full scratch -- then
			# reading it here prints its own error and yields an
			# empty string, and the line below becomes
			# "<unreadable: >", which names nothing. This function
			# exists to name the observation, so name this one
			# too rather than emitting an empty accusation.
			# Keep the STATUS as well as the text. Exit 1, 2 and
			# 127 are different failures -- a refusal, a usage
			# error, and sysctl(8) not being there at all -- and
			# without the number they are told apart only by
			# whatever stderr happened to say, which may be
			# nothing.
			if [ "$_errok" = 1 ] && [ -r "$_err" ]; then
				_v=$(tr '\n' ' ' < "$_err" | tr -s ' ')
			else
				_v="stderr not captured (WORKDIR unwritable)"
			fi
			[ -n "$_v" ] || _v="no message"
			_v="rc=$_e: $_v"
			# ONLY the unknown-oid form is treated as absent, and
			# even then the label does NOT claim to know why. An
			# unloaded vmm.ko makes every hw.vmm.* oid unknown
			# exactly as a kernel built without the counter does,
			# and this function exists precisely to stop asserting
			# a cause it cannot distinguish -- so it names the
			# observation and lists the possibilities instead.
			# "unknown oid" here is ALWAYS a fault. Both nodes are
			# static sysctls in the one vmm.ko and register
			# whatever the CPU is, so the wrong-vendor counter
			# reads as zeros, NOT as unknown -- measured on an
			# Intel host, where svm_l2inj printed
			# "total=0 vmruns=0 ..." while l2stats printed real
			# values. An earlier version of this label offered
			# "the other vendor's counter" as the likely benign
			# cause, which would have taught the reader to skip
			# the one line that means something is wrong.
			case "$_v" in
			*"unknown oid"*)
				_v="<rc=$_e unknown oid: vmm not loaded, or a kernel without this counter -- NOT the wrong vendor, which reads as zeros>" ;;
			*)	_v="<unreadable: $_v>" ;;
			esac
		elif [ -z "$_v" ]; then
			_v="<present but empty>"
		fi
		# A warning that accompanies exit 0 must not vanish: dropping
		# it collapses "value" and "value, with sysctl complaining"
		# into the same line, which is the state-merging this function
		# exists to avoid -- just on the success path, where it is
		# easier to miss.
		if [ "$_e" -eq 0 ] && [ "$_errok" = 1 ] && [ -s "$_err" ]; then
			_v="$_v <warning: $(tr '\n' ' ' < "$_err" | tr -s ' ')>"
		fi
		# And say so when stderr was never captured at all. Without
		# this, a successful read whose warning was discarded prints
		# byte-identically to a clean read on a healthy host -- the
		# vanishing this function forbids three comments above,
		# reintroduced by its own fallback. The marker goes on
		# regardless of exit status: the point is that the line may be
		# incomplete, which is true whether the read worked or not.
		# Not on the failure branch, where the label already says it.
		if [ "$_errok" != 1 ] && [ "$_e" -eq 0 ]; then
			_v="$_v <stderr not captured: WORKDIR unwritable>"
		fi
		log "L0counters $1 $_oid: $_v"
	done
}

# Snapshot on EVERY exit path, not just the happy one.
#
# `nested_counters after' used to sit below the "could not read the cycle
# result" check, and that check calls fail(), which exits. So the run most
# likely to have been perturbed by accumulated host state -- the one whose
# loop wedged badly enough to produce no result line -- was the single run
# that recorded no "after" snapshot. The counters exist precisely to explain
# such runs. This does not register a trap of its own: it is CALLED from
# cleanup(), which is already trapped on EXIT and on INT/TERM further down, so
# every fail(), skip() and signal path reaches it. It is guarded so it cannot
# print twice or before the matching "before".
_counters_started=0
_counters_done=0
nested_counters_final()
{
	[ "$_counters_started" = 1 ] || return 0
	[ "$_counters_done" = 0 ] || return 0
	_counters_done=1
	nested_counters after
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
# Both, and separately: comparing against an unvalidated L1_CPUS reports
# "L2_CPUS=1 exceeds L1_CPUS=abc", which is false and sends the reader to
# raise a number that is not the problem. Malformed and too-wide are
# different faults and get different messages.
for _v in L1_CPUS L2_CPUS; do
	eval "_n=\$$_v"
	case "$_n" in
	''|*[!0-9]*|0*)	fail "$_v must be a positive integer, got '$_n'" ;;
	esac
done
# L2_MEM is spliced into a command line typed into L1, so a malformed value
# becomes a malformed bhyve invocation inside the guest, where the failure
# looks like a failed L2 boot and is TALLIED as one. That contaminates exactly
# the kind of comparison this knob exists for: an arm whose value is
# unusable scores as an arm whose nesting is broken. Refuse it here instead.
# Strip the unit first, then require what remains to be DIGITS ONLY. One case
# glob cannot express that: `[1-9]*[MmGg]' accepts "5X2M" -- [1-9] takes the 5,
# * takes the X2, [MmGg] takes the M -- and the arithmetic below then dies on
# `5X2'. A check that admits the value it exists to reject is worse than no
# check, because the caller believes it ran.
_size_ok()
{
	case "$1" in
	*[MmGg])	;;
	*)		return 1 ;;
	esac
	_n=${1%[MmGg]}
	[ -n "$_n" ] || return 1
	case "$_n" in
	*[!0-9]*)	return 1 ;;
	# A leading zero is OCTAL to both the shell's $(( )) and bhyve's
	# expand_number(3). "0512M" is not 512M, it is 330M, and the run
	# would quietly measure a guest nobody asked for. "08M" is not even
	# valid octal: $(( 08 )) is an arithmetic error, the command
	# substitution comes back empty, and the `-lt' below then fails with
	# the "does not fit inside L1_MEM" message -- a wrong diagnosis
	# produced by the check meant to prevent wrong diagnoses.
	0*)		return 1 ;;
	esac
	# Bound the magnitude before any arithmetic. A long digit string
	# overflows the shell's signed 64-bit $(( )) and wraps NEGATIVE, which
	# then passes the `-lt' fit check below -- an absurd size accepted by
	# the very test meant to reject it. Seven digits covers 9999999M, far
	# past any real L1.
	[ "${#_n}" -le 7 ] || return 1
	# Backstop. Given the checks above -- non-empty, all digits, no leading
	# zero -- $_n is at least 1 here, so this cannot currently reject
	# anything. It is kept anyway because it is dead by PRECEDING GUARD, not
	# dead by construction: relax any one of those three and this becomes
	# the only line still looking at the value. Drop the leading-zero case
	# and "0M" arrives here; drop the all-digits case and "4gM" does.
	# ("4g" would NOT -- the `g' is the unit and is stripped, leaving 4,
	# which is a valid 4 gigabytes. It takes a second unit letter to leave
	# a non-numeric behind.)
	#
	# It carried a 2>/dev/null once. That hid a DIAGNOSTIC, not a failure:
	# `[ 4g -gt 0 ]' exits 2 as well as complaining, so the rejection
	# happened either way. Dropped so that drift announces itself instead of
	# being turned away in silence.
	[ "$_n" -gt 0 ] || return 1
	return 0
}
# This is NARROWER than bhyve, deliberately. bhyve accepts a bare `-m 4096'
# (megabytes) and K/T suffixes; this harness requires an explicit M or G. The
# narrowing is the point: a bare number is the ambiguity that produced the
# octal bug above, and every value here is quoted into a log line that another
# reader has to interpret months later. Say so in the message so a caller who
# typed something bhyve would have taken is told why it was refused, rather
# than left thinking the check is broken.
#
# NOTE FOR L1_MEM SPECIFICALLY: that knob predates this check and was passed
# straight to bhyve, so this narrows an interface somebody may already be
# using -- `L1_MEM=4096' now fails where it once worked. Accepted as a
# deliberate break rather than an oversight: bhyve_in_bhyve.sh in this same
# directory already refuses its own size knob with "must be a bhyve size such
# as 4G", no in-tree caller passes a bare number, and the failure is a loud
# message at startup rather than a wrong measurement. If an out-of-tree caller
# turns up, widen _size_ok to accept a bare number as megabytes -- do not
# widen it to accept leading zeros.
_size_ok "${L2_MEM}" ||
    fail "L2_MEM must be a size with an explicit M or G suffix, like 512M or 1G, not '${L2_MEM}' (bhyve is more permissive; this harness is not, on purpose)"
_size_ok "${L1_MEM}" ||
    fail "L1_MEM must be a size with an explicit M or G suffix, like 4G, not '${L1_MEM}' (bhyve is more permissive; this harness is not, on purpose)"
# Same reasoning one level up: an L2 that cannot fit inside L1 fails at bhyve
# startup in the guest and is counted as a nesting failure. Compared in bytes
# because "1G" and "1024M" are the same size and string comparison says
# otherwise. L1 must also keep something for itself, so require strictly less.
_tob() {
	case "$1" in
	*[Mm])	echo $(( ${1%[Mm]} * 1024 * 1024 )) ;;
	*[Gg])	echo $(( ${1%[Gg]} * 1024 * 1024 * 1024 )) ;;
	esac
}
[ "$(_tob "${L2_MEM}")" -lt "$(_tob "${L1_MEM}")" ] ||
    fail "L2_MEM=${L2_MEM} does not fit inside L1_MEM=${L1_MEM}: bhyve inside L1 cannot give L2 as much memory as L1 itself has. Raise L1_MEM."

[ "${L2_CPUS}" -le "${L1_CPUS}" ] ||
    fail "L2_CPUS=${L2_CPUS} exceeds L1_CPUS=${L1_CPUS}: bhyve inside L1 cannot use more CPUs than L1 has. Raise L1_CPUS to at least ${L2_CPUS}."

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

	# Teardown is not interruptible. A second signal -- a second ^C, a
	# harness TERM arriving after an INT, or the HUP that ends a run whose
	# ssh session went away -- would otherwise fire the handler
	# again, and its `exit' would abort THIS cleanup part-way, before
	# bhyvectl --destroy. That abandons the VM this function exists to
	# reclaim, and the EXIT pass cannot repair it because the guard below
	# has already been set. Ignore both for the duration.
	trap '' INT TERM HUP

	# Signalled runs come through here and then again via EXIT. Without a
	# guard the second pass re-runs bhyvectl --destroy on a VM that is
	# already gone and re-logs the workdir line, which reads as if two runs
	# ended.
	[ -n "${_cleaned:-}" ] && return 0
	_cleaned=1

	# Before anything is torn down: the counters, on every exit path. See
	# nested_counters_final -- the run that dies here is the one whose
	# counters matter most, and it was the only run that used to lose them.
	nested_counters_final

	# A signal is not a clean finish, so keep the evidence regardless of
	# what $? happened to be when the signal landed.
	[ -n "${_sig:-}" ] && _rc=1

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
# INT and TERM get handlers that EXIT. A bare `trap cleanup INT TERM' runs
# cleanup and then RESUMES where the signal landed -- so a signalled run tore
# down its VM and carried on against nothing, reaching wait_for and reporting
# "L2 did not boot" for what was actually an operator ^C. Observed: a TERMed
# run kept its process alive with its VM already destroyed.
#
# 128+signo, the shell convention, so a caller can tell a signal from a real
# FAIL(1) or SKIP(77).
trap cleanup EXIT
trap '_sig=INT;  cleanup; exit 130' INT
trap '_sig=TERM; cleanup; exit 143' TERM
# HUP as well, and not as an afterthought: a long campaign is normally driven
# over ssh, so losing the terminal is the ordinary way one of these runs dies.
# Without this it exits on the default HUP action, cleanup never runs, and the
# run records no "after" counter snapshot -- the perturbed run being exactly
# the one the snapshot exists for.
trap '_sig=HUP;  cleanup; exit 129' HUP

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
# Armed HERE, before L1 is loaded, not down beside the stress loop.
#
# These sysctls are host-side and readable the moment the workdir exists, and
# siting the snapshot later meant every run that died in bhyveload, in the L1
# boot, or in the tracer check recorded NEITHER snapshot -- the guard in
# nested_counters_final turned into a silent no-op for exactly the runs whose
# accumulated host state is most worth having. "Every run's log carries the
# host state it ran against" is only true from this point.
# Geometry goes HERE, beside the counter snapshot and before L1 is loaded,
# for the same reason the snapshot was moved: sited after bhyveload, a run
# that died in bhyveload or the L1 boot recorded its counters but never said
# what geometry it was trying to run. An unattributable failure is the one
# most worth attributing.
#
# L1_MEM is named as well as L2_MEM: an L2_MEM comparison is only
# interpretable against the L1 it ran inside, and a reader correlating arms
# should not have to join two lines to find out.
log "L2 geometry: L2_CPUS=${L2_CPUS} L2_MEM=${L2_MEM} (inside L1_MEM=${L1_MEM})"
progress "l2=${L2_CPUS}cpu/${L2_MEM}"
nested_counters before
# Raised only once the "before" line is actually out. Set ahead of it, a
# signal landing inside that snapshot -- it forks sysctl twice -- would run
# cleanup and print an "after" against a missing or half-written "before",
# which is precisely what the guard is documented to prevent.
_counters_started=1

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
# Three states, not two, because an empty readback is not a mismatched arm.
#
# MEASURED, contrary to what the name suggests: hw.vmm.nested.svm_debug is
# present on BOTH vendors in this tree -- it reads 1 on freedev003 (vmx=1
# svm=0) exactly as on freedev010 (vmx=0 svm=1). So "absent" does NOT mean
# "a VMX host"; it means a kernel without the OID at all, such as stock
# vmm(4) or an older build. The branch below is kept for that case rather
# than for Intel, and it is written to distinguish it from a read that simply
# failed.
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
		# The OID is present on both vendors in this tree (measured),
		# so reaching here at all is unexpected and worth narrowing
		# rather than waving through. hw.vmm.nested.vmx also exists on
		# both -- 1 on Tiger Lake and Ivy Bridge, 0 on Zen+ -- so a
		# VMX host with no tracer OID is a plausible older/stock kernel
		# and is tolerated; anything else falls through to the fail.
		if [ "$(sysctl -n hw.vmm.nested.vmx 2>/dev/null)" = "1" ]; then
			log "L0 has no hw.vmm.nested.svm_debug OID (stock or older vmm; this tree has it on both vendors) -- tracer arm: n/a"
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
	send 'bhyveload -m '"$L2_MEM"' -h / -e console=comconsole -e autoboot_delay=1 l2 && echo ===L2"START"=== && bhyve -c '"$L2_CPUS"' -m '"$L2_MEM"' -A -H -P -s 0,hostbridge -s 31,lpc -l com1,stdio l2; echo ===L2"EXIT"=$?==='
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
_w "'bhyveload -m '"$L2_MEM"' -h / -e console=comconsole -e autoboot_delay=0 l2 >/tmp/l2load 2>&1'"
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
_w "'bhyve -c '"$L2_CPUS"' -m '"$L2_MEM"' -A -H -P -s 0,hostbridge -s 31,lpc -l com1,/dev/nmdm_l2\${i}A l2 >/tmp/l2err.\${i} 2>&1 &'"
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
# RIP stays IMMEDIATELY adjacent to the RIPAGAIN marker on BOTH sides, with
# RSP outside it. The established way to read this capture is
# `grep -B1 RIPAGAIN', and a reader doing the mirror-image thing takes the
# line after. Putting RSP next to the marker would hand one of them an RSP
# labelled as the RIP in their own notes -- a new field silently corrupting
# the existing measurement, which is worse than not adding it.
_w "'bhyvectl --vm=l2 --cpu=0 --get-rsp 2>&1 | head -1'"
_w "'bhyvectl --vm=l2 --cpu=0 --get-rip 2>&1 | head -1'"
_w "'sleep 3'"
_w "'echo RIPAGAI\"N\"'"
_w "'bhyvectl --vm=l2 --cpu=0 --get-rip 2>&1 | head -1'"
_w "'bhyvectl --vm=l2 --cpu=0 --get-rsp 2>&1 | head -1'"
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
	_tail=$(tail -n +"$((mark + 1))" "$CONS")
	_last=$(printf '%s\n' "$_tail" | grep -o 'STEP=[a-z]*:[0-9-]*' | tail -1)
	# Report the PARTIAL result, not just where it stopped. The markers
	# already carry it: one STEP=checked: per finished cycle, whose value is
	# the running count of successes. Without this an aborted run yields no
	# numbers at all, and a caller then either drops it -- losing real
	# launches -- or, worse, scores it 0-of-N and invents a failure rate.
	# A wedged run here that had completed six cycles successfully was
	# tallied by one such caller as 0/50, reporting 57% for a host measuring
	# nearer 10%.
	_done=$(printf '%s\n' "$_tail" | grep -c 'STEP=checked:')
	_boots=$(printf '%s\n' "$_tail" | grep -o 'STEP=checked:[0-9]*' | tail -1)
	_boots=${_boots#STEP=checked:}
	fail "the stress loop stopped after ${_last:-no step at all} -- completed ${_done} of ${L2_CYCLES} cycles, ${_boots:-0} L2 boots seen. This is a PARTIAL result: it is not ${L2_CYCLES} attempts, so do not score it as one (log: $CONS)"
}

_res=$(tail -n +"$((mark + 1))" "$CONS" | grep -o 'CYCLESRESULT=[0-9]*/[0-9]*' | tail -1)
_ok=${_res#CYCLESRESULT=}; _ok=${_ok%%/*}
_tried=${_res##*/}

[ -n "$_ok" ] && [ -n "$_tried" ] ||
    fail "could not read the cycle result off the console (log: $CONS)"
nested_counters_final
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
