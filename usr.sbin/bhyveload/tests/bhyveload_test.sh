#
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
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

# Tests for bhyveload(8).
#
# The argument-handling cases need neither root nor vmm(4).  The rest create a
# real VM, so they require both, and each destroys the VM it made -- including
# on failure, via the cleanup routine, so a failing case cannot strand a VM and
# make every later case fail too.
#
# The VM cases load the running host's own kernel with -h /.  That needs no
# guest image and no bootable disk, which keeps them runnable anywhere rather
# than only on a machine with test media.

BHYVELOAD=${BHYVELOAD:-/usr/sbin/bhyveload}

# A VM name fixed per test case.  It must NOT depend on $$: atf-sh runs a
# case's body and its cleanup routine as separate invocations of the test
# program, so a pid-derived name differs between the two, cleanup looks for a
# VM that never existed, and every run leaks the VM the body created.  VM names
# are a single global namespace, which is why this suite is marked exclusive;
# with that, a fixed name per case is unambiguous.
vmname()
{
	echo "bhyveload_test_$1"
}

destroy_vm()
{
	if [ -e "/dev/vmm/$1" ]; then
		bhyvectl --destroy --vm="$1" >/dev/null 2>&1 || true
	fi
}

# Start from a known state: a run killed before its cleanup could leave the VM
# behind, and every case below asserts on whether its VM exists.
reset_vm()
{
	destroy_vm "$1"
	if [ -e "/dev/vmm/$1" ]; then
		# Fail rather than skip.  The name is fixed per case, so a VM
		# that cannot be removed makes this case unrunnable from now
		# on; skipping would hide that indefinitely behind a green
		# result, which is the failure mode this suite exists to avoid.
		atf_fail "leftover VM $1 could not be destroyed"
	fi
}

require_vmm()
{
	if [ ! -e /dev/vmmctl ]; then
		atf_skip "vmm(4) is not loaded"
	fi
}

# --------------------------------------------------------------------------
# Argument handling.  No privileges, no vmm(4).
# --------------------------------------------------------------------------

atf_test_case usage_without_arguments
usage_without_arguments_head()
{
	atf_set "descr" "bhyveload with no arguments prints usage and fails"
}
usage_without_arguments_body()
{
	atf_check -s exit:1 -e match:"usage: bhyveload" -o empty "$BHYVELOAD"
}

atf_test_case rejects_unknown_option cleanup
rejects_unknown_option_head()
{
	atf_set "descr" "an unknown option is rejected, with usage"
}
rejects_unknown_option_body()
{
	# -Z is not, and should not become, a bhyveload option.
	# Deliberately not matching getopt(3)'s wording: that string is libc's,
	# not bhyveload's, and would break this case for a reason unrelated to
	# what it protects. The invariant is that the option is refused and
	# nothing is created.
	atf_check -s exit:1 -e not-empty -o empty \
	    "$BHYVELOAD" -Z "$(vmname unknownopt)"
	# getopt rejects -Z before anything is created; assert that.
	if [ -e "/dev/vmm/$(vmname unknownopt)" ]; then
		atf_fail "a rejected option still created a VM"
	fi
}
rejects_unknown_option_cleanup()
{
	destroy_vm "$(vmname unknownopt)"
}

# CloudBSD-specific: -N was a per-VM nested-virtualization opt-in that this
# tree removed, because nesting is host-wide via hw.vmm.nested.enable and the
# flag only ever existed in our own builds. It must stay removed -- a silent
# reintroduction would put a meaningless bit back into the VM creation flags.
# This case has no counterpart upstream, where -N never existed.
atf_test_case rejects_removed_n_flag cleanup
rejects_removed_n_flag_head()
{
	atf_set "descr" "-N is gone and is rejected like any other unknown option"
}
rejects_removed_n_flag_body()
{
	atf_check -s exit:1 -e not-empty -o empty \
	    "$BHYVELOAD" -N "$(vmname removedn)"
	if [ -e "/dev/vmm/$(vmname removedn)" ]; then
		atf_fail "-N created a VM; the flag is supposed to be gone"
	fi
}
rejects_removed_n_flag_cleanup()
{
	destroy_vm "$(vmname removedn)"
}

