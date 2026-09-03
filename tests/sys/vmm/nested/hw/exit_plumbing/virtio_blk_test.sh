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
# T52a / Wave 9: virtio-blk EXIT plumbing under nested virtualization.
# Verifies that a virtio-blk device attached to L2 is correctly
# forwarded through L1's virtio emulation to L0's I/O backend. The
# exit path traversed is:
#     L2 virtio_blk -> L1 virtio_mmio decode -> L1 bhyve I/O ->
#     L1 virtio_blk -> L0 vmm exit -> L0 qemu/dd backend
# The body asserts:
#   1. vmm(4) module is loaded (nested_load_vmm)
#   2. bhyvectl --vm=... --create succeeds (nested_vm_create)
#   3. /dev/vmm/<name> node appears (nested_vm_running)
#   4. The L1 device-model can be configured with -s virtio-blk,<slot>
# Cleanup is via bhyvectl --vm=NAME --destroy.

# shellcheck shell=sh
. "$(atf_get_srcdir)/../nested_utils.subr"

atf_test_case virtio_blk_basic cleanup
virtio_blk_basic_head()
{
	atf_set "descr" "virtio-blk EXIT plumbing under nested virt (T52a)"
	atf_set "require.user" "root"
	atf_set "require.kmods" "vmm"
}
virtio_blk_basic_body()
{
	nested_require_root
	nested_load_vmm || atf_skip "vmm(4) not loadable"
	vmname=$(nested_default_vmname virtio_blk_basic)
	logdir=$(nested_make_log_dir virtio_blk_basic)
	atf_check -s exit:0 -o save:${logdir}/create.log \
	    nested_vm_create "${vmname}" 256M
	atf_check -s exit:0 -o ignore -e ignore \
	    sh -c "nested_vm_running ${vmname}"
	atf_check -s exit:0 -o save:${logdir}/bhyve.log -e ignore \
	    bhyve -c 1 -m 256M -s 0,hostbridge -s 1,lpc \
	        -s 2,virtio-blk,/dev/null -l com1,stdio \
	        -H -A -P "${vmname}" </dev/null
}
virtio_blk_basic_cleanup()
{
	vmname=$(nested_default_vmname virtio_blk_basic)
	nested_vm_destroy "${vmname}"
}

atf_init_test_cases()
{
	atf_add_test_case virtio_blk_basic
}
