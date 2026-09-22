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
# There is no per-VM nested opt-in any more: the userland constant
# VMMAPI_OPEN_CREATE_NESTED was removed with the -N flag it existed to
# carry, and nesting is host-wide via hw.vmm.nested.enable.  The kernel
# still tolerates the old VMMCTL_CREATE_NESTED ioctl bit so an older
# binary keeps working.  This smoke test guards the sysctl surface.
#
# Reference: KVM selftests at tools/testing/selftests/kvm/x86_64/svm_*
# are DESIGN REFERENCE ONLY (GPL); this test is original BSD code.

atf_test_case svm_basic_smoke cleanup
svm_basic_smoke_head()
{
	atf_set "descr" "vmm(4) nested-virt userland smoke test (amd64 SVM)"
	atf_set "require.arch" "amd64"
	atf_set "require.kmods" "vmm"
	atf_set "require.user" "root"
	# Exclusivity is declared in the Makefile as TEST_METADATA, which is
	# how the rest of the tree spells it (tests/sys/netinet, net/routing,
	# net/wg). Not as an atf_set property: atf-sh ACCEPTS an arbitrary key
	# and passes it through, and KYUA is what then rejects it -- "Unknown
	# test case metadata property" -- breaking the whole test program.
	# Measured both ways: atf-sh runs such a case fine, kyua calls it
	# broken. So the mistake is invisible to the obvious hand check.
}

svm_basic_smoke_body()
{
	local saved

	# Two different questions, asked separately, because one `sysctl -n`
	# failure would otherwise mean either.
	#
	# require.kmods proves vmm(4) is LOADED -- not that it is OUR vmm(4).
	# A stock kernel has no hw.vmm.nested.* at all, and failing there would
	# report "the nested surface is broken" about a machine that simply
	# does not carry it. So ask whether the NAME exists first: -N prints
	# the name and nothing else, and fails only when the OID is unknown.
	# The PARENT node is the independent signal, and it has to be, because
	# keying on hw.vmm.nested.enable itself cannot tell "this kernel never
	# had the OID" from "this kernel's OID has gone" -- and the second is
	# the regression this test exists to catch. Skipping on both would
	# retire the test silently, since kyua does not count a skip as a
	# failure.
	if ! sysctl -Nq hw.vmm.nested >/dev/null 2>&1; then
		atf_skip "no hw.vmm.nested node in this kernel"
	fi

	# The tree's node IS here, so the gate must be too. Missing now means
	# it was removed or renamed, which is a regression and must FAIL.
	sysctl -Nq hw.vmm.nested.enable >/dev/null 2>&1 ||
	    atf_fail "hw.vmm.nested exists but hw.vmm.nested.enable does not -- the gate was removed or renamed"

	saved=$(sysctl -n hw.vmm.nested.enable) ||
	    atf_fail "hw.vmm.nested.enable exists but cannot be read"

	# Persist for the cleanup routine. A shell trap does not survive the
	# SIGKILL a kyua timeout sends, and this knob is host-global: left at
	# 1, it silently changes what every later test on this machine
	# measures.
	printf '%s\n' "$saved" > svm_basic.saved ||
	    atf_fail "cannot persist the saved value; refusing to change a host-global knob with no way to put it back"

	# BOTH guards, because they cover different holes and neither covers
	# the other. The cleanup routine runs only under kyua, so it does
	# nothing for a hand run -- and a hand run is exactly how this file is
	# now usable. This trap covers that: any atf_check below that fails
	# exits the shell, and the trap fires. It cannot survive the SIGKILL a
	# kyua timeout sends, which is what cleanup is for.
	# Expanded NOW, not when the trap fires: ${saved} is a `local', and
	# whether a shell still has function locals in scope while running an
	# EXIT trap varies between shells. Signals as well as EXIT, because a
	# FreeBSD sh EXIT trap does not run when the shell is killed by
	# SIGINT/TERM/HUP -- a Ctrl-C between the write and the restore would
	# otherwise leave the knob at 1. stdout is silenced, stderr is NOT: a
	# restore that fails must say so.
	trap "sysctl hw.vmm.nested.enable='${saved}' >/dev/null" EXIT INT TERM HUP
	atf_check -s exit:0 -o ignore -e ignore \
	    sysctl hw.vmm.nested.enable=1
	atf_check -s exit:0 -o match:".*1.*" -o ignore -e ignore \
	    sysctl hw.vmm.nested.enable

	# Restore in the body too, and delete the saved file below, so that a
	# passing run genuinely leaves nothing behind for cleanup to act on;
	# cleanup is the belt for the cases the body never reaches.
	atf_check -s exit:0 -o ignore -e ignore \
	    sysctl hw.vmm.nested.enable="${saved}"
	trap - EXIT INT TERM HUP

	# Remove it, or a later cleanup in this directory -- a hand run leaves
	# the file in $PWD, typically /usr/tests/sys/vmm/nested -- would write
	# a stale value back into a host-global knob.
	rm -f svm_basic.saved
}

svm_basic_smoke_cleanup()
{
	local saved

	# No file at all is legitimate: the body may have skipped before it
	# ever wrote one, in which case nothing was changed.
	[ -f svm_basic.saved ] || return 0

	# A file that exists but is EMPTY is not legitimate -- the body only
	# creates it immediately before changing the knob -- so returning 0
	# here would report "restored" for a host left at 1.
	saved=$(cat svm_basic.saved)
	if [ -z "$saved" ]; then
		echo "svm_basic.saved is empty; hw.vmm.nested.enable may be left at 1" >&2
		return 1
	fi

	# NOT `>/dev/null 2>&1 || true'. Cleanup is the only path after a
	# timeout kill, so a restore that fails here leaves the host-global
	# knob at 1 -- exactly the outcome this routine exists to prevent --
	# and silencing it would report that identically to success. Let it
	# be loud: kyua marks the case broken and prints sysctl's own words.
	sysctl hw.vmm.nested.enable="${saved}"
}

atf_init_test_cases()
{
	atf_add_test_case svm_basic_smoke
}