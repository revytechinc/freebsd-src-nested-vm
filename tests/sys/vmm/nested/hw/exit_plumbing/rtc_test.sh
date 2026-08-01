#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case rtc
rtc_head() { atf_set "descr" "RTC timer I/O exit reflection"; }
rtc_body() { run_l2_device_test "rtc" "${RTC_TEST_CMD:-date -u}"; }
atf_init_test_cases() { atf_add_test_case rtc; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then rtc_body; fi
