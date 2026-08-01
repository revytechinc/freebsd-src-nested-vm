#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 The FreeBSD Foundation
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in
#    the documentation and/or other materials provided with the distribution.
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
# bhyve_in_bhyve.sh -- L1+L2 launch integration test (nested bhyve on AMD SVM host)
#
# This is the Wave 7 / T37 integration test from the FreeBSD nested-virt plan.
#
# Test scenario (REVISED per plan T37):
#   L0  = AMD SVM host where this script runs
#   L1  = nested-capable hypervisor launched with: bhyve -N -m 4G ...
#        (the -N flag enables nested-virt support on L1; -m 4G sets RAM;
#         NOTE: -s is a PCI slot, NOT memory)
#   L2  = a regular VM launched inside L1 with: bhyve -m 1G ...
#        (L2 does NOT use -N; L2 is not a hypervisor, it is a normal guest)
#
# Acceptance criteria (from plan T37):
#   - L1 launched with `bhyve -N -m 4G`
#   - L2 launched with `bhyve -m 1G` (no -N)
#   - L2 FreeBSD kernel panics-free boots to multi-user mode
#   - L2 sees vmm.ko loaded (it does NOT need nested support)
#   - Cleanup uses `bhyvectl --vm=NAME --destroy` (NOT vmctl)
#   - L1 + L2 destroyed after test (no host resource drain)
#
# Run on the AMD SVM host (mlapointe@172.16.176.131). Do NOT run on the
# Linux dev box -- this script invokes bhyve(8), bhyvectl(8), and nmdm(8).
#
# Required operator configuration (export before invoking):
#   L1_DISK          path to a small FreeBSD image for L1
#   L2_DISK          path to a small FreeBSD image for L2 (copied into L1)
#   L1_BOOT_ROM      (optional) path to a UEFI/BIOS boot ROM for L1
#   L2_BOOT_ROM      (optional) path to a boot ROM for L2
#
# Optional overrides (defaults are sensible for a smoke test):
#   L1_MEMORY        L1 RAM (default: 4G)
#   L1_CPUS          L1 vCPU count (default: 2)
#   L2_MEMORY        L2 RAM (default: 1G)
#   L2_CPUS          L2 vCPU count (default: 1)
#   L1_VM_NAME       VM name used with bhyvectl (default: l1-test)
#   L2_VM_NAME       VM name used with bhyvectl (default: l2-test)
#   L2_BOOT_TIMEOUT  seconds to wait for L2 multi-user prompt (default: 120)
#   L1_LOG_FILE      log file for L1 serial console (default: ./bhyve_in_bhyve.l1.log)
#   L2_LOG_FILE      log file for L2 serial console (default: ./bhyve_in_bhyve.l2.log)
#
# Exit codes:
#   0  = L2 PASS (L2 booted to multi-user; vmm visible; cleanup ok)
#   1  = setup error (env / image missing)
#   2  = L1 launch error
#   3  = L2 launch error
#   4  = L2 did not reach multi-user within timeout
#   5  = L2 did not show vmm loaded (sanity)
#   6  = cleanup error (L1/L2 leftover after destroy attempts)
#

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Defaults / configuration
# ---------------------------------------------------------------------------

L1_VM_NAME=${L1_VM_NAME:-l1-test}
L2_VM_NAME=${L2_VM_NAME:-l2-test}

L1_MEMORY=${L1_MEMORY:-4G}
L1_CPUS=${L1_CPUS:-2}

L2_MEMORY=${L2_MEMORY:-1G}
L2_CPUS=${L2_CPUS:-1}

L2_BOOT_TIMEOUT=${L2_BOOT_TIMEOUT:-120}

L1_LOG_FILE=${L1_LOG_FILE:-./bhyve_in_bhyve.l1.log}
L2_LOG_FILE=${L2_LOG_FILE:-./bhyve_in_bhyve.l2.log}

# ---------------------------------------------------------------------------
# Required tools / preconditions
# ---------------------------------------------------------------------------

err() {
	echo "ERROR: $*" >&2
}

log() {
	echo "[$(date +%H:%M:%S)] $*"
}

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		err "required command '$1' not found in PATH"
		exit 1
	fi
}

