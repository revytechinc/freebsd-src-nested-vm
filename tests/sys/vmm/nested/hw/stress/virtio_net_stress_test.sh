#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case virtio_net_stress
virtio_net_stress_head() { atf_set "descr" "virtio-net packet flow under concurrent nested load"; }
virtio_net_stress_body() { run_l2_stress_test "virtio_net" "${VIRTIO_NET_STRESS_CMD:-for i in $(seq 1 100); do ping -c 1 -W 1 ${NESTED_STRESS_PEER:-127.0.0.1} >/dev/null; done}"; }
atf_init_test_cases() { atf_add_test_case virtio_net_stress; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then virtio_net_stress_body; fi
