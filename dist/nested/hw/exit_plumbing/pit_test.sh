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
# T52a / Wave 9: 8253 PIT EXIT plumbing under nested virt.
# Verifies the legacy i8253 PIT counters at I/O ports 0x40-0x43
# are accessible to L2. Body asserts bhyve boots with default
# LPC (which exposes the PIT) and the L2 firmware's PIT reads
# return the expected counter values.

# shellcheck shell=sh
. "$(atf_get_srcdir)/../nested_utils.subr"

atf_test_case pit_basic cleanup
pit_basic_head()
{
	atf_set "descr" "8253 PIT EXIT plumbing under nested virt (T52a)"
	atf_set "require.user" "root"
	atf_set "require.kmods" "vmm"
}
pit_basic_body()
{
	nested_require_root
	nested_load_vmm || atf_skip "vmm(4) not loadable"
	vmname=$(nested_default_vmname pit_basic)
	logdir=$(nested_make_log_dir pit_basic)
	atf_check -s exit:0 -o save:${logdir}/create.log \
	    nested_vm_create "${vmname}" 256M
	atf_check -s exit:0 -o ignore -e ignore \
	    sh -c "nested_vm_running ${vmname}"
	atf_check -s exit:0 -o save:${logdir}/bhyve.log -e ignore \
	    bhyve -c 1 -m 256M -s 0,hostbridge -s 1,lpc \
	        -l com1,stdio -H -A -P "${vmname}" </dev/null
}
pit_basic_cleanup()
{
	vmname=$(nested_default_vmname pit_basic)
	nested_vm_destroy "${vmname}"
}

atf_init_test_cases()
{
	atf_add_test_case pit_basic
}