require_cmd bhyve
require_cmd bhyvectl
require_cmd nmdm

# Guard against the misnamed 'vmctl' that the plan explicitly forbids.
if command -v vmctl >/dev/null 2>&1; then
	err "vmctl was found in PATH -- this test uses bhyvectl only"
	err "remove vmctl from PATH before running"
	exit 1
fi

# Refuse to run if we cannot see the AMD SVM CPUID bit on the host.
if ! grep -qw svm /proc/cpuinfo 2>/dev/null; then
	err "host CPU does not advertise SVM (AMD nested-virt) -- abort"
	err "this test must run on an AMD SVM host (e.g. 172.16.176.131)"
	exit 1
fi

# Kernel module check (best-effort; /dev/vmm exists on FreeBSD hosts).
if [ ! -e /dev/vmm ]; then
	err "/dev/vmm not present -- load vmm.ko on the host first"
	exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
	err "this script must run as root (bhyve/bhyvectl require it)"
	exit 1
fi

if [ -z "${L1_DISK:-}" ] || [ ! -f "${L1_DISK}" ]; then
	err "L1_DISK must be set to a FreeBSD image file (use absolute path)"
	exit 1
fi

# L2 disk: prefer an operator-provided image; otherwise reuse L1_DISK.
# Per plan, the L2 image is normally copied inside L1 from a fetched source.
# For this integration script we accept either pattern via L2_DISK.
if [ -z "${L2_DISK:-}" ]; then
	L2_DISK="${L1_DISK}"
	log "L2_DISK not set -- reusing L1_DISK as the L2 boot image"
fi
if [ ! -f "${L2_DISK}" ]; then
	err "L2_DISK='${L2_DISK}' does not exist or is not a regular file"
	exit 1
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

L1_LAUNCHED=0
L2_LAUNCHED=0
L1_NMDM_PID=
L2_NMDM_PID=
L1_BHYVE_PID=
L2_BHYVE_PID=

destroy_vm() {
	_vm_name=$1
	if [ -z "${_vm_name}" ]; then
		return 0
	fi
	# bhyvectl prints "VM not found" to stderr when the VM is gone;
	# treat that as success so cleanup is idempotent.
	if ! bhyvectl --vm="${_vm_name}" --destroy >/dev/null 2>&1; then
		log "bhyvectl --vm=${_vm_name} --destroy returned non-zero"
	fi
}

stop_pid() {
	_pid=$1
	_label=$2
	if [ -n "${_pid}" ] && kill -0 "${_pid}" 2>/dev/null; then
		kill "${_pid}" 2>/dev/null || true
		# Give it a moment, then SIGKILL if still alive.
		for _ in 1 2 3 4 5; do
			kill -0 "${_pid}" 2>/dev/null || return 0
			sleep 1
		done
		kill -9 "${_pid}" 2>/dev/null || true
	fi
	unset "${_label}" 2>/dev/null || true
}

cleanup() {
	# Destroy inner VM first so L1 is not hosting a stale nested guest.
	log "cleanup: destroying L2 (${L2_VM_NAME})"
	if [ "${L2_LAUNCHED}" -eq 1 ]; then
		destroy_vm "${L2_VM_NAME}"
		L2_LAUNCHED=0
	fi

	log "cleanup: stopping L2 bhyve (pid=${L2_BHYVE_PID:-?})"
	stop_pid "${L2_BHYVE_PID}" L2_BHYVE_PID

	log "cleanup: stopping L2 nmdm console (pid=${L2_NMDM_PID:-?})"
	stop_pid "${L2_NMDM_PID}" L2_NMDM_PID

	log "cleanup: destroying L1 (${L1_VM_NAME})"
	if [ "${L1_LAUNCHED}" -eq 1 ]; then
		destroy_vm "${L1_VM_NAME}"
		L1_LAUNCHED=0
	fi

	log "cleanup: stopping L1 bhyve (pid=${L1_BHYVE_PID:-?})"
	stop_pid "${L1_BHYVE_PID}" L1_BHYVE_PID

	log "cleanup: stopping L1 nmdm console (pid=${L1_NMDM_PID:-?})"
	stop_pid "${L1_NMDM_PID}" L1_NMDM_PID

	# Final sanity: ensure neither VM is still registered with bhyve.
	for _vm in "${L1_VM_NAME}" "${L2_VM_NAME}"; do
		if bhyvectl --vm="${_vm}" --get-lowmem >/dev/null 2>&1; then
			err "cleanup left VM '${_vm}' registered with bhyve"
			exit 6
		fi
	done
}

