#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# build_layer_images.sh — build one stock FreeBSD image per nesting layer.
#
# Deep-nesting tests need an image at L1, another at L2, another at L3.
# Copying one image N times does not work: the copies carry identical GPT
# labels and an identical ZFS pool name, so a guest can import or mount the
# partitions of the disk belonging to the layer below it. The failures that
# produces impersonate hypervisor bugs -- a layer dropping to single user
# after a failed fsck, or bhyveload reporting a bare "Operation not
# permitted" because GEOM will not write-open a provider whose partitions are
# already in use.
#
# So build each layer separately with OccamBSD's imagine.sh and give each one
# its own pool name. Two flags are not optional for our purposes:
#
#   -p "bhyve-firmware"  a layer cannot boot a guest of its own without it,
#                        which is the commonest reason a "nested" image turns
#                        out not to nest
#   -I                   injects imagine.sh/propagate.sh so a layer can build
#                        the image for the layer below it
#
# The guests stay stock FreeBSD: nothing here modifies the guest to make
# nesting work.
#
# Requires root, network, and ~4 GB of pool space per layer.

# shellcheck shell=sh
set -eu

PROGRAM="${0##*/}"

LAYERS=${LAYERS:-3}
SIZE_GB=${SIZE_GB:-15}
WORKDIR=${WORKDIR:-${HOME}/imagine-work}
OCCAMBSD=${OCCAMBSD:-${HOME}/occambsd}
RELEASE=${RELEASE:-}
PACKAGES=${PACKAGES:-bhyve-firmware}

usage()
{
	cat <<USAGE
usage: ${PROGRAM} [-n layers] [-g gigabytes] [-O workdir] [-r release]

  -n  number of layer images to build (default: ${LAYERS})
  -g  grow each image to this many gigabytes (default: ${SIZE_GB})
  -O  working directory (default: ${WORKDIR})
  -r  FreeBSD version to image (default: this host's)

Produces \${workdir}/nested<N>.raw with pool "nested<N>", plus the
generated bhyve/qemu/xen boot scripts under \${workdir}/layer<N>/.
USAGE
	exit 1
}

while getopts "n:g:O:r:h" opt; do
	case "${opt}" in
	n)	LAYERS=${OPTARG} ;;
	g)	SIZE_GB=${OPTARG} ;;
	O)	WORKDIR=${OPTARG} ;;
	r)	RELEASE=${OPTARG} ;;
	*)	usage ;;
	esac
done

[ "$(id -u)" = 0 ] || { echo "${PROGRAM}: must be root" >&2; exit 1; }
[ -f "${OCCAMBSD}/imagine.sh" ] || {
	echo "${PROGRAM}: ${OCCAMBSD}/imagine.sh not found." >&2
	echo "  git clone https://github.com/michaeldexter/occambsd.git ${OCCAMBSD}" >&2
	exit 1
}

mkdir -p "${WORKDIR}"

n=1
while [ "${n}" -le "${LAYERS}" ]; do
	image="${WORKDIR}/nested${n}.raw"
	layerdir="${WORKDIR}/layer${n}"

	if [ -f "${image}" ]; then
		echo "${PROGRAM}: layer ${n}: ${image} exists, skipping"
		n=$((n + 1))
		continue
	fi

	echo "${PROGRAM}: layer ${n}: building ${image} (pool nested${n})"
	# -u adds the root/root and freebsd/freebsd logins the console-driven
	# tests log in with; -n and -v produce a NIC and ready-made boot
	# scripts, which set the UEFI bootrom and NVMe backing correctly.
	# shellcheck disable=SC2086
	( cd "${OCCAMBSD}" && sh imagine.sh \
	    ${RELEASE:+-r "${RELEASE}"} \
	    -O "${layerdir}" \
	    -g "${SIZE_GB}" \
	    -Z "nested${n}" \
	    -u \
	    -p "${PACKAGES}" \
	    -I \
	    -n \
	    -v \
	    -t "${image}" ) || {
		echo "${PROGRAM}: layer ${n} failed" >&2
		exit 1
	}

	# Every generated script names the VM "vm0", which collides as soon as
	# two layers are staged on one host.
	for script in "${layerdir}"/bhyve-*.sh "${layerdir}"/qemu-*.sh; do
		[ -f "${script}" ] || continue
		sed -i '' "s/vm0/nested${n}/g" "${script}"
	done

	n=$((n + 1))
done

echo "${PROGRAM}: done"
ls -l "${WORKDIR}"/nested*.raw
