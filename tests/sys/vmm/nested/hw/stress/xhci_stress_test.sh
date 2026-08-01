#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case xhci_stress
xhci_stress_head() { atf_set "descr" "xHCI USB 3 controller concurrent device stress"; }
xhci_stress_body() { run_l2_stress_test "xhci" "${XHCI_STRESS_CMD:-usbconfig list}"; }
atf_init_test_cases() { atf_add_test_case xhci_stress; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then xhci_stress_body; fi
