#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case virtio_console
virtio_console_head() { atf_set "descr" "virtio-console character I/O exit reflection"; }
virtio_console_body() { run_l2_device_test "virtio_console" "${VIRTIO_CONSOLE_TEST_CMD:-printf 'nested-console\\n' > /dev/console}"; }
atf_init_test_cases() { atf_add_test_case virtio_console; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then virtio_console_body; fi
