#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Run gen_release_manifest.py under whichever python3 this host has.
#
# FreeBSD's ports install python3.12 and python3.11 as those exact names and
# leave `python3` to a separately-installed symlink, so a `#!/usr/bin/env
# python3` shebang does not run on a build host -- and `command -v python3`
# returning nothing does not mean the host has no python. Probing is the
# difference between "no interpreter" and "no alias", and getting that wrong is
# how this generator was nearly written in printf.
set -eu

for _p in python3 python3.12 python3.11 python3.10; do
	if command -v "$_p" >/dev/null 2>&1; then
		exec "$_p" "$(dirname "$0")/gen_release_manifest.py" "$@"
	fi
done

echo "${0##*/}: needs python3 (tried python3, python3.12, python3.11, python3.10)" >&2
exit 2
