#!/bin/sh
#
# build_l2_image.sh — Build a bootable mfsBSD image for L2 testing.
#
# This script fetches the current FreeBSD 16.0-CURRENT base.txz and
# kernel.txz, then uses mfsBSD scripts to produce a ~388MB GPT image
# that boots in bhyve via UEFI.
#
# Run on a FreeBSD host with git and sudo.
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
sudo -n pkg install -y bhyve-firmware

# 4. Build the image (needs sudo for chown/chmod in work tree)
log "Building mfsBSD image (this takes ~2 minutes)"
rm -rf "${IMAGE_DIR}/work"
cd "${IMAGE_DIR}"
sudo -n make BASE="$(realpath "${FREEBSD_DIST}")" MFSROOT_MAXSIZE=512m image

# 5. Verify the image
log "Verifying image"
ls -la mfsbsd-16.0-CURRENT-amd64.img
sudo -n mdconfig -f mfsbsd-16.0-CURRENT-amd64.img
sudo -n gpart show md0
sudo -n mkdir -p /tmp/mfsverify
sudo -n mount -t msdosfs /dev/md0p2 /tmp/mfsverify
sudo -n ls /tmp/mfsverify/EFI/BOOT/ | head -5
sudo -n ls /tmp/mfsverify/boot/ | head -5
sudo -n umount /tmp/mfsverify
sudo -n mdconfig -d -u 0

# 6. Install as test fixture
log "Installing at /usr/tests/sys/vmm/nested/fixtures/l2_freebsd.img"
sudo -n mkdir -p /usr/tests/sys/vmm/nested/fixtures
sudo -n cp mfsbsd-16.0-CURRENT-amd64.img /usr/tests/sys/vmm/nested/fixtures/l2_freebsd.img
sudo -n chmod 644 /usr/tests/sys/vmm/nested/fixtures/l2_freebsd.img

log "Done. Image is at /usr/tests/sys/vmm/nested/fixtures/l2_freebsd.img"
log "Test with: bhyve -c 2 -m 1G -l bootrom,/usr/local/share/uefi-firmware/BHYVE_UEFI.fd -l com1,stdio -s 0,hostbridge -s 1,lpc -s 2,virtio-blk,/usr/tests/sys/vmm/nested/fixtures/l2_freebsd.img test-l2"