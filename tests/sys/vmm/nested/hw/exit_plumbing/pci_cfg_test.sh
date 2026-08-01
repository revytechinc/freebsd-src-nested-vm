#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case pci_cfg
pci_cfg_head() { atf_set "descr" "PCI CF8/CFC configuration-space I/O exit reflection"; }
pci_cfg_body() { run_l2_device_test "pci_cfg" "${PCI_CFG_TEST_CMD:-pciconf -l}"; }
atf_init_test_cases() { atf_add_test_case pci_cfg; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then pci_cfg_body; fi
