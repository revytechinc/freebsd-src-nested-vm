#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
# All rights reserved.
#
# Wave 2 / T11 ATF smoke test for the AMD SVM nested-virt userland
# surface.  Verifies:
#
#   * vmm(4) loads on amd64,
#   * the runtime gate hw.vmm.nested.enable (T2) is observable,
#   * the gate round-trips through sysctl(8) (write 1, read back,
#     write 0 to restore) without regression.
#
# Deliberately does NOT attempt to launch a nested L2 guest — that
# path lands in wave 4 once svm_nested.{h,c} is wired into the
# VMRUN/VMRESUME loop.  This test exists to catch userland KBI
# regressions for wave 1's VMMCTL_CREATE_NESTED addition.
#
# The userland-side constant VMMAPI_OPEN_CREATE_NESTED lives in
# lib/libvmmapi/vmmapi.h and must remain combinable with
# VMMAPI_OPEN_CREATE via vm_openf(3); a wave-3 test will exercise
# the actual ioctl.  Until then, this smoke test guards the sysctl
# surface that gates the nested-create path.
#
# Reference: KVM selftests at tools/testing/selftests/kvm/x86_64/svm_*
# are DESIGN REFERENCE ONLY (GPL); this test is original BSD code.

atf_test_case svm_basic_smoke
svm_basic_smoke_head()
{
	atf_set "descr" "vmm(4) nested-virt userland smoke test (amd64 SVM)"
	atf_set "require.arch" "amd64"
	atf_set "require.kmods" "vmm"
	atf_set "require.user" "root"
}

svm_basic_smoke_body()
{
	local saved

	# vmm module is loaded (require.kmods enforces presence).
	# sysctl is observable (T2 landed in wave 1).
	atf_check -s exit:0 -o ignore -e ignore \
	    sysctl -n hw.vmm.nested.enable

	# Save current value so we can restore it; the gate is
	# CTLFLAG_RWTUN so writing 1 must succeed.
	saved=$(sysctl -n hw.vmm.nested.enable)
	trap 'sysctl hw.vmm.nested.enable="${saved}" >/dev/null 2>&1' EXIT

	atf_check -s exit:0 -o ignore -e ignore \
	    sysctl hw.vmm.nested.enable=1
	atf_check -s exit:0 -o match:".*1.*" -o ignore -e ignore \
	    sysctl hw.vmm.nested.enable

	# Restore the original value so other tests are unaffected.
	atf_check -s exit:0 -o ignore -e ignore \
	    sysctl hw.vmm.nested.enable="${saved}"
	trap - EXIT
}

atf_init_test_cases()
{
	atf_add_test_case svm_basic_smoke
}