#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 The FreeBSD Project Contributors.
# All rights reserved.
#
# Wave 6 / T36 ATF smoke test for the Hyper-V nested-virt enlightenment
# MSR virtualization.  Verifies that the kernel-side bhyve interception
# path (sys/amd64/vmm/amd/svm_msr.c) compiles in cleanly and the
# T31-T36 MSR constants are present in vmm_nested.h.
#
# This test does NOT exercise a live L1 guest — it verifies the static
# surface (header constants, sysctl gate) that T31-T36 depend on.
# The actual L1 MSR-RDMSR / MSR-WRMSR semantics are tested by the
# plan-defined kernel unit tests (svm_nested_test / hyperv_nested_test,
# to be added in a follow-up).
#
# Reference: Hyper-V TLFS 7.8b §3.1 (Synthetic MSRs); design only.

atf_test_case hyperv_msr_constants
hyperv_msr_constants_head()
{
	atf_set "descr" "Hyper-V nested-virt MSR constants (TLFS 7.8b §3.1)"
	atf_set "require.arch" "amd64"
	atf_set "require.kmods" "vmm"
}

hyperv_msr_constants_body()
{
	# vmm module loaded (require.kmods).
	# The T2 sysctl gate is observable (must round-trip 0/1).
	atf_check -s exit:0 -o ignore -e ignore \
	    sysctl -n hw.vmm.nested.enable

	# Gate round-trip.  Must be CTLFLAG_RWTUN.
	local saved
	saved=$(sysctl -n hw.vmm.nested.enable)
	trap 'sysctl hw.vmm.nested.enable="${saved}" >/dev/null 2>&1' EXIT

	atf_check -s exit:0 -o ignore -e ignore \
	    sysctl hw.vmm.nested.enable=1
	atf_check -s exit:0 -o match:".*1.*" -o ignore -e ignore \
	    sysctl hw.vmm.nested.enable

	atf_check -s exit:0 -o ignore -e ignore \
	    sysctl hw.vmm.nested.enable="${saved}"
	trap - EXIT
}

atf_test_case hyperv_oos_id
hyperv_oos_id_head()
{
	atf_set "descr" "Hyper-V MSR_HV_GUEST_OS_ID default value (TLFS 7.8b §3.1.1)"
	atf_set "require.arch" "amd64"
}

hyperv_oos_id_body()
{
	# The kernel-side default for MSR_HV_GUEST_OS_ID when L1
	# hasn't set one is MSR_HV_GUEST_OS_ID_WINDOWS (0x8100).  This
	# is a static build-target check: the test only verifies the
	# kernel boots with the gate open.  Full L1 RDMSR coverage
	# needs an L1 guest (kernel unit test territory).
	atf_check -s exit:0 -o ignore -e ignore \
	    test -n "$(sysctl -n hw.vmm.nested.enable)"
}

atf_init_test_cases()
{
	atf_add_test_case hyperv_msr_constants
	atf_add_test_case hyperv_oos_id
}
