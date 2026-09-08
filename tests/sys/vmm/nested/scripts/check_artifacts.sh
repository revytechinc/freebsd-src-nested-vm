#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# check_artifacts.sh -- one artifact, several homes, one checksum.
#
# Several things in this project exist in more than one place at once. A demo
# script lives in this tree, is installed onto hosts by a package, and is served
# from the website for people to fetch and run. The hypervisor module is built
# here, installed into /boot/kernel there, and quoted by checksum in published
# results. Each copy is written by a different process at a different time, so
# they drift -- not as an accident but as the default behaviour of the
# arrangement.
#
# Drift of this kind is quiet. The copy that is wrong is usually the one nobody
# runs day to day, which means it is discovered by whoever trusted it: on this
# project, the published nested-demo.sh required a sysctl to read a value it had
# stopped reporting, so the one-liner on the demo page told a nested-capable
# machine it was not nested-capable and stopped. The source tree and the fleet
# had been right for some time. Only the copy people were told to fetch was
# wrong, and nothing compared them.
#
# So this compares them, deliberately, on demand -- rather than each mismatch
# being found again by somebody it inconveniences.
#
# Usage:
#   check_artifacts.sh [-s srctree] [-u base-url] [-l] [-H "host host ..."]
#
#   -s  source tree to treat as authoritative (default: derived from $0)
#   -u  site base URL to check published copies against
#   -l  check the copies installed on THIS machine, without ssh
#   -H  space-separated hosts to check installed copies on, over ssh
#
# Prefer -l. The -H form is a loop over hostnames inside a script, and it has
# the failure this kind of loop always has: a host that is down is skipped, and
# the run reports green for a machine it never asked. Run this on each host
# instead -- the cloudbsd-test agent does exactly that, and its fan-out reports
# an unreachable machine as a result rather than as an omission. -H remains for
# a workstation with no agent, and for the cross-fleet vmm.ko comparison, which
# genuinely cannot be answered from one machine.
#
# With no -u, no -l and no -H it checks what it can reach and says what it
# skipped. Exit 0 only if every copy of every artifact that could be read
# agreed, and nothing that was asked for was missing.

set -u

PROGRAM="${0##*/}"
HERE=$(cd "$(dirname "$0")" && pwd)
SRCTREE=${SRCTREE:-$(cd "$HERE/../../../../.." 2>/dev/null && pwd)}
BASEURL=${BASEURL:-}
HOSTS=${HOSTS:-}
LOCAL=${LOCAL:-no}
SSH="ssh -4 -o BatchMode=yes -o ConnectTimeout=15"

while getopts s:u:lH: o; do
	case "$o" in
	s)	SRCTREE=$OPTARG ;;
	u)	BASEURL=$OPTARG ;;
	l)	LOCAL=yes ;;
	H)	HOSTS=$OPTARG ;;
	*)	echo "usage: $PROGRAM [-s srctree] [-u base-url] [-l] [-H \"host ...\"]" >&2
		exit 2 ;;
	esac
done

log()  { printf '%s: %s\n' "$PROGRAM" "$*"; }
# What to call this machine in the output. Computed once: it is printed on
# every local line, and a name that changes mid-report reads as two machines.
SELF=$(hostname -s 2>/dev/null) || SELF=""
[ -n "$SELF" ] || SELF="this host"
fail=0
checked=0
skipped=0
# Which kinds of copy went unchecked. A bare count tells a reader that
# something was skipped without telling them what, which is the half of the
# message that would let them fix it.
# One kind per line: every entry contains spaces, so a space-separated list
# cannot be walked back apart afterwards.
skipped_kinds=""

note_skip() {
	skipped=$((skipped + 1))
	case "
$skipped_kinds
" in
	*"
$1
"*)	return ;;
	esac
	skipped_kinds="${skipped_kinds}${skipped_kinds:+
}$1"
}

# sha of a local file, or empty. Empty is never treated as a match: two unread
# files must not agree with each other, which is the failure mode a naive
# comparison has and the one that would make this whole script decorative.
sum_local() {
	[ -f "$1" ] || return 1
	_s=$(sha256 -q "$1" 2>/dev/null)
	is_sum "$_s" || _s=$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)
	is_sum "$_s" || return 1
	printf '%s\n' "$_s"
}

sum_url() {
	_tmp=$(mktemp) || return 1
	# The cache-buster goes on BOTH paths. It was on the curl attempt only,
	# which meant that on a host without curl -- a stock FreeBSD, which is
	# exactly what this ships to -- the fallback fetched the bare URL and a
	# stale cached copy could be hashed and reported as agreeing with the
	# tree. A drift checker that passes on a cached answer is worse than no
	# checker, because it is trusted.
	_bust="$1?cb=$$-$(date +%s 2>/dev/null || echo 0)"
	# -f so an HTTP error is a failure. Without it a 404 body would be
	# hashed and compared, and this site answers 200 with its index page for
	# a file it does not have.
	if ! curl -fsS -o "$_tmp" "$_bust" 2>/dev/null &&
	   ! fetch -qo "$_tmp" "$_bust" 2>/dev/null; then
		rm -f "$_tmp"
		return 1
	fi
	sum_local "$_tmp"
	_rc=$?
	rm -f "$_tmp"
	return $_rc
}

