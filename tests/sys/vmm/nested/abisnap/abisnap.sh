#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
# All rights reserved.
#
# Wave 7 / T39 — Nested-virt ABI snapshot test (golden comparator).
#
# This script dumps three pieces of the L0 (bhyve) ABI:
#
#   1. VMCS12 layout  - the nVMX shadow VMCS that L1 hypervisors
#                       read/write when they VMREAD/VMWRITE.
#
#   2. VMCB12 layout  - the nSVM shadow VMCB that L1 hypervisors
#                       read/write via VMLOAD/VMSAVE.
#
#   3. Hyper-V MSR list - the MSRs exposed via the Hyper-V TLFS
#                          interface (0x40000000-0x4000FFFF range
#                          plus 0xC0000002 ranges).
#
# The dump is compared against the committed golden file
# `golden_abisnap.txt`.  If the diff is non-empty, the test FAILS.
# This is the "loud failure" required by the plan: any future ABI
# change to the L0 will be caught by the snapshot test.
#
# Modes:
#   --check         (default) compare current L0 dump against golden
#   --regen-golden  write current L0 dump to the golden file.
#                   This is INTENTIONALLY manual: a human must
#                   review the diff before regenerating.
#   --self-check    validate the golden file format; safe to run
#                   on any host (does not require bhyve)
#   --help          this message
#
# Exit codes:
#   0  dump matches golden (or self-check passed)
#   1  self-check failed (malformed golden)
#   2  snapshot diff non-empty (loud failure)
#   3  bhyve/vmm not available (--check only)
#   4  --regen-golden refused (no human reviewer acknowledged)
#
# The golden file is checked into the test directory; the test
# is "test-first" in the sense that the first commit is the
# golden + script.  Until T18, T19, T25, T28 land, the L0 will
# not produce the full snapshot and --check will fail (RED).
# Once those commits land and the L0 produces the expected
# snapshot, --check passes (GREEN).  Any future change that
# breaks the ABI will fail --check (LOUD FAILURE).
#
# Reference: KVM tools/testing/selftests/kvm/x86_64/vmx_fix.c
# is a DESIGN REFERENCE for the snapshot-test pattern (GPL);
# this script is original BSD code.

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
GOLDEN="${SCRIPT_DIR}/golden_abisnap.txt"
SNAPSHOT="${SNAPSHOT_FILE:-/tmp/abisnap.actual.$$}"
DUMP_BIN="${DUMP_BIN:-/usr/tests/sys/vmm/nested/abisnap/abisnap_dump}"
KEEP_SNAPSHOT=0

MODE="check"
VERBOSE=0
REVIEWER=""

usage()
{
	cat <<EOF
Usage: $(basename "$0") [--check|--regen-golden|--self-check|--help]
                        [--reviewer NAME] [-v]

Modes:
  --check            compare current L0 dump against the golden file
                     (default; requires FreeBSD with vmm(4) loaded)
  --regen-golden     write the current L0 dump to the golden file.
                     A human reviewer MUST be named with --reviewer.
                     The diff is printed before the write so the
                     reviewer can sanity-check the change.
  --self-check       validate the golden file format only
                     (does not require vmm/bhyve; safe on any host)
  --reviewer NAME    required for --regen-golden; recorded in the
                     new golden file header as the human approver
  -v                 verbose output
  -h, --help         this help

Environment:
  DUMP_BIN           path to the L0 dump helper
                     (default: /usr/tests/sys/vmm/nested/abisnap/abisnap_dump)
  SNAPSHOT_FILE      path to the temporary snapshot file
                     (default: /tmp/abisnap.actual.PID)
  KEEP_SNAPSHOT=1    keep the snapshot file after the test (debug)
EOF
}

parse_args()
{
	while [ $# -gt 0 ]; do
		case "$1" in
		--check)
			MODE="check"
			shift
			;;
		--regen-golden)
			MODE="regen"
			shift
			;;
		--self-check)
			MODE="self-check"
			shift
			;;
		--reviewer)
			[ $# -ge 2 ] || { echo "--reviewer requires a name" >&2; exit 1; }
			REVIEWER="$2"
			shift 2
			;;
		-v)
			VERBOSE=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 1
			;;
		esac
	done
}

log_v()
{
	if [ "${VERBOSE}" = "1" ]; then
		echo "[INFO] $1"
	fi
}

err()
{
	echo "[ERROR] $1" >&2
}

# Detect environment
detect_host()
{
	if [ "$(uname -s 2>/dev/null)" = "FreeBSD" ] && \
	    [ -e /dev/vmm ] 2>/dev/null; then
		echo "freebsd-vmm"
	elif [ "$(uname -s 2>/dev/null)" = "FreeBSD" ]; then
		echo "freebsd-no-vmm"
	else
		echo "non-freebsd"
	fi
}

# Run the L0 dump.  On a FreeBSD system with vmm(4) and the
# abisnap_dump helper installed, this writes the snapshot to
# $SNAPSHOT.  In --self-check mode (or on non-FreeBSD), the
# function returns 0 without writing anything; the test then
# falls back to verifying the golden file format.
run_dump()
{
	_host=$(detect_host)
	case "${_host}" in
	freebsd-vmm)
		if [ ! -x "${DUMP_BIN}" ]; then
			err "dump helper not found or not executable: ${DUMP_BIN}"
			return 3
		fi
		log_v "running L0 dump: ${DUMP_BIN} > ${SNAPSHOT}"
		"${DUMP_BIN}" > "${SNAPSHOT}" 2>&1
		return $?
		;;
	freebsd-no-vmm)
		err "FreeBSD host without /dev/vmm; load vmm(4) and ensure nested-virt is enabled"
		return 3
		;;
	non-freebsd)
		err "non-FreeBSD host; --self-check is the only valid mode"
		return 3
		;;
	esac
}

