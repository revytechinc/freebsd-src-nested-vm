#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case uart
uart_head() { atf_set "descr" "UART 16550A legacy serial I/O exit reflection"; }
uart_body() { run_l2_device_test "uart" "${UART_TEST_CMD:-stty -a < /dev/ttyu0}"; }
atf_init_test_cases() { atf_add_test_case uart; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then uart_body; fi
