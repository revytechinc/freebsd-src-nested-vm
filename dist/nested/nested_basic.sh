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
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
# DAMAGE.
#

# shellcheck shell=sh
#
# shellcheck disable=SC1091
. "$(atf_get_srcdir)/nested_utils.subr"

atf_test_case nested_basic cleanup
nested_basic_head()
{
	atf_set "descr" "Nested-VMM harness: vmm loads and hw.vmm.nested.enable defaults to 0"
	atf_set "require.user" "root"
	atf_set "require.kmods" "vmm"
}
nested_basic_body()
{
	nested_load_vmm
	atf_check -s exit:0 -o ignore -e ignore kldstat -q -m vmm

	enable=$(nested_sysctl_get enable)
	if [ -z "${enable}" ]; then
		atf_fail "hw.vmm.nested.enable is not exposed by the running kernel"
	fi
	atf_check_equal "${enable}" "0"
}
nested_basic_cleanup()
{
	# No persistent state to clean up.  The module stays loaded: it is a
	# prerequisite for the rest of the nested-vmm suite and removing it
	# here would race with parallel ATF runs.
	:
}

atf_init_test_cases()
{
	atf_add_test_case nested_basic
}