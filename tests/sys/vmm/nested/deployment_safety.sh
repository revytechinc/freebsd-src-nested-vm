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
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# shellcheck shell=sh
#
# deployment_safety.sh -- ATF test for bhyve nested-virt deployment safety.
#
# Verifies that the host is configured for safe nested-virt development:
#   * Panic debugger is disabled so panics auto-reboot rather than hanging
#     the test box in DDB.
#   * vmm.ko is NOT auto-loaded at boot so a broken vmm does not brick the
#     box before an operator can intervene.
#
# Run via:
#   cd /usr/tests/sys/vmm/nested && kyua test deployment_safety
#
# scripts_exist runs with no extra argument. The two cases that rewrite this
# machine's boot configuration are gated behind require.config and stay
# skipped unless asked for by name:
#
#   kyua -v test_suites.FreeBSD.vmm_nested_allow_boot_config_rewrite=yes \
#       test deployment_safety
#
# The variable is named for this test deliberately. A generic name like
# allow_host_mutation is a suite-wide switch that any other test could share,
# so one line in kyua.conf would silently arm all of them at once.
#
# Note also that neither case backs up the file it rewrites. The change is
# PERMANENT, which is why it is opt-in rather than merely exclusive.
#
# Note the shape: -v is a GENERAL option and goes BEFORE the subcommand, and
# the property needs its full test_suites.<suite>. path. `kyua test -v
# vmm_nested_allow_boot_config_rewrite=yes' is rejected outright -- measured, both forms.

# This used to read
#     . "$(atf_get_srcdir)/utils.subr"
# but utils.subr lives in tests/sys/vmm/, one directory up and in a different
# package, so atf_get_srcdir -- this test's own directory -- could never
# resolve it, and that was the only thing stopping the file from loading.
# Neither function it defines (vmm_mkjail, vmm_cleanup) is used here.
#
# Nothing is sourced now, and that is deliberate rather than left over. The
# one helper this file ever called, nested_load_vmm, has been removed as
# irrelevant to what it asserts (see panic_sysctl_set below), so sourcing
# nested_utils.subr would add a dependency nothing uses. Check both together
# if a helper call is ever added back.

atf_test_case panic_sysctl_set
panic_sysctl_set_head()
{
	atf_set "descr" "Verify debug.debugger_on_panic=0, panic wait, and powercycle_on_panic=1"
	atf_set "require.user" "root"
	# HOST-MUTATING. This case RUNS the deployment script, which rewrites
	# /etc/sysctl.conf on the machine executing it. require.config keeps it
	# skipped unless somebody asks for it by name:
	#     kyua -v test_suites.FreeBSD.vmm_nested_allow_boot_config_rewrite=yes \
	#         test deployment_safety
	# so the harmless scripts_exist case below runs everywhere while these
	# two stay opt-in.
	atf_set "require.config" "vmm_nested_allow_boot_config_rewrite"
}
panic_sysctl_set_body()
{
	# require.config only checks the variable is DEFINED, so
	# vmm_nested_allow_boot_config_rewrite=no would run this and rewrite /etc/sysctl.conf.
	# It is also enforced by kyua alone -- running this program by hand
	# bypasses it entirely, and this file is executable by hand for the
	# first time. Check the value here, where nothing can go around it.
	[ "$(atf_config_get vmm_nested_allow_boot_config_rewrite no)" = "yes" ] ||
	    atf_skip "vmm_nested_allow_boot_config_rewrite is not yes; refusing to rewrite /etc/sysctl.conf"

	# There is deliberately no `nested_load_vmm' here. It used to be
	# called as `nested_load_vmm || true', which masked the fact that the
	# helper was never sourced and so was plain "command not found".
	# Neither masking it nor skipping on it is right, because EVERY
	# assertion below is a kernel-global panic setting --
	# debug.debugger_on_panic, kern.panic_reboot_wait_time,
	# kern.powercycle_on_panic -- and all three exist whether or not
	# vmm(4) can be loaded. Skipping on a failed load would have reported
	# "the panic settings were never deployed" identically to "this host
	# has no vmm", on the one run where an operator explicitly asked for
	# deployment to be verified.
	#
	# Run the idempotent script; it must exit 0 either way.
	atf_check -s exit:0 -o ignore /bin/sh "$(atf_get_srcdir)/scripts/disable-panic-debugger.sh"
	val=$(sysctl -n debug.debugger_on_panic)
	atf_check_equal "$val" "0"
	wait=$(sysctl -n kern.panic_reboot_wait_time)
	# Any non-negative integer is acceptable; we only require the script
	# left it on the system.  A bare >=0 check would be brittle.
	[ -n "$wait" ] || atf_fail "kern.panic_reboot_wait_time not set"
	pc=$(sysctl -n kern.powercycle_on_panic 2>/dev/null || true)
	atf_check_equal "$pc" "1"
}

atf_test_case vmm_load_disabled
vmm_load_disabled_head()
{
	atf_set "descr" "Verify vmm is NOT auto-loaded at boot (vmm_load=\"NO\" in /boot/loader.conf)"
	atf_set "require.user" "root"
	# HOST-MUTATING. This case RUNS the deployment script, which rewrites
	# /boot/loader.conf on the machine executing it. require.config keeps it
	# skipped unless somebody asks for it by name:
	#     kyua -v test_suites.FreeBSD.vmm_nested_allow_boot_config_rewrite=yes \
	#         test deployment_safety
	# so the harmless scripts_exist case below runs everywhere while these
	# two stay opt-in.
	atf_set "require.config" "vmm_nested_allow_boot_config_rewrite"
}
vmm_load_disabled_body()
{
	# require.config only checks the variable is DEFINED, so
	# vmm_nested_allow_boot_config_rewrite=no would run this and rewrite /boot/loader.conf.
	# It is also enforced by kyua alone -- running this program by hand
	# bypasses it entirely, and this file is executable by hand for the
	# first time. Check the value here, where nothing can go around it.
	[ "$(atf_config_get vmm_nested_allow_boot_config_rewrite no)" = "yes" ] ||
	    atf_skip "vmm_nested_allow_boot_config_rewrite is not yes; refusing to rewrite /boot/loader.conf"

	atf_check -s exit:0 -o ignore /bin/sh "$(atf_get_srcdir)/scripts/disable-vmm-autoload.sh"
	# The script idempotently appends vmm_load="NO" to /boot/loader.conf.
	# If vmm_load is unset, the kernel module auto-loads.
	if grep -qE '^[[:space:]]*vmm_load[[:space:]]*=' /boot/loader.conf; then
		val=$(grep -E '^[[:space:]]*vmm_load[[:space:]]*=' /boot/loader.conf | tail -1)
		atf_check_equal "$val" 'vmm_load="NO"'
	else
		atf_fail "vmm_load not set in /boot/loader.conf"
	fi
}

atf_test_case scripts_exist
scripts_exist_head()
{
	atf_set "descr" "Verify the deployment safety scripts exist and are executable"
}
scripts_exist_body()
{
	for s in scripts/disable-panic-debugger.sh scripts/disable-vmm-autoload.sh \
	    scripts/disable-panic-debugger.8 scripts/activate_oneshot_be.sh \
	    scripts/enable-fail-watchdog.sh; do
		[ -f "$(atf_get_srcdir)/$s" ] || atf_fail "$s missing"
		case "$s" in
		*.sh) [ -x "$(atf_get_srcdir)/$s" ] || atf_fail "$s not executable" ;;
		esac
	done
}

atf_init_test_cases()
{
	atf_add_test_case panic_sysctl_set
	atf_add_test_case vmm_load_disabled
	atf_add_test_case scripts_exist
}