# Validate the golden file format.  Returns 0 on success.
self_check()
{
	log_v "mode: self-check"
	_rc=0

	if [ ! -f "${GOLDEN}" ]; then
		err "golden file not found: ${GOLDEN}"
		return 1
	fi

	# Required section headers
	for _section in "VMCS12" "VMCB12" "Hyper-V MSR"; do
		if ! grep -q "^# ${_section}" "${GOLDEN}"; then
			err "golden file missing section: ${_section}"
			_rc=1
		fi
	done

	# Required header (revision, generated-by)
	for _hdr in "ABI-SNAPSHOT" "revision" "generated-by"; do
		if ! grep -q "${_hdr}" "${GOLDEN}"; then
			err "golden file missing header field: ${_hdr}"
			_rc=1
		fi
	done

	# Count entries; record in summary
	_vmcs=$(grep -cE "^[A-Z0-9_]+\s+0x[0-9a-fA-F]+\s+[0-9]+" "${GOLDEN}" | head -1)
	_vmcs_count=$(awk '/^# VMCS12/{f=1; next} /^# VMCB12/{f=0} f && /^[A-Z0-9_]+/ {c++} END{print c+0}' "${GOLDEN}")
	_vmcb_count=$(awk '/^# VMCB12/{f=1; next} /^# Hyper-V/{f=0} f && /^[A-Z0-9_]+/ {c++} END{print c+0}' "${GOLDEN}")
	_msr_count=$(awk '/^# Hyper-V/{f=1; next} f && /^[A-Z0-9_]+/ {c++} END{print c+0}' "${GOLDEN}")

	log_v "VMCS12 entries: ${_vmcs_count}"
	log_v "VMCB12 entries: ${_vmcb_count}"
	log_v "Hyper-V MSR entries: ${_msr_count}"

	if [ "${_vmcs_count}" -lt 10 ]; then
		err "VMCS12 section has too few entries (${_vmcs_count}); expected >= 10"
		_rc=1
	fi
	if [ "${_vmcb_count}" -lt 10 ]; then
		err "VMCB12 section has too few entries (${_vmcb_count}); expected >= 10"
		_rc=1
	fi
	if [ "${_msr_count}" -lt 5 ]; then
		err "Hyper-V MSR section has too few entries (${_msr_count}); expected >= 5"
		_rc=1
	fi

	if [ ${_rc} -eq 0 ]; then
		echo "self-check: PASS"
		echo "  golden file format is valid"
		echo "  all three sections present (VMCS12, VMCB12, Hyper-V MSR)"
		echo "  VMCS12 entries: ${_vmcs_count}"
		echo "  VMCB12 entries: ${_vmcb_count}"
		echo "  Hyper-V MSR entries: ${_msr_count}"
	else
		echo "self-check: FAIL"
	fi
	return ${_rc}
}

# Compare current dump against golden.
check_mode()
{
	log_v "mode: check"
	if [ ! -f "${GOLDEN}" ]; then
		err "golden file not found: ${GOLDEN}"
		return 1
	fi

	if ! run_dump; then
		return 3
	fi

	log_v "diffing ${SNAPSHOT} against ${GOLDEN}"
	if diff -u "${GOLDEN}" "${SNAPSHOT}"; then
		echo "snapshot: PASS (no diff)"
		[ "${KEEP_SNAPSHOT}" = "1" ] || rm -f "${SNAPSHOT}"
		return 0
	else
		echo "snapshot: FAIL (diff non-empty)"
		[ "${KEEP_SNAPSHOT}" = "1" ] || rm -f "${SNAPSHOT}"
		return 2
	fi
}

# Regenerate the golden file.  Requires --reviewer.
regen_mode()
{
	log_v "mode: regen-golden"
	if [ -z "${REVIEWER}" ]; then
		err "--regen-golden requires --reviewer NAME"
		err "A human reviewer must be named so the change is auditable."
		return 4
	fi
	if [ ! -f "${GOLDEN}" ]; then
		err "golden file not found: ${GOLDEN} (cannot regen without existing golden)"
		return 1
	fi

	if ! run_dump; then
		return 3
	fi

	# Print the diff so the human reviewer can see what is changing
	echo "=== diff of new snapshot against existing golden ==="
	diff -u "${GOLDEN}" "${SNAPSHOT}" || true
	echo "=== end of diff ==="

	echo ""
	echo "Reviewer: ${REVIEWER}"
	echo "Snapshot file: ${SNAPSHOT}"
	echo ""
	echo "If the diff above is acceptable, manually copy:"
	echo "    cp ${SNAPSHOT} ${GOLDEN}"
	echo "and commit the change with a message that explains the ABI change."
	echo ""
	echo "The script will NOT do this automatically; per the plan,"
	echo "every ABI change requires human review."
	rm -f "${SNAPSHOT}"
	return 4
}

main()
{
	parse_args "$@"

	if [ "${KEEP_SNAPSHOT:-0}" = "1" ]; then
		KEEP_SNAPSHOT=1
	fi

	case "${MODE}" in
	check)
		check_mode
		;;
	regen)
		regen_mode
		;;
	self-check)
		self_check
		;;
	*)
		err "unknown mode: ${MODE}"
		return 1
		;;
	esac
}

main "$@"
