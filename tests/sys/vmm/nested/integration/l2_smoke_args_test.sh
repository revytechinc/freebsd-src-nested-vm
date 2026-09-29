#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Unit tests for l2_smoke.sh's argument validation.
#
# Scope, stated plainly so nobody mistakes this for coverage it is not: these
# exercise ONLY the checks that run before any privilege or hardware is
# needed. The sysctl readback, the abort-on-mismatch and the post-loop
# recheck cannot be reached without root and an L0 with vmm(4) loaded, so
# they are NOT tested here. A file named *_test.sh that quietly covers a
# tenth of the thing is how a gap starts looking like coverage.
#
# Both directions are exercised for every case. A validator tested only where
# it rejects is tested only in the half that cannot hurt anyone: the case that
# matters is that a LEGITIMATE value still runs, because a check that refuses
# everything gets switched off within a day.

set -eu

PROGRAM=${0##*/}
# Piped in via `sh -s' -- the diagnostic path that points SMOKE at an
# installed harness -- $0 is the shell, and a summary line reading "sh: 6
# passed" names nothing useful.
case "$PROGRAM" in
sh|-sh|dash|bash|ksh)	PROGRAM=l2_smoke_args_test.sh ;;
esac
SCRIPTDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SCRIPTDIR=.

# Overridable so this can be pointed at an INSTALLED l2_smoke.sh, which is how
# you check the test still goes red against a harness lacking the guard. The
# name is deliberately long: a bare SMOKE in the environment -- kyua scrubs no
# such variable -- would silently redirect the run at a different file.
L2_SMOKE_ARGS_TEST_SMOKE="${L2_SMOKE_ARGS_TEST_SMOKE:-$SCRIPTDIR/l2_smoke.sh}"
SMOKE=$L2_SMOKE_ARGS_TEST_SMOKE
[ -r "$SMOKE" ] || { echo "$PROGRAM: not readable: $SMOKE" >&2; exit 1; }

# Say WHICH harness was tested. Without this, "tested the committed harness"
# and "tested some other file that happened to be in the way" print the same
# summary -- and when SCRIPTDIR falls back to `.' (a failed cd, or `sh -s'
# where dirname gives `.'), the default resolves against the caller's cwd.
echo "$PROGRAM: harness under test: $SMOKE"

