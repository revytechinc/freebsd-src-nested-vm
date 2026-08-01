#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case virtio_scsi_stress
virtio_scsi_stress_head() { atf_set "descr" "virtio-scsi multi-LUN scatter-gather stress"; }
virtio_scsi_stress_body() { run_l2_stress_test "virtio_scsi" "${VIRTIO_SCSI_STRESS_CMD:-mount -t devfs devfs /dev && ls /dev/da*}"; }
atf_init_test_cases() { atf_add_test_case virtio_scsi_stress; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then virtio_scsi_stress_body; fi
