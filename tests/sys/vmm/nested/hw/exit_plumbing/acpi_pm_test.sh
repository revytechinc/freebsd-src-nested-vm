#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case acpi_pm
acpi_pm_head() { atf_set "descr" "ACPI PM timer I/O exit reflection"; }
acpi_pm_body() { run_l2_device_test "acpi_pm" "${ACPI_PM_TEST_CMD:-sysctl -n kern.timecounter.choice}"; }
atf_init_test_cases() { atf_add_test_case acpi_pm; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then acpi_pm_body; fi
