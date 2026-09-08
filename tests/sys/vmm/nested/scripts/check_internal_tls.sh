#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# check_internal_tls.sh -- does an internal TLS service present a chain that a
# host holding only our root can actually validate, and for how much longer?
#
# Two failures this exists for, both of which have happened.
#
# A server configured with the LEAF ALONE works perfectly for anyone who
# already has the intermediate, and fails for everyone who has only the root --
# which is every host in the fleet, because the whole point of an intermediate
# is that rotating it must not mean touching every machine. The internal package
# repository shipped in exactly that state, and the proof that "it works" passed
# because the tester handed the client the full chain as its CA file. The client
# supplied the missing link and nobody noticed the server was not sending it.
#
# So the check here trusts ONLY the root, deliberately. Handing it the chain
# would reproduce the mistake it exists to catch.
#
# The second is expiry. Certificates issued for 90 days are the right choice --
# renewal has to be routine or it does not happen -- but only if something
# notices before the day. Nothing renews these yet, so this at least says how
# long is left, loudly, while there is still time to act.
#
# Usage:
#   check_internal_tls.sh -r <root.pem> [-H host[:port]] [-d days]
#
#   -r  the ROOT certificate only. Not the chain: see above.
#   -H  host[:port] to check, repeatable. Default pkg.internal.revytechinc.com.
#   -d  warn when fewer than this many days remain (default 21).
#
# Exit 0 only if every endpoint presented a chain validating against the root
# alone, and none is inside the warning window.

set -u

PROGRAM="${0##*/}"
ROOT=""
HOSTS=""
WARN_DAYS=21

while getopts r:H:d: o; do
	case "$o" in
	r)	ROOT=$OPTARG ;;
	H)	HOSTS="$HOSTS $OPTARG" ;;
	d)	WARN_DAYS=$OPTARG ;;
	*)	echo "usage: $PROGRAM -r <root.pem> [-H host[:port]] [-d days]" >&2
		exit 2 ;;
	esac
done
[ -n "$HOSTS" ] || HOSTS="pkg.internal.revytechinc.com:443"

log() { printf '%s: %s\n' "$PROGRAM" "$*"; }

[ -n "$ROOT" ] || { log "need -r <root certificate>"; exit 2; }
[ -f "$ROOT" ] || { log "no such file: $ROOT"; exit 2; }

# Refuse a chain file where a root was asked for. Passing the chain makes every
# check below succeed regardless of what the server sends, which is precisely
# the way the original defect hid.
_n=$(grep -c 'BEGIN CERTIFICATE' "$ROOT" 2>/dev/null || echo 0)
if [ "$_n" -ne 1 ]; then
	log "FAIL: $ROOT holds $_n certificates; this must be the ROOT ALONE."
	log "  A chain file would supply the intermediate the server is supposed to"
	log "  send, so the check would pass for a server that sends nothing."
	exit 2
fi
if ! openssl x509 -in "$ROOT" -noout -subject -issuer 2>/dev/null |
    awk -F'subject=|issuer=' 'NR==1{s=$2} NR==2{i=$2} END{exit !(s==i)}'; then
	log "FAIL: $ROOT is not self-signed, so it is not a root."
	exit 2
fi

fail=0
for hp in $HOSTS; do
	case "$hp" in
	*:*)	h=${hp%:*}; p=${hp##*:} ;;
	*)	h=$hp; p=443 ;;
	esac
	printf '\n== %s:%s\n' "$h" "$p"

	out=$(echo | openssl s_client -connect "$h:$p" -servername "$h" \
	    -CAfile "$ROOT" 2>/dev/null)
	if [ -z "$out" ]; then
		printf '   %s\n' "UNREACHABLE"
		fail=$((fail + 1))
		continue
	fi

	depth=$(printf '%s\n' "$out" | grep -cE '^ [0-9]+ s:')
	printf '   chain presented: %s certificate(s)\n' "$depth"
	printf '%s\n' "$out" | sed -n 's/^ \([0-9]\) s:\(.*\)/     \1 \2/p'

	verify=$(printf '%s\n' "$out" | sed -n 's/^ *Verify return code: //p' | tail -1)
	case "$verify" in
	"0 (ok)")
		printf '   verifies against the root alone: yes\n' ;;
	*)
		printf '   verifies against the root alone: NO -- %s\n' "$verify"
		if [ "$depth" -le 1 ]; then
			log "  The server is sending the leaf only. Concatenate the leaf"
			log "  and the intermediate into one file, leaf first, and point"
			log "  ssl_certificate at that. Do not fix this by shipping the"
			log "  intermediate to every host -- that is what the root is for."
		fi
		fail=$((fail + 1))
		continue ;;
	esac

	# Expiry, from the leaf the server actually sent.
	leaf=$(printf '%s\n' "$out" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' | head -100)
	end=$(printf '%s\n' "$leaf" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
	if [ -z "$end" ]; then
		printf '   expiry: could not read it\n'
		fail=$((fail + 1))
		continue
	fi
	end_s=$(date -j -f '%b %d %T %Y %Z' "$end" +%s 2>/dev/null ||
	        date -d "$end" +%s 2>/dev/null)
	if [ -z "$end_s" ]; then
		printf '   expiry: %s (could not convert to compare)\n' "$end"
		continue
	fi
	left=$(( (end_s - $(date +%s)) / 86400 ))
	printf '   expires: %s (%s days)\n' "$end" "$left"
	if [ "$left" -lt "$WARN_DAYS" ]; then
		log "  FEWER THAN $WARN_DAYS DAYS LEFT and nothing renews this yet."
		fail=$((fail + 1))
	fi
done

printf '\n'
if [ "$fail" -gt 0 ]; then
	log "FAIL: $fail endpoint(s) would not validate on a host holding only the root"
	exit 1
fi
log "PASS: every endpoint presents a chain a root-only host can validate"
exit 0
