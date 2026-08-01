#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case virtio_rnd
virtio_rnd_head() { atf_set "descr" "virtio-rnd entropy exit reflection"; }
virtio_rnd_body() { run_l2_device_test "virtio_rnd" "${VIRTIO_RND_TEST_CMD:-dd if=/dev/random of=/dev/null bs=32 count=1}"; }
atf_init_test_cases() { atf_add_test_case virtio_rnd; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then virtio_rnd_body; fi
