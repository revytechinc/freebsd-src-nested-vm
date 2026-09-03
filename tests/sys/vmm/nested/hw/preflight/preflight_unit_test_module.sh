#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 The FreeBSD Project
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
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
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# Wave 3 / T17 + Wave 5 follow-up: kernel unit test module
# (vmx_nested_test.ko) integration.  The module is built with the
# forked kernel and loaded via kldload(8); its MOD_LOAD handler
# runs five sub-tests and prints "N/5 PASS (M FAIL, K SKIP)" to
# the kernel log.  The test SKIPs gracefully on hosts where vmm.ko
# does not export the wave-3 vmx_nested_status symbol (the documented
# failure mode for an upstream 16.0-CURRENT vmm.ko).
#
# Requires root; the vmx_nested_test.ko file must be in MODULES_OVERRIDE
# directories (or under /boot/modules or /boot/kernel).

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

preflight_unit_test_module_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if [ "$(id -u 2>/dev/null)" != "0" ]; then
		echo "SKIP: not root; cannot kldload"
		return 0
	fi
	if ! command -v kldload >/dev/null 2>&1; then
		echo "SKIP: kldload(8) not available"
		return 0
	fi
	if kldstat 2>/dev/null | grep -qw vmx_nested_test; then
		echo "SKIP: vmx_nested_test already loaded"
		return 0
	fi
	return 1
}

# Locate the module on disk.  Search standard /boot locations.
find_module_path()
{
	for dir in /boot/modules /boot/kernel; do
		if [ -r "${dir}/vmx_nested_test.ko" ]; then
			printf '%s\n' "${dir}/vmx_nested_test.ko"
			return 0
		fi
	done
	return 1
}

# Mark the dmesg cursor so we can read only the lines emitted by
# the module load.  FreeBSD dmesg is a ring; we can't easily truncate
# it, so instead we read the full dmesg after the load and filter
# for lines matching the module name.
preflight_unit_test_module_main()
{
	if preflight_unit_test_module_unsupported; then
		exit 0
	fi

	modpath=$(find_module_path) || {
		echo "SKIP: vmx_nested_test.ko not found in /boot/{modules,kernel}"
		exit 0
	}

	dmesg_before=$(dmesg 2>/dev/null | wc -l)
	if ! kldload "${modpath}" 2>/dev/null; then
		# Documented failure mode: the forked vmm.ko exports
		# vmx_nested_status, but an upstream vmm.ko does not.
		# Treat that as a SKIP rather than a FAIL.
		err=$(kldload "${modpath}" 2>&1 || true)
		if printf '%s\n' "${err}" | grep -q 'undefined symbol'; then
			echo "SKIP: kldload failed (vmm.ko missing wave-3 vmx_nested_status symbol)"
			exit 0
		fi
		echo "FAIL: kldload ${modpath} failed: ${err}"
		exit 1
	fi

	# Give the kernel log a moment to flush.
	sleep 0.2

	# Read all vmx_nested_test output.  The module prints
	# "vmx_nested_test: starting 5 sub-tests (T17 / Wave 3)"
	# followed by per-test PASS/FAIL/SKIP lines and a final
	# "vmx_nested_test: N/5 PASS (M FAIL, K SKIP)" line.
	out=$(dmesg 2>/dev/null | grep '^vmx_nested_test:')
	if [ -z "${out}" ]; then
		# Fall back to the kernel log file on hosts where
		# the dmesg ring is no longer readable.
		out=$(grep '^vmx_nested_test:' /var/log/messages 2>/dev/null || true)
	fi
	if [ -z "${out}" ]; then
		# dmesg_before is the line count before; anything after
		# is the new output.  But dmesg(8) is cumulative, so
		# this is best-effort.
		echo "WARN: no vmx_nested_test output found in dmesg"
	fi

	# Try to unload.  Failures here are non-fatal because the
	# kernel may hold a reference to the module if a test
	# allocated persistent resources.
	kldunload vmx_nested_test 2>/dev/null || true

	# Validate the summary line.
	if ! printf '%s\n' "${out}" | grep -Eq \
	    '^vmx_nested_test: [0-9]+/5 PASS \([0-9]+ FAIL, [0-9]+ SKIP\)$'; then
		echo "FAIL: vmx_nested_test summary line not found"
		printf '%s\n' "${out}"
		# dmesg_before is referenced only to silence unused
		# variable warnings; the real failure is the summary.
		: "${dmesg_before}"
		exit 1
	fi

	# Confirm the test module reached MOD_LOAD (the 'starting'
	# line is unconditional, even if every sub-test SKIPs).
	if ! printf '%s\n' "${out}" | grep -q 'starting 5 sub-tests'; then
		echo "FAIL: vmx_nested_test 'starting' line missing"
		printf '%s\n' "${out}"
		exit 1
	fi

	echo "PASS: preflight_unit_test_module loaded and ran 5 sub-tests"
	: "${dmesg_before}"
}

preflight_unit_test_module_main "$@"

atf_test_case "preflight_unit_test_module"
preflight_unit_test_module_head()
{
	atf_set "descr" "vmx_nested_test.ko loads and prints N/5 PASS summary"
	atf_set "require.user" "root"
}
preflight_unit_test_module_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_unit_test_module"
}
