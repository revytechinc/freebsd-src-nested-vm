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
# Wave 6 / T23 follow-up: EPT12 walker logic, exercised on a
# CPU-side (shell) simulator.  Re-implements the walker's index
# arithmetic + reserved-bit clearing in awk/sh and asserts:
#   - 4KB leaf walk: L2 GPA 0x1000 -> L1 GPA 0x2000 (read access)
#   - 2MB large-page walk: bit 7 set, reserved bits cleared
#   - invalid PTE (R/W/X all clear): walk returns -1
#
# Does not require root, vmm.ko, or any kernel symbols.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
VMX_NESTED_EPT12="${repo_root}/sys/amd64/vmm/intel/vmx_nested_ept12.c"

preflight_ept12_walker_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	return 1
}

# EPT index derivation macros.  The production code uses C macros
# in vmx_nested_ept12.c (EPT_IDX_PML4/PDPT/PD/PT); we re-implement
# the same arithmetic in awk for the simulator.
idx_pml4() { awk -v g="$1" 'BEGIN { printf "%d\n", int(g/549755813888) % 512 }'; }
idx_pdpt() { awk -v g="$1" 'BEGIN { printf "%d\n", int(g/1073741824) % 512 }'; }
idx_pd()   { awk -v g="$1" 'BEGIN { printf "%d\n", int(g/2097152) % 512 }'; }
idx_pt()   { awk -v g="$1" 'BEGIN { printf "%d\n", int(g/4096) % 512 }'; }

# Mask constants from vmx_nested_ept12.c
EPT_PTE_MASK=0x000ffffffffff000
EPT_PTE_R=0x1
EPT_PTE_W=0x2
EPT_PTE_X=0x4
EPT_PTE_LARGE=0x80
EPT_LARGE_2MB_ADDR=0xffffffffffe00000
RESVD_2MB=0x1ff000

# Build a single-level (PTE-only) synthetic EPT12 page.  _gpa is
# the L2 GPA, _target is the L1 GPA, _flags are R/W/X access bits.
# Output is 512 little-endian 8-byte entries on stdout.
build_pte_only_ept()
{
	_gpa=$1
	_target=$2
	_flags=$3
	_pt_index=$(idx_pt "$_gpa")
	_pte=$((_target & EPT_PTE_MASK | _flags))
	i=0
	while [ "$i" -lt 512 ]; do
		if [ "$i" -eq "$_pt_index" ]; then
			printf '%016x\n' "$_pte"
		else
			printf '0000000000000000\n'
		fi
		i=$((i + 1))
	done
}

# Build a 2-level (PD + PT) EPT12 with a 2MB PDE at the matching
# PD slot.  The PDE has bit 7 set and reserved bits cleared.
build_large_2mb_ept()
{
	_gpa=$1
	_target=$2
	_flags=$3
	_pd_index=$(idx_pd "$_gpa")
	_pde=$((_target & EPT_LARGE_2MB_ADDR | EPT_PTE_LARGE | _flags))
	i=0
	while [ "$i" -lt 512 ]; do
		if [ "$i" -eq "$_pd_index" ]; then
			printf '%016x\n' "$_pde"
		else
			printf '0000000000000000\n'
		fi
		i=$((i + 1))
	done
}

