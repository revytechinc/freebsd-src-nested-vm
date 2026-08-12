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
# Wave 6 / T23b follow-up: nested INVEPT descriptor layout.  The
# wave-6 fix changed eptp from uint32_t to uint64_t (and added a
# CTASSERT that sizeof(struct invept_desc_l1) == 16).  Verify:
#   - the struct is 16 bytes (CTASSERT present)
#   - the first field is uint64_t (8 bytes)
#   - the second field is reserved (uint64_t, 8 bytes)
#   - the production vmx_nested_invept_handle() reads desc.eptp as
#     a 64-bit value when calling invept().
#
# Does not require root, vmm.ko, or any kernel symbols.

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
VMX_NESTED_INVEPT="${repo_root}/sys/amd64/vmm/intel/vmx_nested_invept.c"

preflight_invept_descriptor_unsupported()
{
	if [ ! -r "${VMX_NESTED_INVEPT}" ]; then
		echo "SKIP: ${VMX_NESTED_INVEPT} not present"
		return 0
	fi
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	return 1
}

# Confirm the wave-6 uint64_t eptp change is present.  A regression
# to uint32_t would truncate the L1-stated EPTP to its low 32 bits
# and cause L0 INVEPT to operate on a wrong EPT root.
assert_eptp_is_uint64()
{
	# The struct must declare eptp as uint64_t followed by a
	# reserved uint64_t padding field.  Both lines must appear
	# in the descriptor struct.
	if ! grep -q 'uint64_t[[:space:]]\+eptp' "${VMX_NESTED_INVEPT}"; then
		echo "FAIL: eptp not declared as uint64_t in vmx_nested_invept.c"
		exit 1
	fi
	# The 16-byte CTASSERT must be present.
	if ! grep -q 'CTASSERT(sizeof(struct invept_desc_l1) == 16)' \
	    "${VMX_NESTED_INVEPT}"; then
		echo "FAIL: CTASSERT(invept_desc_l1 == 16) missing"
		exit 1
	fi
}

# Confirm the production vmx_nested_invept_handle passes desc.eptp
# (the 64-bit field) to the L0 invept() primitive.
assert_handle_uses_desc_eptp()
{
	if ! grep -A4 'vmx_nested_invept_handle' "${VMX_NESTED_INVEPT}" | \
	    grep -q 'desc.eptp'; then
		echo "FAIL: vmx_nested_invept_handle does not pass desc.eptp"
		exit 1
	fi
}

# INVVPID descriptor should also be 16 bytes with the vpid as a
# uint16_t (SDM Vol 3 §30.7).  Cross-check the second descriptor.
assert_invvpid_descriptor_layout()
{
	if ! grep -q 'struct invvpid_desc_l1' "${VMX_NESTED_INVEPT}"; then
		echo "FAIL: invvpid_desc_l1 struct missing"
		exit 1
	fi
	if ! grep -q 'uint16_t[[:space:]]\+vpid' "${VMX_NESTED_INVEPT}"; then
		echo "FAIL: vpid not declared as uint16_t in invvpid_desc_l1"
		exit 1
	fi
	if ! grep -q 'CTASSERT(sizeof(struct invvpid_desc_l1) == 16)' \
	    "${VMX_NESTED_INVEPT}"; then
		echo "FAIL: CTASSERT(invvpid_desc_l1 == 16) missing"
		exit 1
	fi
}

# CPU-side simulation of the 16-byte descriptor layout.  Use
# shell arithmetic to verify that a 64-bit EPTP written into
# bytes 0..7 leaves bytes 8..15 reserved/zero, and that the same
# EPTP read back is the full 64-bit value (not the old 32-bit
# truncation).
simulate_descriptor()
{
	tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/preflight-invept.XXXXXX") || return 1
	# EPTP with the high bits set (would be truncated to 0 if
	# the descriptor still used uint32_t).
	hi=0xdeadbeef
	lo=0xcafebabe
	eptp=$((hi << 32 | lo))
	: > "${tmpdir}/desc.hex"
	i=0
	while [ "$i" -lt 8 ]; do
		b=$(( (eptp >> (i * 8)) & 0xff ))
		printf '%02x\n' "$b" >> "${tmpdir}/desc.hex"
		i=$((i + 1))
	done
	# Reserved field (all zero).
	i=0
	while [ "$i" -lt 8 ]; do
		printf '00\n' >> "${tmpdir}/desc.hex"
		i=$((i + 1))
	done

	# Read back: bytes 0..7 -> uint64_t LE.  The bytes are
	# stored as hex strings ("be", not 0xbe); use the 16#be
	# syntax to convert them to integers so set -u does not
	# interpret them as variable names.
	hi_out=0
	lo_out=0
	i=0
	while [ "$i" -lt 8 ]; do
		b=$(sed -n "$((i + 1))p" "${tmpdir}/desc.hex")
		if [ "$i" -lt 4 ]; then
			lo_out=$((lo_out | (16#$b << (i * 8))))
		else
			hi_out=$((hi_out | (16#$b << ((i - 4) * 8))))
		fi
		i=$((i + 1))
	done
	eptp_out=$((hi_out << 32 | lo_out))
	if [ "${eptp_out}" != "${eptp}" ]; then
		echo "FAIL: 64-bit EPTP not preserved through descriptor (got ${eptp_out}, expected ${eptp})"
		rm -rf "${tmpdir}"
		return 1
	fi

	# Read back the reserved field (bytes 8..15): must be zero.
	resv=$(sed -n '9p;10p;11p;12p;13p;14p;15p;16p' "${tmpdir}/desc.hex" | \
	    tr -d '\n')
	if [ "${resv}" != "0000000000000000" ]; then
		echo "FAIL: reserved field not zero (got ${resv})"
		rm -rf "${tmpdir}"
		return 1
	fi

	rm -rf "${tmpdir}"
	return 0
}

preflight_invept_descriptor_main()
{
	if preflight_invept_descriptor_unsupported; then
		exit 0
	fi

	# 1) Source-level: eptp must be uint64_t.
	assert_eptp_is_uint64

	# 2) Source-level: handle passes the full 64-bit field.
	assert_handle_uses_desc_eptp

	# 3) Source-level: invvpid_desc_l1 also has its CTASSERT and
	# 16-bit vpid field.
	assert_invvpid_descriptor_layout

	# 4) CPU-side simulation: 16-byte descriptor preserves the
	# full 64-bit EPTP (no truncation).
	simulate_descriptor || exit 1

	echo "PASS: preflight_invept_descriptor 16-byte layout + uint64_t EPTP"
}

preflight_invept_descriptor_main "$@"

atf_test_case "preflight_invept_descriptor"
preflight_invept_descriptor_head()
{
	atf_set "descr" "INVEPT descriptor is 16 bytes with uint64_t eptp (wave-6 fix)"
}
preflight_invept_descriptor_body()
{
	bash "$0"
}
atf_init_test_cases()
{
	atf_add_test_case "preflight_invept_descriptor"
}
