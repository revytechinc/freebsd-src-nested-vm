#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case pit
pit_head() { atf_set "descr" "PIT timer I/O exit reflection"; }
pit_body() { run_l2_device_test "pit" "${PIT_TEST_CMD:-sleep 0.01}"; }
atf_init_test_cases() { atf_add_test_case pit; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then pit_body; fi
