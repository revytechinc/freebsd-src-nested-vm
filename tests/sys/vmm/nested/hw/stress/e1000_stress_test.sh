#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case e1000_stress
e1000_stress_head() { atf_set "descr" "e1000 multi-queue legacy NIC stress"; }
e1000_stress_body() { run_l2_stress_test "e1000" "${E1000_STRESS_CMD:-netstat -i}"; }
atf_init_test_cases() { atf_add_test_case e1000_stress; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then e1000_stress_body; fi