# is_sum accepts only a full sha256: 64 hex digits and nothing else.
#
# The looser test this replaces accepted anything beginning with a hex digit,
# so a stray line of remote output starting "a..." would have been compared as
# though it were a hash. That does not error -- it returns a wrong verdict,
# which is the one outcome this script must not produce.
is_sum() {
	case "$1" in
	*[!0-9a-f]*)	return 1 ;;
	esac
	[ ${#1} -eq 64 ]
}

sum_host() {
	_h=$1; _p=$2
	# Take the last line: a login banner or a doas notice ahead of the
	# checksum would otherwise be what gets compared.
	_s=$($SSH "$_h" "sha256 -q \"$_p\" 2>/dev/null" 2>/dev/null |
	    tr -d '\r' | tail -1)
	is_sum "$_s" || return 1
	printf '%s\n' "$_s"
}

# compare NAME SOURCE-PATH [where=value ...]
#
# The first argument after the name is the copy everything else is measured
# against. Naming one authoritative copy is the point: "these two differ" is a
# question, "the website disagrees with the tree" is an answer.
compare() {
	_name=$1; _src=$2; shift 2
	printf '\n== %s\n' "$_name"

	# Prefer the source tree as the reference. Where there is no tree -- on a
	# fleet host, or from an installed tests package -- fall back to what the
	# site actually serves. That is a weaker authority, because it cannot say
	# whether the published copy itself is current, but it answers the
	# question a host can usefully ask: does what is installed here match what
	# people are being handed? Refusing to run at all in that situation would
	# mean the check only ever works in one place, which is how a check ends
	# up not being run.
	_reftag="source tree"
	_want=$(sum_local "$_src") || _want=""
	if [ -z "$_want" ]; then
		_urlspec=""
		for _s in "$@"; do
			case "$_s" in url=*) _urlspec=${_s#url=} ;; esac
		done
		if [ -n "$BASEURL" ] && [ -n "$_urlspec" ]; then
			_want=$(sum_url "$BASEURL/$_urlspec") || _want=""
			_reftag="published copy"
			_src="$BASEURL/$_urlspec"
		fi
	fi
	if [ -z "$_want" ]; then
		log "$_name: no reference available."
		log "  Looked for a source tree at: $_src"
		log "  Pass -s <srctree>, or -u <base-url> to compare against what is published."
		fail=$((fail + 1))
		return
	fi
	printf '   %-46s %s  (%s)\n' "$(basename "$_src")" "$(echo "$_want" | cut -c1-16)" "$_reftag"

	for spec in "$@"; do
		_where=${spec%%=*}
		_loc=${spec#*=}
		case "$_where" in
		url)
			[ -n "$BASEURL" ] || { note_skip "the published copies (-u)"; continue; }
			# It is the yardstick in fallback mode; measuring it
			# against itself would report a reassuring "ok" that
			# means nothing.
			[ "$_reftag" = "published copy" ] && continue
			checked=$((checked + 1))
			_got=$(sum_url "$BASEURL/$_loc") || {
				printf '   %-46s %s\n' "$BASEURL/$_loc" "UNREADABLE"
				fail=$((fail + 1)); continue
			}
			_label="$BASEURL/$_loc"
			;;
		host)
			# The copy installed on THIS machine, read directly.
			#
			# This is the case that matters now: every host runs this for
			# itself and the answers are collected by whatever asked them
			# all. The ssh loop below cannot report a machine that did not
			# answer -- it just has one fewer line -- which is how a check
			# comes to pass for a host it never reached.
			if [ "$LOCAL" = yes ]; then
				checked=$((checked + 1))
				if _got=$(sum_local "$_loc"); then
					if [ "$_got" = "$_want" ]; then
						printf '   %-46s %s  ok\n' \
						    "$SELF:$(basename "$_loc")" "$(echo "$_got" | cut -c1-16)"
					else
						printf '   %-46s %s  DIFFERS\n' \
						    "$SELF:$(basename "$_loc")" "$(echo "$_got" | cut -c1-16)"
						fail=$((fail + 1))
					fi
				else
					printf '   %-46s %s\n' "$SELF:$_loc" "UNREADABLE"
					fail=$((fail + 1))
				fi
			fi
			if [ -z "$HOSTS" ]; then
				[ "$LOCAL" = yes ] || note_skip "the installed copies (-l or -H)"
				continue
			fi
			for _h in $HOSTS; do
				checked=$((checked + 1))
				_got=$(sum_host "$_h" "$_loc") || {
					printf '   %-46s %s\n' "$_h:$_loc" "UNREADABLE"
					fail=$((fail + 1)); continue
				}
				if [ "$_got" = "$_want" ]; then
					printf '   %-46s %s  ok\n' "$_h:$(basename "$_loc")" "$(echo "$_got" | cut -c1-16)"
				else
					printf '   %-46s %s  DIFFERS\n' "$_h:$(basename "$_loc")" "$(echo "$_got" | cut -c1-16)"
					fail=$((fail + 1))
				fi
			done
			continue
			;;
		*)
			log "unknown location kind: $_where"
			fail=$((fail + 1)); continue
			;;
		esac
		if [ "$_got" = "$_want" ]; then
			printf '   %-46s %s  ok\n' "$_label" "$(echo "$_got" | cut -c1-16)"
		else
			printf '   %-46s %s  DIFFERS\n' "$_label" "$(echo "$_got" | cut -c1-16)"
			fail=$((fail + 1))
		fi
	done
}

