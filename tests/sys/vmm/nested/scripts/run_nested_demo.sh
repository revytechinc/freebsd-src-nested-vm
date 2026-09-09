#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# run_nested_demo.sh -- run the hands-on nested demo as a gate, from the copy
# installed on THIS host.
#
# The demo driver is a real program: it downloads a disk image, creates taps,
# bridges and md devices, and boots two guests as root. So the one thing this
# wrapper must never do is fetch a script over the network and run it. An
# earlier draft of this gate did exactly that -- `fetch` into a temporary
# directory, `grep -q nested` to decide it looked right, then `sh` it as root.
# Any response containing the word "nested" satisfies that check, so anyone who
# could answer for the site, or sit between us and it, had root on every host in
# the round. The word "published" in a claim is not worth a remote shell.
#
# The published copy is still checked, and that check has an owner: the
# `artifacts` gate compares the demo script the site serves against the copy on
# this host byte for byte, and fails on a difference. Drift is therefore caught
# by comparison rather than by execution, which is the whole trade -- we learn
# the same fact without ever running bytes that arrived over the wire.
#
# Running the installed copy is also the only way the demo works as designed:
# the driver resolves its banner and its launchers relative to $0, so a copy
# dropped in a temporary directory finds none of them.
#
# Usage:
#   run_nested_demo.sh [-d <path to nested-demo.sh>] [-- demo args...]
set -eu

PROGRAM="${0##*/}"

# Where the demo kit installs, then where the tests package puts its traceable
# copy. Order matters: the kit's copy sits beside the banner and the launchers
# it expects, and the tests copy is the fallback for a host that has the tests
# package but has not run install_demo_kit.sh.
DEFAULT_PATHS="/usr/local/libexec/cloudbsd-demo/nested-demo.sh
/usr/tests/sys/vmm/nested/demo/libexec/nested-demo.sh"

DEMO=""
while getopts d: o; do
	case "$o" in
	d) DEMO=$OPTARG ;;
	*) echo "usage: $PROGRAM [-d <path to nested-demo.sh>] [-- demo args...]" >&2
	   exit 2 ;;
	esac
done
shift $((OPTIND - 1))

# -d is a convenience for a person at a shell, and it is NOT a security
# boundary -- it names a script this then runs, so anyone who can pass it can
# run anything. That is fine here and only here: reaching this flag already
# requires being root on the host, which is strictly more than it grants.
#
# The gate that drives this over the network deliberately exposes no such
# parameter. It had one, briefly, and it turned the test service's unscoped
# bearer token into arbitrary root execution on every host in a round. The
# checks below are shape checks against a typo -- an argument that is not a
# path at all, or one with a ".." in it -- not a defence against a caller.
if [ -n "$DEMO" ]; then
	case "$DEMO" in
	/*) ;;
	*) echo "$PROGRAM: -d must be an absolute path: $DEMO" >&2; exit 2 ;;
	esac
	case "/$DEMO/" in
	*/../*) echo "$PROGRAM: -d has a '..' component: $DEMO" >&2; exit 2 ;;
	esac
else
	_saveIFS=$IFS
	IFS='
'
	for _p in $DEFAULT_PATHS; do
		IFS=$_saveIFS
		[ -f "$_p" ] && { DEMO=$_p; break; }
		IFS='
'
	done
	IFS=$_saveIFS
fi

if [ -z "$DEMO" ]; then
	echo "$PROGRAM: the nested demo is not installed on this host." >&2
	echo "$PROGRAM: looked in:" >&2
	printf '  %s\n' $DEFAULT_PATHS >&2
	echo "$PROGRAM: install the demo kit, or the CloudBSD-tests package, first." >&2
	# Distinct from the demo failing: nothing was learned about nesting here,
	# and reporting a missing harness as a nesting failure is how a fleet
	# round grows a defect that does not exist.
	exit 2
fi

[ -f "$DEMO" ] || { echo "$PROGRAM: no such file: $DEMO" >&2; exit 2; }
[ -r "$DEMO" ] || { echo "$PROGRAM: cannot read $DEMO" >&2; exit 2; }

# Record WHICH copy ran, by digest. A verdict that does not say what it tested
# cannot be compared with the next one, and this is the value the `artifacts`
# gate reports for the same file -- so the two logs can be lined up.
sha=$(sha256 -q "$DEMO" 2>/dev/null) || sha=""
# The pipeline's status is cut's, and cut succeeds on empty input, so a missing
# sha256sum leaves $sha empty rather than failing. The emptiness test below is
# what actually decides, which is why it is a test and not a `||`.
[ -n "$sha" ] || sha=$(sha256sum "$DEMO" 2>/dev/null | cut -d' ' -f1)

echo "$PROGRAM: running the installed demo"
echo "$PROGRAM:   path   $DEMO"
if [ -n "$sha" ]; then
	echo "$PROGRAM:   sha256 $sha"
	echo "$PROGRAM: the published copy is compared against this one by the artifacts gate."
else
	# Not fatal: whether this host nests is still worth knowing, and a
	# FreeBSD host always has sha256(1) in base, so this is the portability
	# tail rather than a case anyone meets. But it is said plainly, because
	# a verdict that cannot name what it tested cannot be lined up with the
	# artifacts gate's digest for the same file -- which is the entire
	# reason the digest is printed.
	echo "$PROGRAM:   sha256 UNAVAILABLE -- no sha256 or sha256sum on this host"
	echo "$PROGRAM: WARNING: this run's verdict cannot be tied to a known copy of"
	echo "$PROGRAM: the demo, so it cannot be compared with the artifacts gate."
fi
echo

# `sh "$DEMO"`, not exec of the file itself: the tests package has shipped
# these mode 0444 before, and an unreadable-by-exec script that is perfectly
# readable by an interpreter fails here for a reason that has nothing to do
# with nesting.
sh "$DEMO" "$@"