atf_test_case rejects_bad_memsize cleanup
rejects_bad_memsize_head()
{
	atf_set "descr" "an unparseable -m argument is rejected before any VM is made"
}
rejects_bad_memsize_body()
{
	atf_check -s exit:64 -e not-empty "$BHYVELOAD" -m notasize -h / "$(vmname badmem)"
	# The size is parsed while options are handled, before the VM exists.
	if [ -e "/dev/vmm/$(vmname badmem)" ]; then
		atf_fail "an unparseable -m still created a VM"
	fi
}
rejects_bad_memsize_cleanup()
{
	destroy_vm "$(vmname badmem)"
}

atf_test_case rejects_missing_disk cleanup
rejects_missing_disk_head()
{
	atf_set "descr" "a -d path that does not exist is reported, and no VM is left behind"
	atf_set "require.user" "root"
}
rejects_missing_disk_body()
{
	require_vmm
	vm=$(vmname missingdisk)
	reset_vm "$vm"
	atf_check -s exit:64 -e match:"Could not open" \
	    "$BHYVELOAD" -m 256M -h / -d /nonexistent/disk.img "$vm"
	# The disk is opened while options are parsed, so the failure must come
	# before the VM is created. A VM here would be a leak on an error path.
	if [ -e "/dev/vmm/$vm" ]; then
		atf_fail "bhyveload left /dev/vmm/$vm behind after failing"
	fi
}
rejects_missing_disk_cleanup()
{
	destroy_vm "$(vmname missingdisk)"
}

# --------------------------------------------------------------------------
# VM lifecycle.  These need root and vmm(4).
# --------------------------------------------------------------------------

atf_test_case creates_vm cleanup
creates_vm_head()
{
	atf_set "descr" "loading into a new name creates that VM"
	atf_set "require.user" "root"
}
creates_vm_body()
{
	require_vmm
	vm=$(vmname create)
	reset_vm "$vm"
	atf_check -s exit:0 -o ignore -e ignore \
	    "$BHYVELOAD" -m 256M -h / -e autoboot_delay=0 "$vm" </dev/null
	if [ ! -e "/dev/vmm/$vm" ]; then
		atf_fail "bhyveload succeeded but /dev/vmm/$vm does not exist"
	fi
}
creates_vm_cleanup()
{
	destroy_vm "$(vmname create)"
}

atf_test_case reloads_existing_vm cleanup
reloads_existing_vm_head()
{
	atf_set "descr" "loading again into an existing VM succeeds and reinitializes it"
	atf_set "require.user" "root"
}
reloads_existing_vm_body()
{
	require_vmm
	vm=$(vmname reload)
	reset_vm "$vm"

	# First load creates it.
	atf_check -s exit:0 -o ignore -e ignore \
	    "$BHYVELOAD" -m 256M -h / -e autoboot_delay=0 "$vm" </dev/null
	if [ ! -e "/dev/vmm/$vm" ]; then
		atf_fail "first load did not create /dev/vmm/$vm"
	fi

	# Second load must reuse and reinitialize rather than fail on EEXIST.
	# This is the path that decides whether a guest is booted into a clean
	# VM or into whatever state the previous load left; it is worth an
	# explicit test because nothing else exercises it.
	atf_check -s exit:0 -o ignore -e ignore \
	    "$BHYVELOAD" -m 256M -h / -e autoboot_delay=0 "$vm" </dev/null
	if [ ! -e "/dev/vmm/$vm" ]; then
		atf_fail "reload destroyed /dev/vmm/$vm instead of reusing it"
	fi
}
reloads_existing_vm_cleanup()
{
	destroy_vm "$(vmname reload)"
}

atf_test_case reports_bad_host_path cleanup
reports_bad_host_path_head()
{
	atf_set "descr" "a -h path that does not exist is reported rather than silently ignored"
	atf_set "require.user" "root"
}
reports_bad_host_path_body()
{
	require_vmm
	vm=$(vmname badhost)
	reset_vm "$vm"
	# The VM is created before the loader runs, so this exercises the
	# failure path *after* creation: it must report, not hang or succeed.
	atf_check -s exit:71 -o ignore -e ignore \
	    "$BHYVELOAD" -m 256M -h /nonexistent-host-path "$vm" </dev/null
}
reports_bad_host_path_cleanup()
{
	destroy_vm "$(vmname badhost)"
}

atf_init_test_cases()
{
	atf_add_test_case usage_without_arguments
	atf_add_test_case rejects_unknown_option
	atf_add_test_case rejects_bad_memsize
	atf_add_test_case rejects_removed_n_flag
	atf_add_test_case rejects_missing_disk
	atf_add_test_case creates_vm
	atf_add_test_case reloads_existing_vm
	atf_add_test_case reports_bad_host_path
}
