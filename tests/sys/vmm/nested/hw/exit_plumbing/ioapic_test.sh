#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case ioapic
ioapic_head() { atf_set "descr" "IOAPIC modern interrupt injection"; }
ioapic_body() { run_l2_device_test "ioapic" "${IOAPIC_TEST_CMD:-dmesg | grep -Ei 'ioapic|interrupt' | tail -n 1}"; }
atf_init_test_cases() { atf_add_test_case ioapic; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then ioapic_body; fi
