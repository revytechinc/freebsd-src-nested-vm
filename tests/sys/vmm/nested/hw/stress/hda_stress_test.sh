#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case hda_stress
hda_stress_head() { atf_set "descr" "Intel HDA playback and capture stress"; }
hda_stress_body() { run_l2_stress_test "hda" "${HDA_STRESS_CMD:-cat /dev/sndstat}"; }
atf_init_test_cases() { atf_add_test_case hda_stress; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then hda_stress_body; fi
