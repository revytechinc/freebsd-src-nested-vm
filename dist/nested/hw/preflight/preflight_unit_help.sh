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
# T0a / Wave 0a: preflight unit help. Confirms tools/preflight.sh runs
# without root or vmm.ko, prints the expected banner, and ends with the
# Verdict: section. Pure smoke test of the script's basic surface.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
PREFLIGHT="${repo_root}/tools/preflight.sh"

preflight_unit_help_unsupported()
{
	if [ ! -r "${PREFLIGHT}" ]; then
		echo "SKIP: tools/preflight.sh not present at ${PREFLIGHT}"
		return 0
	fi
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	return 1
}

preflight_unit_help_main()
{
	if preflight_unit_help_unsupported; then
		exit 0
	fi

	# Run preflight against the host's real dmesg.boot if readable,
	# otherwise fall back to a synthetic fixture so the test still works
	# on non-FreeBSD CI hosts.
	if [ -r /var/run/dmesg.boot ] && grep -q '^CPU:' /var/run/dmesg.boot 2>/dev/null; then
		out=$(sh "${PREFLIGHT}" 2>&1) || rc=$?
	else
		tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/preflight-help.XXXXXX") || exit 1
		script_copy="${tmpdir}/preflight.sh"
		cp "${PREFLIGHT}" "${script_copy}"
		chmod +x "${script_copy}"
		dmesg_path="${tmpdir}/dmesg.boot"
		cat > "${dmesg_path}" <<'DMESG'
CPU: Intel(R) Core(TM) synthetic
  Origin="GenuineIntel"  Id=0x806d1  Family=0x6  Model=0x8d  Stepping=1
  Features=0xbfebfbff
  Features2=0x7ffafbff
  Structured Extended Features=0xf3bfa7eb
DMESG
		sed -i.bak "s|PREFLIGHT_DMESG=/var/run/dmesg.boot|PREFLIGHT_DMESG=${dmesg_path}|" "${script_copy}"
		out=$(PREFLIGHT_DMESG="${dmesg_path}" sh "${script_copy}" 2>&1) || rc=$?
		rm -rf "${tmpdir}"
	fi
	rc=${rc:-0}

	if ! printf '%s\n' "${out}" | grep -q "vmm.preflight  v2.0"; then
		echo "FAIL: banner line not found in preflight output"
		printf '%s\n' "${out}" | head -20
		exit 1
	fi

	if ! printf '%s\n' "${out}" | grep -qE '^---------- verdict'; then
		echo "FAIL: verdict section missing"
		printf '%s\n' "${out}" | tail -20
		exit 1
	fi

	echo "PASS: preflight_unit_help banner + verdict sections present"
}

preflight_unit_help_main "$@"

atf_test_case "preflight_unit_help"
preflight_unit_help_head()
{
	atf_set "descr" "preflight.sh runs without root/vmm and prints the v2.0 banner + Verdict section"
}
preflight_unit_help_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_unit_help"
}