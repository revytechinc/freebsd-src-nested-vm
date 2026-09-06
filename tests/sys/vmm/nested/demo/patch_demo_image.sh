#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Teach an already-built demo image to size its nested L2 guest from the kernel
# environment.
#
# The L1 side of the automatic demo lives in the image's own /etc/rc.local, and
# it booted the L2 guest with a hardcoded "-c 1".  That made the vCPU count a
# property of a 2.7 GB disk image rather than of the run, so asking for a wider
# guest meant rebuilding and redistributing the image to every host.  Reading
# the count from kenv(1) instead lets the host-side driver pass it down at boot
# through bhyveload's -e, which costs nothing and changes no default: an image
# patched this way still boots a single-vCPU L2 when nobody asks for more.
#
# Patching in place beats rebuilding here because the change is four lines in
# one file; the image itself is unchanged in every other respect, so a host
# that has already verified its copy does not have to re-verify a new one.
#
# Usage: doas sh patch_demo_image.sh [/path/to/nested-demo.raw]
set -eu

IMG=${1:-/usr/local/share/cloudbsd-demo/auto/nested-demo.raw}

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }

MNT=$(mktemp -d /tmp/demoimg.XXXXXX)
MD=""
# Detach failures are reported rather than swallowed.  A silent failure here
# leaks an md(4) unit and a mountpoint on every run, and since this script is
# meant to be safe to repeat, a host would quietly accumulate them until
# mdconfig ran out of units -- with nothing on screen to say why.
cleanup() {
	umount "$MNT" 2>/dev/null || true
	if [ -n "$MD" ]; then
		mdconfig -d -u "${MD#md}" 2>/dev/null ||
		    echo "warning: could not detach ${MD}; detach it by hand" >&2
	fi
	rmdir "$MNT" 2>/dev/null ||
	    echo "warning: left mountpoint ${MNT} behind" >&2
}
trap cleanup EXIT INT TERM

MD=$(mdconfig -a -t vnode -f "$IMG")
mount "/dev/${MD}p1" "$MNT"

RC="$MNT/etc/rc.local"
[ -f "$RC" ] || { echo "image has no /etc/rc.local" >&2; exit 1; }

if grep -q nested_demo_l2_cpus "$RC"; then
	echo "already patched: $IMG"
	exit 0
fi

# Keep the original beside it; this image is not rebuilt often and the previous
# L1 script is the only record of how the demo behaved before.
cp -p "$RC" "$RC.pre-l2cpus"

awk '
/^\$BC --vm=\$VM --destroy/ && !done {
	print "# How many vCPUs to give the L2 guest.  The host-side driver passes this"
	print "# down as a kernel environment variable through bhyveloads -e; a driver"
	print "# that does not set it leaves L2 with the single vCPU it always had."
	print "L2CPUS=$(kenv -q nested_demo_l2_cpus 2>/dev/null || echo 1)"
	print "case \"$L2CPUS\" in \x27\x27|*[!0-9]*) L2CPUS=1 ;; esac"
	print "[ \"$L2CPUS\" -ge 1 ] 2>/dev/null || L2CPUS=1"
	print "echo \"L1: giving the L2 guest ${L2CPUS} vCPU(s)\""
	done = 1
}
{ print }
' "$RC" > "$RC.new"

sed -i '' 's|\$BH -c 1 -m 1G|$BH -c "$L2CPUS" -m 1G|' "$RC.new"

# Refuse to install a script that does not parse, or one where the substitution
# silently missed: a broken rc.local turns every later run into a mystery.
sh -n "$RC.new" || { echo "patched rc.local does not parse; not installing" >&2; exit 1; }
grep -q 'BH -c "\$L2CPUS"' "$RC.new" || { echo "bhyve line not rewritten" >&2; exit 1; }

mv "$RC.new" "$RC"
chmod 755 "$RC"
echo "patched: $IMG"
