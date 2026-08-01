#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
set -o errexit
set -o nounset
set -o pipefail
source "$(dirname "$0")/../hw_test_common.sh"
atf_test_case dma_nested_paging_stress
dma_nested_paging_stress_head() { atf_set "descr" "emulated DMA under nested EPT/NPT paging stress"; }
dma_nested_paging_stress_body() { run_l2_stress_test "dma_nested_paging" "${DMA_NESTED_PAGING_STRESS_CMD:-dd if=/dev/zero of=/tmp/nested-dma bs=4k count=128 conv=fsync}"; }
atf_init_test_cases() { atf_add_test_case dma_nested_paging_stress; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then dma_nested_paging_stress_body; fi