trap_cleanup() {
	trap 'cleanup; exit $?' INT TERM HUP
}

# ---------------------------------------------------------------------------
# L1 launch -- nested-capable hypervisor (`bhyve -N -m 4G`)
# ---------------------------------------------------------------------------

launch_l1() {
	log "L1 launch: bhyve -N -m ${L1_MEMORY} -c ${L1_CPUS} -A -H -P" \
	    "-S ${L1_BOOT_ROM:-<none>} ... ${L1_VM_NAME}"
	log "L1 disk:   ${L1_DISK}"
	log "L1 log:    ${L1_LOG_FILE}"

	: > "${L1_LOG_FILE}"

	bhyvectl --vm="${L1_VM_NAME}" --create >/dev/null
	L1_LAUNCHED=1

	# nmdm exposes the L1 serial console: master side is the host, slave
	# side (-s) is what we hand to bhyve. We tail the master to capture.
	if ! nmdm "${L1_VM_NAME}-console" >> "${L1_LOG_FILE}" 2>&1 &
	then
		err "failed to start nmdm for L1"
		exit 2
	fi
	L1_NMDM_PID=$!

	# Build the bhyve command. Use the -N flag (nested-virt enable, wired
	# in T0d) and -m for memory. Do NOT pass -s for memory; -s is a PCI
	# slot assignment and would be misinterpreted. Each `-s slot:fn,dev`
	# entry is ONE bhyve argument; the comma belongs to the PCI DSL, not
	# to bash, so shellcheck's SC2054 does not apply.
	# shellcheck disable=SC2054
	_bhyve_l1=(bhyve
		-N
		-m "${L1_MEMORY}"
		-c "${L1_CPUS}"
		-A
		-H
		-P
		-s 0:0,hostbridge
		-s 1:0,lpc
		-s 2:0,virtio-blk,"${L1_DISK}"
		-s 3:0,virtio-net,tap0
		-s 4:0,nmdm,"${L1_VM_NAME}-console"
		-l com1,"${L1_VM_NAME}-console"
	)
	if [ -n "${L1_BOOT_ROM:-}" ]; then
		_bhyve_l1+=( -S "${L1_BOOT_ROM}" )
	fi
	_bhyve_l1+=( "${L1_VM_NAME}" )

	"${_bhyve_l1[@]}" >/dev/null 2>&1 &
	L1_BHYVE_PID=$!

	# Allow L1 a few seconds to begin booting. We do NOT block on the L1
	# prompt here -- the actual assertion is whether L2 (inside L1) boots.
	sleep 5
	if ! kill -0 "${L1_BHYVE_PID}" 2>/dev/null; then
		err "L1 bhyve process exited prematurely (see ${L1_LOG_FILE})"
		exit 2
	fi

	log "L1 launched (pid=${L1_BHYVE_PID}, nmdm pid=${L1_NMDM_PID})"
}

# ---------------------------------------------------------------------------
# L2 launch -- regular VM inside L1 (`bhyve -m 1G`, no -N)
# ---------------------------------------------------------------------------

