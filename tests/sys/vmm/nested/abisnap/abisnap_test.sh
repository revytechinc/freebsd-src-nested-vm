#-
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
#
# The atf front end for abisnap.sh.
#
# abisnap.sh is a TOOL, not a test: it parses --check/--regen-golden/
# --self-check and has no atf_test_case anywhere in it. It was nonetheless
# listed as ATF_TESTS_SH, so kyua ran it with -l to list its cases, the
# argument parser rejected the flag, and the program exited non-zero before
# printing anything kyua could parse -- reported as "broken: Test program did
# not exit cleanly". It had never run, because the directory was not reachable
# from any Kyuafile.
#
# Keeping the tool a tool and putting the atf surface in its own file is the
# arrangement the rest of the tree uses, and it leaves --regen-golden where a
# person can still invoke it by hand. Regenerating a golden file is not
# something a test run should ever do.

golden_file_is_wellformed_head()
{
	atf_set "descr" "abisnap --self-check: the golden ABI file parses" \
	    "and carries every required section"
}
golden_file_is_wellformed_body()
{
	# --self-check reads only the golden file, so this runs anywhere: no
	# vmm(4), no hypervisor, no root.
	atf_check -s exit:0 -o ignore -e ignore \
	    sh "$(atf_get_srcdir)/abisnap.sh" --self-check
}

abi_matches_golden_head()
{
	atf_set "descr" "abisnap --check: the live nested-virt ABI still" \
	    "matches the recorded golden snapshot"
	atf_set "require.user" "root"
}
abi_matches_golden_body()
{
	# Exit 3 is abisnap's documented "bhyve/vmm not available" status --
	# see the exit-code table in abisnap.sh. That is a reason not to have
	# run, so it becomes a SKIP. Anything else non-zero is a real ABI
	# difference and must fail: this test exists to notice exactly that,
	# and turning every non-zero status into a skip would make it a check
	# that cannot fail.
	sh "$(atf_get_srcdir)/abisnap.sh" --check >abisnap.out 2>&1
	_rc=$?
	case "${_rc}" in
	0)
		;;
	3)
		atf_skip "abisnap: vmm(4)/dump helper unavailable on this host"
		;;
	*)
		cat abisnap.out
		atf_fail "abisnap --check exited ${_rc}: the live ABI differs from the golden snapshot, or the tool failed"
		;;
	esac
}

atf_init_test_cases()
{
	atf_add_test_case golden_file_is_wellformed
	atf_add_test_case abi_matches_golden
}
