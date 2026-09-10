#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# run_published_gates.sh -- run every gate that tests what we PUBLISHED, on a
# host, and give one verdict.
#
# These two gates are different in kind from the round in run_release_round.sh.
# That one boots an artifact we built and still have in our hands. These check
# the thing a stranger actually receives:
#
#   verify_stock_install.sh   a stock, unmodified FreeBSD follows the published
#                             instructions and comes up nesting -- run once per
#                             route, because the site publishes three of them
#                             and they are different instructions
#   verify_upgrade.sh         the release that was on the site yesterday moves
#                             to the one on it today
#   check_artifacts.sh        every copy of a shipped file agrees with the tree
#
# The last one runs first and cheaply. A release whose published demo script is
# older than the source tree will pass both of the other gates and still hand a
# reader something that does not work -- which is not hypothetical: the demo
# one-liner spent some time requiring a sysctl value that had stopped being
# reported, while the tree and most of the fleet were correct. Comparing the
# copies takes seconds and is the difference between finding that here and
# finding it when somebody runs it.
#
# Both must run AFTER publishing, because both fetch from the live site. That
# is what makes them worth having and also what makes them easy to forget --
# the round is over, the announcement is written, and the gate that would have
# caught the problem is the one nobody remembered to run. Both defects that
# made these gates necessary were found by hand, once, and would have shipped
# the next time. So they live in one script that runs them both.
#
# It does NOT stop at the first failure, for the same reason a round does not:
# an install fault and an upgrade fault are unrelated and will not both be
# found if the first one ends the run.
#
# Usage:
#   run_published_gates.sh [-p prev-image] [-P host:releases-dir] [gate ...]
#
#   -p  the previously published image: a local path, or a URL to fetch.
#       Skips the lookup below.
#   -P  where published releases live, as user@host:/path, so the previous
#       one can be found without it being typed in. Requires that this host
#       can reach that one, which is not true of every test host. No default:
#       this script ships in a public tree and must not name anyone's
#       infrastructure.
#   gate  one or more of: artifacts stock stock-manual stock-be upgrade
#         (default: all of them)
#
# The three stock gates share one working directory on purpose: they all start
# from the same verified FreeBSD image, and giving each its own would fetch and
# verify the same 700MB three times. Sharing is safe because no run can boot
# what a previous one left behind: the disk each gate boots is decompressed
# fresh from the manifest-checked archive under a name carrying that run's own
# pid, so a disk abandoned by an interrupted run is never picked up, only left
# taking up space. The word "stock" would mean nothing otherwise -- the second
# gate would be starting from a machine the first one had installed into.
#
# Exit 0 only if every gate that ran passed.

set -u

PROGRAM="${0##*/}"
HERE=$(dirname "$0")
PREV=""
PUBLISH=""
WORK=${WORK:-$HOME/published-gates}

while getopts p:P: o; do
	case "$o" in
	p)	PREV=$OPTARG ;;
	P)	PUBLISH=$OPTARG ;;
	*)	echo "usage: $PROGRAM [-p prev-image] [-P host:dir] [stock|upgrade ...]" >&2
		exit 2 ;;
	esac
done
shift $((OPTIND - 1))
GATES=${*:-"artifacts stock stock-manual stock-be upgrade"}

log() { printf '%s: %s\n' "$PROGRAM" "$*"; }

