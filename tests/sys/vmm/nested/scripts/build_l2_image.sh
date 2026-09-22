#!/bin/sh
#
# build_l2_image.sh — Build a bootable mfsBSD image for L2 testing.
#
# This script fetches the current FreeBSD 16.0-CURRENT base.txz and
# kernel.txz, then uses mfsBSD scripts to produce a ~388MB GPT image
# that boots in bhyve via UEFI.
#
# Run on a FreeBSD host with git and doas (or sudo).
#
# Output: $HOME/mfsbsd-build/mfsbsd/mfsbsd-16.0-CURRENT-amd64.img
# Then copy to /usr/tests/sys/vmm/nested/fixtures/l2_freebsd.img

set -eu

BUILD_DIR="${HOME}/mfsbsd-build"
IMAGE_DIR="${HOME}/mfsbsd-build/mfsbsd"
BASE="https://download.freebsd.org/snapshots/amd64/amd64/16.0-CURRENT"
FREEBSD_DIST="${BUILD_DIR}/freebsd-dist"

log()
{
    echo "$(date -u +%H:%M:%S) $*"
}

# PRIVILEGE ESCALATION: doas first, sudo second.
#
# This script called `sudo -n' fourteen times. The CloudBSD fleet standardises
# on doas(1) and several hosts have no sudo at all, where every one of those
# lines fails with "sudo: not found" -- partway through, after the downloads
# and the clone, leaving a half-built tree. Resolve it once, up front, and say
# so plainly if neither is available rather than discovering it at line 41.
if command -v doas >/dev/null 2>&1; then
    SUDO="doas"
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo -n"
else
    echo "build_l2_image: neither doas nor sudo is available; cannot continue" >&2
    exit 1
fi

# 1. Fetch base + kernel archives
log "Fetching base.txz and kernel.txz"
mkdir -p "${BUILD_DIR}"
mkdir -p "${FREEBSD_DIST}"
fetch -q -o "${FREEBSD_DIST}/base.txz" "${BASE}/base.txz"
fetch -q -o "${FREEBSD_DIST}/kernel.txz" "${BASE}/kernel.txz"

# 2. Fetch mfsbsd scripts (depth-1)
if [ ! -d "${IMAGE_DIR}" ]; then
    log "Cloning mfsbsd scripts"
    git clone --depth=1 https://github.com/mmatuska/mfsbsd.git "${IMAGE_DIR}"
fi

# 3. Install bhyve-firmware (required for bhyve to boot the image)
log "Installing bhyve-firmware"
${SUDO} pkg install -y bhyve-firmware

# 4. Build the image (needs privilege for chown/chmod in work tree)
log "Building mfsBSD image (this takes ~2 minutes)"
rm -rf "${IMAGE_DIR}/work"
cd "${IMAGE_DIR}"
${SUDO} make BASE="$(realpath "${FREEBSD_DIST}")" MFSROOT_MAXSIZE=512m image

# 5. Verify the image
log "Verifying image"
ls -la mfsbsd-16.0-CURRENT-amd64.img
# USE THE UNIT mdconfig ACTUALLY GAVE US, not md0.
#
# `mdconfig -f <img>' allocates the next FREE unit and prints its name. This
# block used to attach that way and then hardcode md0 for gpart, for the
# mount, and -- worst -- for `mdconfig -d -u 0'. On any host where md0 already
# belonged to something else, this inspected the wrong device and then
# DESTROYED a memory disk it did not create.
#
# And it was not correct even on an idle host. Measured on freedev010 with no
# md devices attached at all, `mdconfig -f' returned md1 -- so `gpart show
# md0' named a device that did not exist, the mount had nothing to mount, and
# the destroy targeted a unit this script had never created.
MD=$(${SUDO} mdconfig -f mfsbsd-16.0-CURRENT-amd64.img)
case "${MD}" in
md[0-9]*) ;;
*)  echo "build_l2_image: mdconfig returned '${MD}', not a unit name" >&2
    exit 1 ;;
esac

# Detach on any exit from here on, so a failure in the middle does not leave
# the image attached and the mount point busy.
cleanup_md()
{
    ${SUDO} umount /tmp/mfsverify 2>/dev/null || true
    ${SUDO} mdconfig -d -u "${MD#md}" 2>/dev/null || true
}
trap cleanup_md EXIT INT TERM

${SUDO} gpart show "${MD}"
${SUDO} mkdir -p /tmp/mfsverify
${SUDO} mount -t msdosfs "/dev/${MD}p2" /tmp/mfsverify
${SUDO} ls /tmp/mfsverify/EFI/BOOT/ | head -5
${SUDO} ls /tmp/mfsverify/boot/ | head -5
${SUDO} umount /tmp/mfsverify
${SUDO} mdconfig -d -u "${MD#md}"
trap - EXIT INT TERM

# 6. Install as test fixture
log "Installing at /usr/tests/sys/vmm/nested/fixtures/l2_freebsd.img"
${SUDO} mkdir -p /usr/tests/sys/vmm/nested/fixtures
${SUDO} cp mfsbsd-16.0-CURRENT-amd64.img /usr/tests/sys/vmm/nested/fixtures/l2_freebsd.img
${SUDO} chmod 644 /usr/tests/sys/vmm/nested/fixtures/l2_freebsd.img

log "Done. Image is at /usr/tests/sys/vmm/nested/fixtures/l2_freebsd.img"
log "Test with: bhyve -c 2 -m 1G -l bootrom,/usr/local/share/uefi-firmware/BHYVE_UEFI.fd -l com1,stdio -s 0,hostbridge -s 1,lpc -s 2,virtio-blk,/usr/tests/sys/vmm/nested/fixtures/l2_freebsd.img test-l2"