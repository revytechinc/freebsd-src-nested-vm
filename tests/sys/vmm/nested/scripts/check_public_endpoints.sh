#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# check_public_endpoints.sh -- can a person actually reach what we publish, on
# every hostname we publish it under, over both address families?
#
# This exists because a user found the answer first. Running `pkg upgrade`
# against the published repository, their machine printed
#
#     SSL certificate subject does not match host nested.cloudbsd.cat
#
# four times and stopped. Nothing on our side had noticed, because nothing on
# our side was looking: the site was checked by opening it in a browser, from
# one machine, over whichever family that machine preferred.
#
# The same sweep found nested.cloudbsd.ca with no DNS record at all -- while a
# published release image had been configured to fetch its packages from it.
#
# So this checks, per hostname:
#
#   1. it resolves to BOTH an A and an AAAA record. Dual-stack is not optional
#      here, and this fleet has had hosts with no global IPv6 address at all.
#   2. it is reached through the proxy rather than the origin. A name resolving
#      straight to the origin publishes a fleet machine's address and skips the
#      edge that terminates TLS.
#   3. the certificate presented actually covers the name asked for -- over
#      each family separately, because they can be answered by different
#      machines.
#   4. fetch(1) retrieves the repository catalogue for EVERY release published
#      under that hostname, over each family -- not only `latest`. A person who
#      installed release2 keeps fetching release2, and an older directory that
#      has stopped being served fails for them alone, silently, while every
#      check aimed at `latest` passes. The list is read from the site rather
#      than typed here, so a release published tomorrow is covered without
#      anyone remembering to add it.
#
#      fetch, not curl: libfetch is what pkg(8) uses, and it is the thing that
#      rejected the certificate in the report above. curl succeeding proves
#      nothing about pkg.
#
# Usage:
#   check_public_endpoints.sh [-h host] [-p path]
#
#   -h  hostname to check, repeatable. Defaults to every name we publish under.
#   -r  release to check, repeatable. Default: every one the site lists.
#
# Run it on FreeBSD: it needs fetch(1), and testing with anything else tests
# something other than what our users run.

set -u

PROGRAM="${0##*/}"
HOSTS=""
ABI="${ABI:-FreeBSD:16:amd64}"
RELEASES=""

while getopts h:r: o; do
	case "$o" in
	h)	HOSTS="$HOSTS $OPTARG" ;;
	r)	RELEASES="$RELEASES $OPTARG" ;;
	*)	echo "usage: $PROGRAM [-h host] [-r release]" >&2; exit 2 ;;
	esac
done

[ -n "$HOSTS" ] || HOSTS="nested.cloudbsd.cat nested.cloudbsd.org nested.cloudbsd.ca"

command -v fetch >/dev/null 2>&1 || {
	echo "$PROGRAM: needs fetch(1); run this on FreeBSD, since fetch is what pkg uses" >&2
	exit 2
}
command -v openssl >/dev/null 2>&1 || { echo "$PROGRAM: needs openssl" >&2; exit 2; }
# Without host(1) every lookup below returns nothing and the run reports that
# no name resolves -- a gate failing for a reason that has nothing to do with
# what it measures, which is the worst way for one to break.
command -v host >/dev/null 2>&1 || { echo "$PROGRAM: needs host(1)" >&2; exit 2; }

# Cloudflare's published ranges start in these blocks. Enough to tell "behind
# the proxy" from "straight at a fleet machine", which is the distinction that
# matters; it is not an attempt to validate ownership of an address.
proxied_v4() {
	case "$1" in
	104.2[0-7].*|172.6[4-9].*|172.7[0-1].*|173.245.*|188.114.*|190.93.*|197.234.*|198.41.*|162.15[8-9].*|141.101.*|108.162.*)
		return 0 ;;
	esac
	return 1
}
proxied_v6() {
	case "$1" in
	2606:4700:*|2803:f800:*|2405:b500:*|2405:8100:*|2a06:98c0:*|2c0f:f248:*)
		return 0 ;;
	esac
	return 1
}

fail=0
note() { printf '     %s\n' "$*"; }