# stage_previous accepts a URL or a path and leaves a local file in PREV.
#
# A URL is the form that works everywhere. The ssh lookup below needs the test
# host to be able to reach the publishing host, which is not true of every
# machine in a fleet -- the first host this ran on could not resolve it. Once
# the previous release is served over HTTP the same way the current one is,
# this becomes automatic with no change here.
stage_previous() {
	case "$1" in
	http://*|https://*)
		log "fetching the previous release: $1"
		# Retried, because a single name-resolution blip has now cost
		# this gate three runs. It fails as `Transient resolver
		# failure' partway through a session in which the host is also
		# running bhyve guests, and a manual attempt a minute later
		# always succeeds -- so one attempt decides the gate on
		# something that has nothing to do with the release.
		#
		# Three tries with a growing pause, and the reason kept from
		# the last one. Still a hard failure if all three fail: an
		# unreachable previous release is a real answer, just not one
		# to conclude from a first attempt.
		_fetched=no
		_ferr="$WORK/prev-fetch.err"
		for _try in 1 2 3; do
			# Each attempt starts from nothing. A failed fetch can
			# leave a partial file, and a later attempt resuming
			# onto it would report success over a truncated image
			# -- which xz would then blame for being corrupt.
			rm -f "$WORK/prev-release.raw.xz"
			if fetch -o "$WORK/prev-release.raw.xz" "$1" 2>"$_ferr"; then
				_fetched=yes
				break
			fi
			# The first 120 CHARACTERS, not bytes. fetch puts the
			# cause at the start and progress after it, so the tail
			# is the half that says nothing about why -- but a
			# byte-boundary cut through a multi-byte character
			# leaves an invalid trailing byte in the log.
			#
			# The locale is set explicitly and is not decoration:
			# `cut -c' counts characters only in a multi-byte
			# locale, and under LC_ALL=C -- which is what a cron or
			# CI context usually hands a script -- it is byte
			# slicing again. Measured on a fleet host across a
			# two-byte character: head -c and LC_ALL=C cut -c both
			# emit a lone 0xC3; LC_ALL=C.UTF-8 cut -c keeps it
			# whole.
			#
			# A host without C.UTF-8 falls back to byte behaviour
			# silently. That costs a mangled tail on one log line
			# and never a wrong verdict, so it is not worth a
			# preflight.
			log "  attempt $_try failed: $(tr '\n' ' ' < "$_ferr" |
			    LC_ALL=C.UTF-8 cut -c1-120)"
			[ "$_try" = 3 ] || sleep $(( _try * 10 ))
		done
		if [ "$_fetched" = no ]; then
			log "could not fetch $1 in three attempts"
			return 1
		fi
		# Check what arrived, not whether the transfer succeeded. The
		# site is a single-page app behind a fallback, so a URL for a
		# file that is not there returns 200 with the index page --
		# and fetch(1) reports success. Tested here: a wrong URL
		# produced a 1.7KB HTML document saved as the release image,
		# and the run failed several minutes later complaining that xz
		# did not recognise the format, which blames decompression for
		# a download that never happened.
		if ! xz -t "$WORK/prev-release.raw.xz" 2>/dev/null; then
			log "what came back from $1 is not an xz image"
			log "  got: $(file -b "$WORK/prev-release.raw.xz" 2>/dev/null | cut -c1-60)"
			log "  a single-page site answers 200 for a file it does not have,"
			log "  so a successful fetch is not evidence the file exists"
			rm -f "$WORK/prev-release.raw.xz"
			return 1
		fi
		PREV="$WORK/prev-release.raw.xz"
		;;
	*)
		[ -f "$1" ] || { log "no such image: $1"; return 1; }
		PREV=$1
		;;
	esac
	return 0
}

[ "$(id -u)" -eq 0 ] || { log "need root"; exit 2; }
mkdir -p "$WORK"

