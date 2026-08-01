#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case acpi_powerbutton_stress
acpi_powerbutton_stress_head() { atf_set "descr" "ACPI power-button propagation under load"; }
acpi_powerbutton_stress_body() { run_l2_stress_test "acpi_powerbutton" "${ACPI_POWERBUTTON_STRESS_CMD:-sysctl -n hw.acpi.supported_sleep_state}"; }
atf_init_test_cases() { atf_add_test_case acpi_powerbutton_stress; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then acpi_powerbutton_stress_body; fi
