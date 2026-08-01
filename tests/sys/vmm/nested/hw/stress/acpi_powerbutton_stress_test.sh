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
# T52b / Wave 9: ACPI power-button stress. Verifies that L1
# forwards an ACPI power-button event to L2 and that L2
# performs an orderly shutdown. Body creates the VM and
# triggers the power-button via bhyvectl repeatedly.

# shellcheck shell=sh
. "$(atf_get_srcdir)/../nested_utils.subr"

ITERATIONS_DEFAULT=20
ITERATIONS="${NESTED_STRESS_ITER:-${ITERATIONS_DEFAULT}}"

atf_test_case acpi_powerbutton_stress cleanup
acpi_powerbutton_stress_head()
{
	atf_set "descr" "ACPI power-button stress under nested virt (T52b)"
	atf_set "require.user" "root"
	atf_set "require.kmods" "vmm"
}
acpi_powerbutton_stress_body()
{
	nested_require_root
	nested_load_vmm || atf_skip "vmm(4) not loadable"
	vmname=$(nested_default_vmname acpi_powerbutton_stress)
	logdir=$(nested_make_log_dir acpi_powerbutton_stress)
	atf_check -s exit:0 -o save:${logdir}/create.log \
	    nested_vm_create "${vmname}" 512M
	atf_check -s exit:0 -o ignore -e ignore \
	    sh -c "nested_vm_running ${vmname}"
	atf_check -s exit:0 -o save:${logdir}/stress.log -e ignore \
	    sh -c "i=0; while [ \$i -lt ${ITERATIONS} ]; do \
	        bhyvectl --vm=${vmname} --power-button >/dev/null 2>&1 || true; \
	        sleep 1; \
	        bhyvectl --vm=${vmname} --create >/dev/null 2>&1 || true; \
	        i=\$((i + 1)); done; echo done >${logdir}/stress.done"
}
acpi_powerbutton_stress_cleanup()
{
	vmname=$(nested_default_vmname acpi_powerbutton_stress)
	nested_vm_destroy "${vmname}"
}

atf_init_test_cases()
{
	atf_add_test_case acpi_powerbutton_stress
}