# Ask the site which releases it publishes. Typing the list here would go stale
# the next time one is published, and the check would then quietly stop
# covering the newest thing anybody installs.
# Sets $releases, and $discover_why when it comes back empty. Fetching the
# index and parsing it are different failures: reporting a parse miss as "the
# index is not being served" sends the reader to the web server, and coverage
# would silently drop to nothing the next time the index markup changes --
# which is the very thing reading the list from the site was meant to avoid.
discover_releases() {
	discover_why=""
	_idx=$(fetch -o - -T 20 "https://$1/pkgbase/${ABI}/" 2>/dev/null)
	if [ -z "$_idx" ]; then
		releases=""
		discover_why="the release index is not being served"
		return
	fi
	releases=$(printf '%s\n' "$_idx" |
	    sed -n 's/.*href="\([^"]*\)\/".*/\1/p' |
	    grep -v '^\.' | sort -u)
	if [ -z "$releases" ]; then
		discover_why="the index was served but nothing parsed out of it; the markup has changed and this script's parser needs updating"
	fi
}

for h in $HOSTS; do
	printf '\n== %s\n' "$h"

	v4=$(host -t A "$h" 2>/dev/null | sed -n 's/.* has address //p' | head -1)
	v6=$(host -t AAAA "$h" 2>/dev/null | sed -n 's/.* has IPv6 address //p' | head -1)

	if [ -z "$v4" ]; then
		note "A     : NONE -- the name does not resolve over IPv4"
		fail=$((fail + 1))
	elif proxied_v4 "$v4"; then
		note "A     : $v4 (proxied)"
	else
		note "A     : $v4 -- NOT the proxy; this exposes the origin directly"
		fail=$((fail + 1))
	fi

	if [ -z "$v6" ]; then
		note "AAAA  : NONE -- dual-stack is required and this name is v4 only"
		fail=$((fail + 1))
	elif proxied_v6 "$v6"; then
		note "AAAA  : $v6 (proxied)"
	else
		note "AAAA  : $v6 -- NOT the proxy; this exposes the origin directly"
		fail=$((fail + 1))
	fi

	# Per family. The two can be answered by different machines, so a
	# certificate proved good over one says nothing about the other.
	for fam in 4 6; do
		addr=$(eval echo "\$v${fam}")
		[ -n "$addr" ] || continue
		case "$fam" in
		4)	conn="${addr}:443" ;;
		6)	conn="[${addr}]:443" ;;
		esac
		san=$(echo | openssl s_client -connect "$conn" -servername "$h" \
		    2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null |
		    tr -d ' ' | tr ',' '\n' | sed -n 's/^DNS://p')
		if [ -z "$san" ]; then
			note "cert/v${fam}: could not read a certificate"
			fail=$((fail + 1))
			continue
		fi
		# Literal, then one-label wildcard -- which is what the certificates
		# in front of these names actually are, and what libfetch matches.
		hit=no
		suffix="${h#*.}"
		for n in $san; do
			if [ "$n" = "$h" ] || [ "$n" = "*.${suffix}" ]; then
				hit=yes
			fi
		done
		if [ "$hit" = yes ]; then
			note "cert/v${fam}: covers ${h}"
		else
			note "cert/v${fam}: DOES NOT COVER ${h} -- presents: $(echo $san | tr '\n' ' ')"
			note "           this is the error a user sees from pkg(8)."
			fail=$((fail + 1))
		fi
	done

	rels="$RELEASES"
	if [ -z "$rels" ]; then
		discover_releases "$h"
		rels="$releases"
		if [ -z "$rels" ]; then
			note "releases: none checked -- ${discover_why}"
			fail=$((fail + 1))
		fi
	fi

	for rel in $rels; do
		for fam in 4 6; do
			# ONCE, capturing both. Fetching again to find out why the first
			# attempt failed reports the SECOND attempt's output, so a
			# transient failure is printed next to a successful transfer --
			# which is what this did on its first real run, and it reads as a
			# bug in the check rather than a blip in the network.
			out=$(fetch -${fam} -o /dev/null -T 20 \
			    "https://${h}/pkgbase/${ABI}/${rel}/meta.conf" 2>&1)
			if [ $? -eq 0 ]; then
				note "$(printf '%-26s v%s: OK' "$rel" "$fam")"
			else
				note "$(printf '%-26s v%s: FAILED -- %s' "$rel" "$fam" \
				    "$(printf '%s' "$out" | tail -1)")"
				fail=$((fail + 1))
			fi
		done
	done
done

printf '\n'
if [ "$fail" -gt 0 ]; then
	echo "$PROGRAM: FAIL -- $fail problem(s); a user running pkg would hit these"
	exit 1
fi
echo "$PROGRAM: PASS -- every published hostname resolves dual-stack, sits behind"
echo "$PROGRAM: the proxy, presents a certificate covering itself, and serves"
echo "$PROGRAM: EVERY published release to fetch(1) over both families"
exit 0
