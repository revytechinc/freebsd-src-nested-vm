#!/bin/sh
# Relay the spin request from L1 down to L2.
#
# The host driver sets nested_demo_l2_spin in L1's kernel environment, but L2
# is a separate guest with its own environment: L1's rc.local has to pass the
# value on when it loads L2, exactly as it already does for the vCPU count.
# Without this the inner guest never sees the request and the spin block is
# dead code -- which would read as "the workload made no difference".
set -eu
IMG=${1:-/usr/local/share/cloudbsd-demo/auto/nested-demo.raw}
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
MNT=$(mktemp -d /tmp/l1r.XXXXXX); MD=""
cleanup() {
	umount "$MNT" 2>/dev/null || true
	if [ -n "$MD" ]; then
		mdconfig -d -u "${MD#md}" 2>/dev/null ||
		    echo "warning: could not detach ${MD}" >&2
	fi
	rmdir "$MNT" 2>/dev/null || true
	# Never let cleanup decide the exit status.
	:
}
trap cleanup EXIT INT TERM
MD=$(mdconfig -a -t vnode -f "$IMG")
mount "/dev/${MD}p1" "$MNT"
RC="$MNT/etc/rc.local"
grep -q nested_demo_l2_cpus "$RC" || { echo "outer rc.local not patched for cpus yet" >&2; exit 1; }
if grep -q nested_demo_l2_spin "$RC"; then echo "already relaying: $IMG"; exit 0; fi
cp -p "$RC" "$RC.pre-spinrelay"

awk '
/^L2CPUS=/ && !d {
	print
	print "L2SPIN=$(kenv -q nested_demo_l2_spin 2>/dev/null || echo 0)"
	print "case \"$L2SPIN\" in \x27\x27|*[!0-9]*) L2SPIN=0 ;; esac"
	d = 1
	next
}
{ print }
' "$RC" > "$RC.new"
# Hand it to the inner loader. Anchored on autoboot_delay=1 alone rather than
# the whole line: a longer match would silently do nothing if the image's
# loader invocation ever gains a flag or wraps differently, and a substitution
# that matches nothing is the hardest kind of failure to notice.
#
# sed -i is spelled differently on BSD and GNU, so write through a temp file and
# move it, as the awk step above already does.
sed 's|-e autoboot_delay=1 |-e autoboot_delay=1 -e nested_demo_l2_spin="$L2SPIN" |' \
    "$RC.new" > "$RC.new2"

fail() { echo "$1" >&2; rm -f "$RC.new" "$RC.new2"; exit 1; }
sh -n "$RC.new2" || fail "patched rc.local does not parse"
grep -q 'nested_demo_l2_spin="\$L2SPIN"' "$RC.new2" ||
    fail "relay not wired into the inner bhyveload"
mv "$RC.new2" "$RC"; rm -f "$RC.new"; chmod 755 "$RC"
echo "relay added: $IMG"
