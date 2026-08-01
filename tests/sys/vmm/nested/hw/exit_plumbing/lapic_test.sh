#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case lapic
lapic_head() { atf_set "descr" "LAPIC per-vCPU interrupt and timer path"; }
lapic_body() { run_l2_device_test "lapic" "${LAPIC_TEST_CMD:-sysctl -n hw.ncpu}"; }
atf_init_test_cases() { atf_add_test_case lapic; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then lapic_body; fi