# ---- the artifacts ---------------------------------------------------------
#
# Add an entry here when something starts existing in more than one place. That
# is the whole maintenance burden, and it is the step that was missing before.

compare "nested-demo.sh (the demo one-liner fetches this)" \
	"$SRCTREE/tests/sys/vmm/nested/demo/libexec/nested-demo.sh" \
	"url=nested-demo.sh" \
	"host=/usr/local/libexec/cloudbsd-demo/nested-demo.sh"

# vmm.ko has no copy in the tree -- it is built -- so the fleet is compared
# against itself: every host in a matrix run must carry the same module or the
# numbers from them cannot be compared. The first host given is the reference.
if [ -n "$HOSTS" ]; then
	printf '\n== vmm.ko across the fleet\n'
	_ref=""; _refhost=""
	for _h in $HOSTS; do
		checked=$((checked + 1))
		_s=$(sum_host "$_h" /boot/kernel/vmm.ko) || {
			printf '   %-46s %s\n' "$_h:/boot/kernel/vmm.ko" "UNREADABLE"
			fail=$((fail + 1)); continue
		}
		if [ -z "$_ref" ]; then
			_ref=$_s; _refhost=$_h
			printf '   %-46s %s  (reference)\n' "$_h" "$(echo "$_s" | cut -c1-16)"
			continue
		fi
		if [ "$_s" = "$_ref" ]; then
			printf '   %-46s %s  ok\n' "$_h" "$(echo "$_s" | cut -c1-16)"
		else
			printf '   %-46s %s  DIFFERS from %s\n' "$_h" "$(echo "$_s" | cut -c1-16)" "$_refhost"
			fail=$((fail + 1))
		fi
	done
elif [ "$LOCAL" = yes ]; then
	# One machine cannot compare a fleet. Report what this host is running
	# and leave the comparison to whoever collected the answers -- which is
	# where it belongs, because that is the only place that knows which
	# machines were asked and which never replied.
	printf '\n== vmm.ko on this host\n'
	_s=$(sum_local /boot/kernel/vmm.ko) || _s=""
	if [ -n "$_s" ]; then
		printf '   %-46s %s  (reported, not compared)\n' "$SELF" "$(echo "$_s" | cut -c1-16)"
	else
		# Not merely noted. A test host that cannot read its own hypervisor
		# module is not running the build anything here claims to measure,
		# and letting the run exit 0 on the strength of the other checks is
		# how that goes unnoticed.
		printf '   %-46s %s\n' "$SELF:/boot/kernel/vmm.ko" "UNREADABLE"
		checked=$((checked + 1))
		fail=$((fail + 1))
	fi
else
	note_skip "vmm.ko across the fleet (-H, or one run per host)"
fi

printf '\n'
if [ "$skipped" -gt 0 ]; then
	log "$skipped check(s) skipped, namely:"
	printf '%s\n' "$skipped_kinds" | sed "s|^|$PROGRAM:   |"
fi
if [ "$fail" -gt 0 ]; then
	log "FAIL: $fail of $checked copies disagree or could not be read"
	log "The copy to trust is the source tree. Re-publish or re-install the others"
	log "rather than editing them in place, or they will differ again tomorrow."
	exit 1
fi
# Checking nothing is not passing. Without -u or -H there is no second copy to
# compare against, so the run has established only that the tree can be read --
# and reporting that as PASS is exactly the false assurance this script exists
# to remove from everything else.
if [ "$checked" -eq 0 ]; then
	log "NOTHING CHECKED: no second copy of anything was compared."
	log "  Pass -u <base-url> for the published copies, -l for the ones installed"
	log "  here, -H \"host ...\" for the ones on other machines, or several."
	log "  Refusing to report a pass for no comparison."
	exit 2
fi
log "PASS: $checked copies checked, all agree"
exit 0