# find_previous locates the last published image.
#
# The publishing side already keeps it: retiring a release moves it aside
# rather than deleting it, so the artifact the upgrade gate needs exists on
# every site that has ever published twice. It was simply never wired to
# anything, and was staged by hand the first time this gate ran -- which is
# exactly the "depends on remembering" problem this script exists to remove.
find_previous() {
	[ -n "$PUBLISH" ] || return 1
	_host=${PUBLISH%%:*}
	_dir=${PUBLISH#*:}
	# Newest retired directory, and the image inside it. Sorting by name
	# works because the timestamp is in the name; sorting by mtime would
	# pick whichever was touched last, which is not the same thing.
	#
	# The exit status of the remote pipeline is tail's, which is 0 even when
	# ls found nothing, so emptiness is what is checked rather than status.
	# Remote paths are quoted where they are re-used: whatever came back is
	# a string from another machine, and it goes into a second command.
	_rel=$(ssh -4 -o BatchMode=yes "$_host" \
	    "ls -d '$_dir'/.retired-* 2>/dev/null | sort | tail -1")
	[ -n "$_rel" ] || { log "no retired release found under $_dir"; return 1; }
	_img=$(ssh -4 -o BatchMode=yes "$_host" \
	    "ls '$_rel'/*.raw.xz 2>/dev/null | head -1")
	[ -n "$_img" ] || { log "no image inside $_rel"; return 1; }
	log "previous release: $_img"
	scp -4 -q "$_host:$_img" "$WORK/prev-release.raw.xz" || return 1
	PREV="$WORK/prev-release.raw.xz"
	return 0
}

run_gate() {
	_name=$1; shift
	_log="$WORK/$_name.log"
	log "running the $_name gate"
	if sh "$@" > "$_log" 2>&1; then
		log "$_name: PASS"
		return 0
	fi
	log "$_name: FAIL"
	return 1
}

# One published install route, run by name.
#
# The route is passed to the script's environment for that command only, so no
# gate leaves INSTALL_METHOD set behind it -- neither for the gates that follow
# nor for whatever the operator had in their own environment. All three share
# WORK/stock; see the note above for why that is safe.
run_stock_gate() {
	_gate=$1
	_method=$2
	_glog="$WORK/$_gate.log"
	log "running the $_gate gate (the $_method route)"
	if env INSTALL_METHOD="$_method" sh "$HERE/verify_stock_install.sh" \
	    "$WORK/stock" > "$_glog" 2>&1; then
		log "$_gate: PASS"
		return 0
	fi
	log "$_gate: FAIL"
	return 1
}

FAILED=""
RAN=""

# Clear the logs of the gates about to run. Nothing else prunes WORK, and a
# summary line that points at a log left over from a previous run reads exactly
# like a fresh result.
for g in $GATES; do
	rm -f "$WORK/$g.log"
done

for g in $GATES; do
	case "$g" in
	artifacts)
		RAN="$RAN artifacts"
		# Fast, and first: no point proving an installer works if the
		# script beside it on the site is a different one from the tree.
		if [ -n "${ARTIFACT_HOSTS:-}" ]; then
			set -- -H "$ARTIFACT_HOSTS"
		else
			set --
		fi
		run_gate artifacts "$HERE/check_artifacts.sh" \
		    -u "${SITE_URL:-https://nested.cloudbsd.cat}" "$@" ||
		    FAILED="$FAILED artifacts"
		;;
	# One gate per published route. They are not three phrasings of one
	# instruction: the installer script, the numbered steps and the boot
	# environment install by different mechanisms and fail in different
	# ways, and each of the three has already been published broken at some
	# point while the others worked.
	#
	# The route is named explicitly for every one of them, the installer
	# route included. Leaving that one to verify_stock_install.sh's default
	# would let an INSTALL_METHOD inherited from the environment silently
	# decide which route the gate called "stock" actually ran, and the
	# summary would name a route that was never taken.
	stock)
		RAN="$RAN stock"
		run_stock_gate stock installer || FAILED="$FAILED stock"
		;;
	stock-manual)
		RAN="$RAN stock-manual"
		run_stock_gate stock-manual manual || FAILED="$FAILED stock-manual"
		;;
	# This one also tests the promise the route makes -- that a kernel which
	# does not come up reverts by itself -- so it reboots the guest four
	# times and takes correspondingly longer than the other two.
	stock-be)
		RAN="$RAN stock-be"
		run_stock_gate stock-be be || FAILED="$FAILED stock-be"
		;;
	upgrade)
		# An explicit -p that cannot be staged is a failure, never a
		# reason to go looking for something else. Falling back to
		# discovery there would test a different image than the one the
		# operator named and report it as a pass for the one they asked
		# for -- the worst outcome available to a gate.
		if [ -n "$PREV" ] && ! stage_previous "$PREV"; then
			{
				echo "CANNOT RUN: the image given with -p could not be used."
				echo
				echo "It was named explicitly, so no other image is substituted:"
				echo "a pass reported against a different artifact than the one"
				echo "asked for is worse than no result at all."
			} > "$WORK/upgrade.log"
			log "upgrade: CANNOT RUN -- -p could not be staged"
			FAILED="$FAILED upgrade"
			RAN="$RAN upgrade"
			continue
		fi
		if [ -z "$PREV" ] && ! find_previous; then
			# Not a pass and not a silent skip: a gate that cannot
			# find its input has not tested anything, and saying so
			# is the difference between a known gap and a false
			# clean run.
			# Write the reason where the summary looks for it. A
			# findings section that points at a log which was never
			# created prints an empty finding, which reads as though
			# the tool broke rather than as a gate that had nothing
			# to test.
			{
				echo "CANNOT RUN: no previous published image was found."
				echo
				echo "This gate starts from the artifact that was genuinely on"
				echo "the site before this release. Without it there is nothing"
				echo "to upgrade FROM, and a fresh install of the new build is"
				echo "not a substitute -- it tests a different code path and a"
				echo "population that does not exist."
				echo
				echo "Give the image with -p <file>, or say where published"
				echo "releases live with -P user@host:/path so it can be found."
			} > "$WORK/upgrade.log"
			log "upgrade: CANNOT RUN -- no previous image (see $WORK/upgrade.log)"
			FAILED="$FAILED upgrade"
			RAN="$RAN upgrade"
			continue
		fi
		RAN="$RAN upgrade"
		run_gate upgrade "$HERE/verify_upgrade.sh" "$PREV" "$WORK/upgrade" ||
		    FAILED="$FAILED upgrade"
		;;
	*)	log "unknown gate: $g"
		log "expected: artifacts stock stock-manual stock-be upgrade"
		exit 2 ;;
	esac
done

echo
echo "================ published gates on $(hostname -s) ================"
for g in $RAN; do
	case " $FAILED " in
	*" $g "*) printf "  %-13s FAIL   %s\n" "$g" "$WORK/$g.log" ;;
	*)        printf "  %-13s PASS   %s\n" "$g" "$WORK/$g.log" ;;
	esac
done

if [ -n "$FAILED" ]; then
	echo
	echo "FINDINGS -- all of them, so they can be fixed as one batch:"
	for g in $FAILED; do
		echo "  --- $g"
		tail -12 "$WORK/$g.log" 2>/dev/null | sed 's/^/      /'
	done
	exit 1
fi
echo
echo "everything we tell people to do was done, and worked"
exit 0
