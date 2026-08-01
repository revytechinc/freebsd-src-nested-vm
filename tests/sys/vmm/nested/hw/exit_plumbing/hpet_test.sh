#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case hpet
hpet_head() { atf_set "descr" "HPET timer MMIO exit reflection"; }
hpet_body() { run_l2_device_test "hpet" "${HPET_TEST_CMD:-sysctl -n kern.timecounter.hardware}"; }
atf_init_test_cases() { atf_add_test_case hpet; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then hpet_body; fi
