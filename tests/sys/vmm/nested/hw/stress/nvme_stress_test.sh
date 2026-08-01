#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case nvme_stress
nvme_stress_head() { atf_set "descr" "NVMe SQE/CQE translation stress"; }
nvme_stress_body() { run_l2_stress_test "nvme" "${NVME_STRESS_CMD:-dd if=/dev/zero of=/tmp/nested-nvme bs=4k count=64 conv=fsync}"; }
atf_init_test_cases() { atf_add_test_case nvme_stress; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then nvme_stress_body; fi
