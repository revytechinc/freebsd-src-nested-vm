# SPDX-License-Identifier: BSD-2-Clause
. "$(atf_get_srcdir)/../hw_test_common.sh"
atf_test_case lapic_ipi
lapic_ipi_head() { atf_set "descr" "LAPIC IPI between L2 vCPUs"; }
lapic_ipi_body() { run_l2_device_test "lapic_ipi" "${LAPIC_IPI_TEST_CMD:-sysctl -n hw.ncpu}"; }
atf_init_test_cases() { atf_add_test_case lapic_ipi; }
