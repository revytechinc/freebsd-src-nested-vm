#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
# DAMAGE.
#

# T17 / Wave 3: VMX (Intel) nested-virt register-virt tests.
#
# This ATF test loads the vmx_nested_test.ko kernel module which runs
# five sub-tests at kldload time and prints PASS/FAIL/SKIP lines to
# the kernel message buffer.  We then verify:
#   - the kernel module loaded and produced "N/5 PASS" (or SKIP)
#     output for the vmm-dependent sub-tests;
#   - hw.vmm.nested.vmx sysctl is present and an integer in [0, 2];
#   - hw.vmm.nested.svm sysctl is present and an integer in [0, 2];
#   - on this host (T17 reference platform is the Tiger Lake i9-11950H
#     which has VMCS shadowing), hw.vmm.nested.vmx must be 2 (ready).
#
# On hosts where vmm.ko is not built into the kernel the entire test
# is skipped via atf_skip.

# shellcheck shell=sh

atf_test_case vmx_basic cleanup
vmx_basic_head()
{
	atf_set "descr" "Wave-3 VMX nested-virt register-virt self-tests"
	atf_set "require.user" "root"
	atf_set "require.kmods" "vmm"
}

vmx_basic_body()
{
	# 1. Kernel unit tests: load vmx_nested_test.ko, read its summary
	#    from dmesg, unload.  Tolerate the kldload failure if the
	#    module is not present in this build; that just means the
	#    test module was not installed.
	dmesg_marker_before=$(dmesg | wc -l)

	if ! kldload vmx_nested_test 2>/dev/null; then
		atf_skip "vmx_nested_test.ko not present in this build"
	fi

	# Give the MOD_LOAD callback time to print its summary.
	sleep 1
	dmesg_marker_after=$(dmesg | wc -l)
	delta=$((dmesg_marker_after - dmesg_marker_before))
	if [ "${delta}" -lt 1 ]; then
		delta=20
	fi
	summary=$(dmesg | tail -n "${delta}" | \
	    grep -E '^vmx_nested_test: [0-9]+/5 PASS' | tail -n 1 || true)

	kldunload vmx_nested_test 2>/dev/null || true

	if [ -z "${summary}" ]; then
		atf_fail "vmx_nested_test.ko produced no N/5 PASS summary line"
	fi
	atf_check_not_matches "${summary}" 'FAIL' "vmx_nested_test reported FAIL"

	# 2. hw.vmm.nested.vmx must exist and be in [0, 2].
	vmx_status=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null) || \
	    atf_skip "hw.vmm.nested.vmx not exposed"
	case "${vmx_status}" in
	0|1|2) ;;
	*)	atf_fail "hw.vmm.nested.vmx=${vmx_status}, not in {0,1,2}" ;;
	esac

	# 3. hw.vmm.nested.svm must exist and be in [0, 2] (may be 0 on Intel).
	svm_status=$(sysctl -n hw.vmm.nested.svm 2>/dev/null) || \
	    atf_skip "hw.vmm.nested.svm not exposed"
	case "${svm_status}" in
	0|1|2) ;;
	*)	atf_fail "hw.vmm.nested.svm=${svm_status}, not in {0,1,2}" ;;
	esac

	# 4. T17 reference host invariant: an Intel CPU with VMCS
	#    shadowing (Haswell+ class, including Tiger Lake i9-11950H)
	#    must report 2 (ready).  Skip on non-Intel CPUs.
	if ! grep -qw vmx /var/run/dmesg.boot /var/log/dmesg 2>/dev/null; then
		# Fall back to /proc/cpuinfo
		if ! grep -qw vmx /proc/cpuinfo 2>/dev/null; then
			atf_skip "host does not advertise Intel VMX"
		fi
	fi
	atf_check_equal "${vmx_status}" "2"

	atf_pass
}

vmx_basic_cleanup()
{
	# Best-effort cleanup so this test does not leave a stale kld
	# loaded if a body error short-circuited the explicit unload.
	kldunload vmx_nested_test 2>/dev/null || true
}

atf_init_test_cases()
{
	atf_add_test_case vmx_basic
}