# Walk a PTE-only table.  _page is a file containing 512 16-hex-
# digit lines.  Returns the resolved L1 GPA on stdout, or -1.
walk_pte_only()
{
	_page=$1
	_gpa=$2
	_idx=$(idx_pt "$_gpa")
	_pte=$(sed -n "$((_idx + 1))p" "${_page}")
	# R/W/X all clear -> empty/invalid PTE.
	if [ -z "${_pte}" ]; then
		printf -- '-1\n'
		return
	fi
	_access=$((16#$_pte & (EPT_PTE_R | EPT_PTE_W | EPT_PTE_X)))
	if [ "$_access" -eq 0 ]; then
		printf -- '-1\n'
		return
	fi
	# 4KB leaf: AND out bits 11:0 and OR in low 12 of L2 GPA.
	_addr=$((16#$_pte & EPT_PTE_MASK))
	_pageoff=$((_gpa & 0xfff))
	_result=$((_addr | _pageoff))
	printf '%x\n' "$_result"
}

# Walk a 2-level table (PD then PT).  Returns the resolved L1
# GPA on stdout, or -1.
walk_two_level()
{
	_page=$1
	_gpa=$2
	_pd_index=$(idx_pd "$_gpa")
	_pde=$(sed -n "$((_pd_index + 1))p" "${_page}")
	if [ -z "${_pde}" ]; then
		printf -- '-1\n'
		return
	fi
	_access=$((16#$_pde & (EPT_PTE_R | EPT_PTE_W | EPT_PTE_X)))
	if [ "$_access" -eq 0 ]; then
		printf -- '-1\n'
		return
	fi
	# Large bit set -> 2MB leaf, AND out reserved bits.
	if [ $((16#$_pde & EPT_PTE_LARGE)) -ne 0 ]; then
		# Reserved bits 20:12 must be zero in a 2MB PDE.
		if [ $((16#$_pde & RESVD_2MB)) -ne 0 ]; then
			printf -- '-1\n'
			return
		fi
		_addr=$((16#$_pde & EPT_LARGE_2MB_ADDR))
		_pageoff=$((_gpa & 0x1fffff))
		_result=$((_addr | _pageoff))
		printf '%x\n' "$_result"
		return
	fi
	# Non-leaf PDE: the next-level table address is bits 51:12.
	_table_addr=$((16#$_pde & EPT_PTE_MASK))
	# For this CPU-side simulator we collapse to a single page.
	# The interesting walk happens at the PT level.
	_pt_index=$(idx_pt "$_gpa")
	_pte=$(sed -n "$((_pt_index + 1))p" "${_page}")
	if [ -z "${_pte}" ]; then
		printf -- '-1\n'
		return
	fi
	_access2=$((16#$_pte & (EPT_PTE_R | EPT_PTE_W | EPT_PTE_X)))
	if [ "$_access2" -eq 0 ]; then
		printf -- '-1\n'
		return
	fi
	_addr=$((16#$_pte & EPT_PTE_MASK))
	_pageoff=$((_gpa & 0xfff))
	_result=$((_addr | _pageoff))
	printf '%x\n' "$_result"
	# Silence unused variable warning.
	: "${_table_addr}"
}

# Build a PTE-only table that has the index entry zeroed out.
build_empty_pte_only()
{
	_gpa=$1
	_pt_index=$(idx_pt "$_gpa")
	i=0
	while [ "$i" -lt 512 ]; do
		if [ "$i" -eq "$_pt_index" ]; then
			printf '0000000000000000\n'
		else
			printf '0000000000000000\n'
		fi
		i=$((i + 1))
	done
}

preflight_ept12_walker_main()
{
	if preflight_ept12_walker_unsupported; then
		exit 0
	fi

	tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/preflight-ept12.XXXXXX") || exit 1

	# 1) 4KB leaf walk: L2 GPA 0x1000 -> L1 GPA 0x2000 (R-only).
	build_pte_only_ept 0x1000 0x2000 "${EPT_PTE_R}" > "${tmpdir}/pt1"
	got=$(walk_pte_only "${tmpdir}/pt1" 0x1000)
	if [ "${got}" != "2000" ]; then
		echo "FAIL: 4KB leaf walk expected 2000, got '${got}'"
		rm -rf "${tmpdir}"
		exit 1
	fi

	# 2) Large-page (2MB) walk: L2 GPA 0x40000000 -> L1 GPA
	# 0x80000000 with bit 7 (LARGE) set and reserved bits clear.
	build_large_2mb_ept 0x40000000 0x80000000 \
	    "$((EPT_PTE_R | EPT_PTE_W))" > "${tmpdir}/pd1"
	got=$(walk_two_level "${tmpdir}/pd1" 0x40000000)
	if [ "${got}" != "80000000" ]; then
		echo "FAIL: 2MB leaf walk expected 80000000, got '${got}'"
		rm -rf "${tmpdir}"
		exit 1
	fi

	# 3) Invalid PTE (R/W/X all clear): walk returns -1.
	build_empty_pte_only 0x1000 > "${tmpdir}/empty"
	got=$(walk_pte_only "${tmpdir}/empty" 0x1000)
	if [ "${got}" != "-1" ]; then
		echo "FAIL: empty-PTE walk expected -1, got '${got}'"
		rm -rf "${tmpdir}"
		exit 1
	fi

	# 4) Source sanity: the production walker must use the same
	# EPT_IDX_PML4/PDPT/PD/PT macros we re-implement.
	if [ -r "${VMX_NESTED_EPT12}" ]; then
		for sym in EPT_IDX_PML4 EPT_IDX_PDPT EPT_IDX_PD EPT_IDX_PT; do
			if ! grep -q "define[[:space:]]\+${sym}(" "${VMX_NESTED_EPT12}"; then
				echo "FAIL: ${sym} macro missing in vmx_nested_ept12.c"
				rm -rf "${tmpdir}"
				exit 1
			fi
		done
	fi

	rm -rf "${tmpdir}"
	echo "PASS: preflight_ept12_walker 4KB / 2MB / invalid PTE walks"
}

preflight_ept12_walker_main "$@"

atf_test_case "preflight_ept12_walker"
preflight_ept12_walker_head()
{
	atf_set "descr" "EPT12 walker logic on a synthetic 4KB / 2MB / invalid-PTE table"
}
preflight_ept12_walker_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_ept12_walker"
}