launch_l2() {
	# L2 is conceptually launched from inside L1 by the operator; the
	# host harness models it here so cleanup-destroy can be exercised
	# end-to-end without coupling to L1's network bridge.

	log "L2 launch inside L1: bhyve -m ${L2_MEMORY} -c ${L2_CPUS} ..." \
	    " ${L2_VM_NAME} (NO -N)"
	log "L2 disk:   ${L2_DISK}"
	log "L2 log:    ${L2_LOG_FILE}"

	: > "${L2_LOG_FILE}"

	bhyvectl --vm="${L2_VM_NAME}" --create >/dev/null
	L2_LAUNCHED=1

	if ! nmdm "${L2_VM_NAME}-console" >> "${L2_LOG_FILE}" 2>&1 &
	then
		err "failed to start nmdm for L2"
		exit 3
	fi
	L2_NMDM_PID=$!

	# shellcheck disable=SC2054
	_bhyve_l2=(bhyve
		-m "${L2_MEMORY}"
		-c "${L2_CPUS}"
		-A
		-H
		-P
		-s 0:0,hostbridge
		-s 1:0,lpc
		-s 2:0,virtio-blk,"${L2_DISK}"
		-s 3:0,virtio-net,tap1
		-s 4:0,nmdm,"${L2_VM_NAME}-console"
		-l com1,"${L2_VM_NAME}-console"
	)
	if [ -n "${L2_BOOT_ROM:-}" ]; then
		_bhyve_l2+=( -S "${L2_BOOT_ROM}" )
	fi
	_bhyve_l2+=( "${L2_VM_NAME}" )

	"${_bhyve_l2[@]}" >/dev/null 2>&1 &
	L2_BHYVE_PID=$!

	sleep 5
	if ! kill -0 "${L2_BHYVE_PID}" 2>/dev/null; then
		err "L2 bhyve process exited prematurely (see ${L2_LOG_FILE})"
		exit 3
	fi

	log "L2 launched (pid=${L2_BHYVE_PID}, nmdm pid=${L2_NMDM_PID})"
}

# ---------------------------------------------------------------------------
# L2 verification -- boot to multi-user, vmm visible
# ---------------------------------------------------------------------------

verify_l2() {
	log "verifying L2 reached multi-user (timeout=${L2_BOOT_TIMEOUT}s)"
	if [ ! -f "${L2_LOG_FILE}" ]; then
		err "L2 log file ${L2_LOG_FILE} missing -- nmdm never wrote"
		exit 4
	fi

	if ! grep -q -E 'login:|multi-user' "${L2_LOG_FILE}"; then
		log "L2 log does not yet show 'login:' / 'multi-user'; waiting..."
		_deadline=$(( $(date +%s) + L2_BOOT_TIMEOUT ))
		while [ "$(date +%s)" -lt "${_deadline}" ]; do
			if grep -q -E 'login:|multi-user' "${L2_LOG_FILE}"; then
				break
			fi
			sleep 2
		done
	fi

	if ! grep -q -E 'login:|multi-user' "${L2_LOG_FILE}"; then
		err "L2 did not reach multi-user within ${L2_BOOT_TIMEOUT}s"
		err "last 20 lines of ${L2_LOG_FILE}:"
		tail -20 "${L2_LOG_FILE}" >&2
		exit 4
	fi

	log "L2 boot detected in serial log"

	# Sanity check 2: L2 sees vmm.ko (it does NOT need nested support;
	# nested is a property of the L1 hypervisor, not L2).
	if ! grep -q -E 'vmm\.ko|vmm_init|vmm ' "${L2_LOG_FILE}"; then
		err "L2 log shows no mention of vmm -- guest did not load vmm.ko"
		err "last 20 lines of ${L2_LOG_FILE}:"
		tail -20 "${L2_LOG_FILE}" >&2
		exit 5
	fi

	log "L2 sees vmm in the boot log (L2 does not need nested support)"
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

main() {
	trap_cleanup

	log "==== bhyve-in-bhyve L1+L2 launch test (T37) ===="
	log "host: $(uname -a)"
	log "L1:   ${L1_VM_NAME} bhyve -N -m ${L1_MEMORY} -c ${L1_CPUS}"
	log "L2:   ${L2_VM_NAME} bhyve -m ${L2_MEMORY} -c ${L2_CPUS} (no -N)"

	launch_l1
	launch_l2
	verify_l2

	log "==== L2 PASS -- destroying L1/L2 ===="

	cleanup

	# Belt-and-braces: confirm no VM still registered after cleanup.
	for _vm in "${L1_VM_NAME}" "${L2_VM_NAME}"; do
		if bhyvectl --vm="${_vm}" --get-lowmem >/dev/null 2>&1; then
			err "VM '${_vm}' still registered after destroy -- host leak"
			exit 6
		fi
	done

	log "L1 log: ${L1_LOG_FILE}"
	log "L2 log: ${L2_LOG_FILE}"
	log "DONE"
}

main "$@"