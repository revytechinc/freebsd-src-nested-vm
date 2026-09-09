#!/bin/sh
# Boot a release artifact under bhyve and record what it does.
# Runs detached: an ssh session that goes away must not take the VM with it.
set -u
IMG=${1:?usage: boottest.sh <image> [vmname]}
VM=${2:-mediatest}
# The VM name becomes part of an nmdm device path, so anything but [A-Za-z0-9]
# would break that path silently: the reader would open nothing, the console
# would stay empty, and the run would report TIMEOUT with no indication that
# the name was the problem.
case "$VM" in
*[!A-Za-z0-9]*) echo "vm name must be alphanumeric: $VM" >&2; exit 2 ;;
esac
OUT=/tmp/${VM}.console
RES=/tmp/${VM}.result
WATCH=${WATCH:-300}

kldload vmm 2>/dev/null; kldload nmdm 2>/dev/null
# Overridable so a host without the edk2-bhyve package can be handed a copy
# rather than having software installed on it just to run one test.
UEFI=${UEFI:-/usr/local/share/uefi-firmware/BHYVE_UEFI.fd}
: > "$RES"
say() { echo "$*" >> "$RES"; }

if [ ! -f "$UEFI" ]; then
	say "no UEFI firmware at $UEFI -- cannot boot a UEFI guest here"
	say "verdict: NO-FIRMWARE"
	echo DONE >> "$RES"
	exit 1
fi

bhyvectl --vm="$VM" --destroy >/dev/null 2>&1
rm -f "$OUT"; : > "$OUT"

# Reader first, so the console is captured from byte zero.  Exactly one reader
# on the B side; termios is set only while that reader holds it open, because
# the last close resets it and flushes anything queued.
cat "/dev/nmdm${VM}B" >> "$OUT" 2>/dev/null &
RPID=$!
sleep 1

say "image:  $IMG ($(stat -f%z "$IMG" 2>/dev/null) bytes)"
say "sha256: $(sha256 -q "$IMG" 2>/dev/null)"
say "host:   $(hostname -s) / $(sysctl -n hw.model)"
say "start:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Optical media is attached as optical media.
#
# Everything here used to go on as virtio-blk, which is right for a raw disk
# image and silently wrong for an installer ISO: UEFI finds no boot entry on
# what it has been told is a hard disk, prints "No bootable option or device
# was found", and the run reports TIMEOUT. That reads as a broken image, and
# the image is fine -- the published disc1.iso was declared a failure that way.
#
# A check that cannot run is not a pass; one that cannot run and reports a
# failure is worse, because somebody acts on it.
# Detected by CONTENT, not by name. ISO 9660 puts "CD001" at offset 32769, and
# that is true of an artifact called .ISO, or .img, or nothing at all. Matching
# the suffix means an image published under any other name falls through to the
# disk path and reproduces the exact failure this exists to prevent.
if dd if="$IMG" bs=1 skip=32769 count=5 2>/dev/null | grep -q CD001; then
	DISKSPEC="2,ahci-cd,$IMG"
else
	DISKSPEC="2,virtio-blk,$IMG"
fi

# ONE argument, quoted at the call site. Assembling "-s 2,kind,path" into a
# string and letting the shell split it puts every space and glob character in
# the path into bhyve's argv as separate words -- so a path with a space
# produces a malformed -s spec and a run that fails looking like a bad image.
# The form this replaced passed "$IMG" quoted and did not have that exposure.
bhyve -c 2 -m 4G -A -H -P \
	-s 0,hostbridge -s "$DISKSPEC" -s 31,lpc \
	-l com1,"/dev/nmdm${VM}A" \
	-l bootrom,"$UEFI" "$VM" > "/tmp/${VM}.bhyve" 2>&1 &
BPID=$!

# Now that bhyve holds the A side, carrier is up and the B side can be
# configured without blocking.  Backgrounded anyway, so a slow start cannot
# wedge the run.
( sleep 2; stty -f "/dev/nmdm${VM}B" raw -echo clocal 2>/dev/null ) &

end=$(( $(date +%s) + WATCH ))
verdict=TIMEOUT
while [ "$(date +%s)" -lt "$end" ]; do
	if grep -qE "Welcome to FreeBSD|bsdinstall|Install  *Exit|login:" "$OUT" 2>/dev/null; then
		verdict=BOOTED; break
	fi
	if grep -qE "panic:|Fatal trap|not a bootable" "$OUT" 2>/dev/null; then
		verdict=FAILED; break
	fi
	kill -0 "$BPID" 2>/dev/null || { verdict=EXITED; break; }
	sleep 5
done

say "verdict: $verdict"
say "console: $(wc -c < "$OUT") bytes"
say "elapsed: $(( WATCH - (end - $(date +%s)) ))s"
# Order matters. Destroy the guest first so bhyve flushes and exits, give the
# reader a moment to drain what it wrote, and only then stop the reader --
# killing it first loses the output around a late panic, which is precisely
# what separates FAILED from TIMEOUT.
bhyvectl --vm="$VM" --destroy >/dev/null 2>&1
kill "$BPID" 2>/dev/null
sleep 3
kill "$RPID" 2>/dev/null
say "console: $(wc -c < "$OUT") bytes after drain"
echo DONE >> "$RES"
