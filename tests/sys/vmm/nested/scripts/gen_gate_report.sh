#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# gen_gate_report.sh -- collect what the release gates proved into one file.
#
# Usage:
#   gen_gate_report.sh -r <release> -v <version> -o <out.json> <gate-log>...
#
# Exits non-zero if any gate FAILED, so this can be the last step of a release
# run rather than something somebody reads afterwards.
set -eu

PROGRAM="${0##*/}"
SCRIPTDIR=$(cd "$(dirname "$0")" && pwd -P)

RELEASE=""; VERSION=""; OUT=""
while getopts r:v:o: o; do
	case "$o" in
	r) RELEASE=$OPTARG ;;
	v) VERSION=$OPTARG ;;
	o) OUT=$OPTARG ;;
	*) echo "usage: $PROGRAM -r <release> -v <version> -o <out.json> <log>..." >&2
	   exit 2 ;;
	esac
done
shift $((OPTIND - 1))

for _v in RELEASE VERSION OUT; do
	eval "_val=\${$_v:-}"
	[ -n "$_val" ] || { echo "$PROGRAM: -$(echo "$_v" | cut -c1 | tr 'A-Z' 'a-z') is required" >&2; exit 2; }
done
[ $# -gt 0 ] || { echo "$PROGRAM: no gate logs given" >&2; exit 2; }

# FreeBSD installs python3.12/3.11 and leaves python3 to a separate
# meta-package, so the interpreter is discovered rather than assumed.
PY=""
for _c in python3 python3.12 python3.11 python3.10; do
	if command -v "$_c" >/dev/null 2>&1; then PY=$_c; break; fi
done
[ -n "$PY" ] || { echo "$PROGRAM: no python3 found (tried python3 python3.12 python3.11 python3.10)" >&2; exit 1; }

exec "$PY" "$SCRIPTDIR/gen_gate_report.py" "$RELEASE" "$VERSION" "$OUT" "$@"
