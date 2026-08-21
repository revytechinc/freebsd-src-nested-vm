#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 The FreeBSD Foundation
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

# shellcheck disable=SC1091
. "$(atf_get_srcdir)/utils.subr"

atf_test_case panic_sysctl_set
panic_sysctl_set_head()
{
	atf_set "descr" "Verify debug.debugger_on_panic=0, panic wait, and powercycle_on_panic=1"
	atf_set "require.user" "root"
}
panic_sysctl_set_body()
{
	# Run the idempotent script; it must exit 0 either way.
	nested_load_vmm || true
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
}
vmm_load_disabled_body()
{
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