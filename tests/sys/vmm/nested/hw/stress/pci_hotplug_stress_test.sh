#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case pci_hotplug_stress
pci_hotplug_stress_head() { atf_set "descr" "PCI hotplug add/remove under concurrent load"; }
pci_hotplug_stress_body() { run_l2_stress_test "pci_hotplug" "${PCI_HOTPLUG_STRESS_CMD:-pciconf -l}"; }
atf_init_test_cases() { atf_add_test_case pci_hotplug_stress; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then pci_hotplug_stress_body; fi