WORK=$(mktemp -d) || exit 1
# Every rm below is rooted here, so this is the one variable that must never
# be empty: an empty $WORK turns `rm -rf "$WORK/x"' into `rm -rf /x'.
case "$WORK" in
/*/*) ;;
*)	echo "$PROGRAM: refusing to run with WORK=$WORK" >&2; exit 1 ;;
esac
trap 'rm -rf "$WORK"' EXIT INT TERM

# Tallies live in files, not variables: a case that runs in a subshell would
# discard an incremented variable when the subshell exits, and the run would
# report a pass it never earned.
: > "$WORK/pass"
: > "$WORK/fail"

# Run l2_smoke.sh with a given environment and report its exit status and
# output. The script is invoked with sh explicitly so the test does not depend
# on the executable bit, and with L1_IMAGE unset so that any case reaching the
# prerequisite checks SKIPs (77) rather than touching hardware.
run_smoke()
{
	# -u both, or an ambient value makes "unset" cases assert a state they
	# never established -- and an ambient SVM_DEBUG_STRICT=2 would fail the
	# SVM_DEBUG cases with the wrong message entirely.
	#
	# BHYVE as well as an empty L1_IMAGE, because the isolation must not rest
	# on one prerequisite staying un-defaulted. L1_IMAGE= relies on the `-n`
	# check; if l2_smoke.sh ever gains `: "${L1_IMAGE:=...}"` -- the same
	# idiom it already uses for SVM_DEBUG -- the accepted cases would try a
	# real L1 boot under kyua, in a test advertised as needing no hardware.
	# A nonexistent bhyve cannot be defaulted away.
	env -u SVM_DEBUG -u SVM_DEBUG_STRICT "$@" \
	    L1_IMAGE= BHYVE=/nonexistent/bhyve BHYVELOAD=/nonexistent/bhyveload \
	    sh "$SMOKE" 2>&1
}

# expect <label> <wanted-status> <wanted-substring> <env>...
expect()
{
	_label=$1; _want=$2; _match=$3; shift 3
	# One invocation, capturing output and status together. `|| _rc=$?` is
	# what keeps `set -e` from killing the run on the cases that are supposed
	# to exit non-zero; an earlier draft used `|| true` inside the
	# substitution and then ran everything a second time to recover a status
	# it had just discarded.
	_rc=0
	_out=$(run_smoke "$@") || _rc=$?

	# A 77 must be a real SKIP, not any old 77: the accepted cases prove
	# validation let them through only if the script then stopped at a
	# prerequisite and said so.
	_ok=1
	[ "$_rc" = "$_want" ] || _ok=0
	if [ -n "$_match" ]; then
		case "$_out" in *"$_match"*) ;; *) _ok=0 ;; esac
	fi
	if [ "$_want" = 77 ]; then
		case "$_out" in *"SKIP:"*) ;; *) _ok=0 ;; esac
	fi

	if [ "$_ok" = 1 ]; then
		echo "ok   $_label (exit $_rc)"
		echo x >> "$WORK/pass"
	else
		echo "FAIL $_label: wanted exit $_want matching '$_match', got exit $_rc: $_out"
		echo x >> "$WORK/fail"
	fi
}

# --- rejected values -------------------------------------------------------
# Exit 1 is FAIL, which is what an unusable argument must produce. A SKIP (77)
# here would be wrong: the caller asked for something specific and cannot have
# it, and a skip reads as "not applicable" rather than "you typed it wrong".

expect "SVM_DEBUG=2 rejected"        1 "SVM_DEBUG must be 0 or 1" SVM_DEBUG=2
expect "SVM_DEBUG=yes rejected"      1 "SVM_DEBUG must be 0 or 1" SVM_DEBUG=yes
# '01' and ' 1' set the sysctl correctly but fail the later string comparison,
# aborting as a mismatch that never happened. Catching them here is the whole
# reason this validation exists.
expect "SVM_DEBUG=01 rejected"       1 "SVM_DEBUG must be 0 or 1" SVM_DEBUG=01
expect "SVM_DEBUG=' 1' rejected"     1 "SVM_DEBUG must be 0 or 1" "SVM_DEBUG= 1"
expect "SVM_DEBUG_STRICT=2 rejected" 1 "SVM_DEBUG_STRICT must be 0 or 1" SVM_DEBUG_STRICT=2
expect "L2_CPUS=0 rejected"          1 "L2_CPUS must be a positive integer" L2_CPUS=0
expect "L2_CPUS=two rejected"        1 "L2_CPUS must be a positive integer" L2_CPUS=two
expect "L2_CPUS=-1 rejected"         1 "L2_CPUS must be a positive integer" L2_CPUS=-1
# Wider than L1 is refused rather than clamped: a run that silently tested 2
# when asked for 8 would answer a question nobody put.
expect "L2_CPUS>L1_CPUS rejected"    1 "exceeds L1_CPUS" L2_CPUS=8 L1_CPUS=2
# A malformed L1_CPUS must say so, not blame L2_CPUS for exceeding it.
expect "L1_CPUS=abc rejected"        1 "L1_CPUS must be a positive integer" L1_CPUS=abc

# Memory sizes. These are spliced into a command line typed into L1, so a
# malformed value becomes a malformed bhyve invocation INSIDE the guest, where
# the failure is indistinguishable from a failed L2 boot and gets tallied as
# one. A rejection here is the difference between "you typed it wrong" and a
# contaminated measurement.
expect "L2_MEM=512 rejected (no unit)" 1 "L2_MEM must be a size" L2_MEM=512
expect "L2_MEM=big rejected"           1 "L2_MEM must be a size" L2_MEM=big
# The case that killed the first version of this check. `[1-9]*[MmGg]' looks
# like it validates a size and accepts this: [1-9] takes the 5, * takes the X2,
# [MmGg] takes the M. The value then reached shell arithmetic and died there,
# inside a run that had already been accepted.
expect "L2_MEM=5X2M rejected"          1 "L2_MEM must be a size" L2_MEM=5X2M
# Arithmetic smuggled through the size field. `2*1G' passes a first/last
# character check, evaluates to a plausible 2G in the fit test, and is then
# typed into L1 as `bhyveload -m 2*1G'.
expect "L2_MEM=2*1G rejected"          1 "L2_MEM must be a size" "L2_MEM=2*1G"
# A digit string long enough to wrap the shell's signed 64-bit arithmetic
# NEGATIVE, which would then pass the "fits inside L1" comparison.
expect "L2_MEM=99999999999999999999G rejected" 1 "L2_MEM must be a size" L2_MEM=99999999999999999999G
expect "L2_MEM=0M rejected"            1 "L2_MEM must be a size" L2_MEM=0M
# Leading zeros are OCTAL to both $(( )) and bhyve's expand_number(3).
# "0512M" is 330M, not 512M -- a run that silently measures a guest nobody
# asked for. "08M" is not valid octal at all and blows up mid-comparison,
# producing a "does not fit inside L1_MEM" misdiagnosis.
expect "L2_MEM=0512M rejected"         1 "L2_MEM must be a size" L2_MEM=0512M
expect "L2_MEM=08M rejected"           1 "L2_MEM must be a size" L2_MEM=08M
expect "L2_MEM='1 2M' rejected"        1 "L2_MEM must be a size" "L2_MEM=1 2M"
expect "L1_MEM=nonsense rejected"      1 "L1_MEM must be a size" L1_MEM=nonsense
# An L2 that cannot fit inside L1 fails at bhyve startup in the guest and is
# counted as a nesting failure -- the same contamination, one level up.
expect "L2_MEM>L1_MEM rejected"        1 "does not fit inside" L2_MEM=8G L1_MEM=4G
# Equal is refused too: L1 must keep something for itself.
expect "L2_MEM==L1_MEM rejected"       1 "does not fit inside" L2_MEM=4G L1_MEM=4G
# Compared in BYTES, not as strings: 1024M and 1G are the same size, and a
# string comparison would call one of these pairs wrong.
expect "L2_MEM=1024M vs L1_MEM=1G"     1 "does not fit inside" L2_MEM=1024M L1_MEM=1G

# --- accepted values -------------------------------------------------------
# These must get PAST validation. With L1_IMAGE unset the run then SKIPs (77)
# at the prerequisite checks -- which is the proof that validation let it
# through, since a rejected value exits 1 before ever reaching them.
#
# Note this is why validation is ordered ahead of the root check: as an
# unprivileged user the script skips at "must run as root", still 77, so the
# distinction between 1 and 77 remains meaningful either way.

expect "SVM_DEBUG=0 accepted"        77 "" SVM_DEBUG=0
expect "SVM_DEBUG=1 accepted"        77 "" SVM_DEBUG=1
expect "SVM_DEBUG unset accepted"    77 "" IGNORE=1
# An EMPTY value is accepted and means "use the default", because the script
# assigns with `: "${SVM_DEBUG:=1}"` and the `:=` form substitutes when the
# variable is unset OR empty. This case is here because the first draft of
# this file asserted the opposite and the test caught it: the expectation was
# wrong, not the code. Left as a case so the behaviour stays deliberate --
# switching to `:-` or `=` later would change it silently.
#
# Named for what it proves: empty is ACCEPTED. This case cannot see WHICH
# value was substituted, so a change from `:=1` to `:=0` passes here unnoticed
# -- it catches the form changing, not the default changing.
expect "SVM_DEBUG empty accepted"    77 "" SVM_DEBUG=
expect "SVM_DEBUG_STRICT=0 accepted" 77 "" SVM_DEBUG_STRICT=0
expect "SVM_DEBUG_STRICT=1 accepted" 77 "" SVM_DEBUG_STRICT=1
expect "L2_CPUS=1 accepted"          77 "" L2_CPUS=1
expect "L2_CPUS=4 with L1_CPUS=4"    77 "" L2_CPUS=4 L1_CPUS=4
expect "L2_MEM=1G inside L1_MEM=4G"  77 "" L2_MEM=1G L1_MEM=4G
expect "L2_MEM=512M accepted"        77 "" L2_MEM=512M
# Lower case units are a real thing people type.
expect "L2_MEM=512m accepted"        77 "" L2_MEM=512m
# The harness is NARROWER than bhyve on purpose: bhyve takes a bare `-m 4096'
# as megabytes and accepts K/T, this refuses them. A bare number is the
# ambiguity that makes 0512M an octal trap, and these values end up in logs a
# reader interprets later. Asserted so the narrowing stays deliberate -- if
# someone widens _size_ok, this case goes red and they have to mean it.
expect "L2_MEM=4096 rejected (no unit)" 1 "explicit M or G" L2_MEM=4096
expect "L2_MEM=1T rejected"          1 "explicit M or G" L2_MEM=1T
# EMPTY is accepted and means "use the default", because the script assigns
# with `: "${L2_MEM:=512M}"` and `:=` substitutes when unset OR empty. This
# case is here because the first draft of it asserted the opposite and the
# test caught it -- the same mistake this file already records for SVM_DEBUG,
# made again. Kept so that switching to `:-` or `=` cannot change the
# behaviour silently.
expect "L2_MEM empty accepted"       77 "" L2_MEM=
# 512M really is less than 1G once compared in bytes; as strings it is not.
expect "L2_MEM=512M inside L1_MEM=1G" 77 "" L2_MEM=512M L1_MEM=1G

# --- result ----------------------------------------------------------------
_p=$(wc -l < "$WORK/pass" | tr -d ' ')
_f=$(wc -l < "$WORK/fail" | tr -d ' ')
echo "$PROGRAM: $_p passed, $_f failed"
# A run that executed no cases at all must not report success: an empty tally
# and a clean tally are different states.
[ "$((_p + _f))" -gt 0 ] || { echo "$PROGRAM: no cases ran" >&2; exit 1; }
[ "$_f" -eq 0 ] || exit 1
exit 0
