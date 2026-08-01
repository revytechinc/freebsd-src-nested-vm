#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case pic
pic_head() { atf_set "descr" "8259A PIC legacy interrupt injection"; }
pic_body() { run_l2_device_test "pic" "${PIC_TEST_CMD:-sysctl -n hw.irq.max_irqs}"; }
atf_init_test_cases() { atf_add_test_case pic; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then pic_body; fi
