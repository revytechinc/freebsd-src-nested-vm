#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause

set -o errexit
set -o nounset
set -o pipefail

source "$(dirname "$0")/../hw_test_common.sh"

atf_test_case virtio_blk
virtio_blk_head() { atf_set "descr" "virtio-blk disk I/O exit reflection"; }
virtio_blk_body() {
    run_l2_device_test "virtio_blk" "${VIRTIO_BLK_TEST_CMD:-dd if=/dev/zero of=/tmp/nested-virtio-blk bs=4k count=8 conv=fsync && cmp /dev/zero /dev/zero}"
}

atf_init_test_cases() { atf_add_test_case virtio_blk; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    virtio_blk_body
fi
