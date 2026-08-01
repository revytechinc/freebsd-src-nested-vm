#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case msi
msi_head() { atf_set "descr" "MSI/MSI-X PCIe interrupt injection"; }
msi_body() { run_l2_device_test "msi" "${MSI_TEST_CMD:-vmstat -i}"; }
atf_init_test_cases() { atf_add_test_case msi; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then msi_body; fi
