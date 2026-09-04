#!/bin/sh
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
# bhyve_in_bhyve.sh -- boot a real L2 bhyve guest inside an L1 bhyve guest.
#
# Topology and control path:
#
#   L0 (this script, AMD SVM host)
#     `-- bhyve -N -m 4G ... l1-test
#          `-- L1 FreeBSD, reached over SSH
#                `-- bhyve -m 1G ... l2-test
#
# There is deliberately no `bhyvectl --create` before either bhyve command.
# The L1 `-N` option is a VMMCTL_VM_CREATE flag, not a reconfiguration knob:
# bhyve must perform the first CREATE of l1-test so vm->nested_enabled is set.
# L2 is created by the bhyve binary running in L1 and never by a process on L0.
#
# Serial consoles use nmdm pairs in the kernel, not a userspace "nmdm"
# command.  On L0, bhyve attaches L1's UART to /dev/nmdm0A while this harness
# reads /dev/nmdm0B.  Inside L1, a tmux console session reads /dev/nmdm1B
# while the nested bhyve attaches L2's UART to /dev/nmdm1A.  The L2 console is
# written inside L1 to /tmp/l2-serial.log and copied to the same path on L0.
#
# Full test prerequisites:
#   L1_DISK          bootable FreeBSD disk image for L1
#   L2_DISK          bootable FreeBSD disk image copied into L1
#   L1_BOOT_ROM      bhyve UEFI ROM on L0; required so bhyve creates L1
#   L2_BOOT_ROM      bhyve UEFI ROM copied into L1 for L2
#   L1_SSH_HOST      address of L1 on the preconfigured L1_TAP network
#
# The L1 image must enable root public-key SSH and contain bhyve, bhyvectl,
# tmux, vmm.ko, and nmdm.ko.  L1_TAP and L2_TAP must already be connected to
# suitable bridges; this test does not alter host networking.
#
# Tiny create-only subset (no disk image required):
#
#   L1_BOOT_ROM=/path/to/BHYVE_UEFI.fd ./bhyve_in_bhyve.sh --create-smoke
#
# It starts a firmware-only L1 with `bhyve -N`, verifies that a new VM device
# exists, and records "VMMCTL_VM_CREATE success" in /tmp/l1-create.log.  Since
# any stale l1-test is destroyed and verified absent first, this proves that
# the -N launch reached and succeeded at the CREATE ioctl without relying on
# an already-created legacy VM.

set -eu

MODE=full
case "${1:-}" in
"")
	;;
--create-smoke)
	MODE=create-smoke
	;;
*)
	printf 'usage: %s [--create-smoke]\n' "$0" >&2
	exit 64
	;;
esac

L1_VM_NAME=${L1_VM_NAME:-l1-test}
L2_VM_NAME=${L2_VM_NAME:-l2-test}
L1_MEMORY=${L1_MEMORY:-4G}
L1_CPUS=${L1_CPUS:-2}
L2_CPUS=${L2_CPUS:-1}
L1_TAP=${L1_TAP:-tap0}
L2_TAP=${L2_TAP:-tap0}
L1_NMDM_UNIT=${L1_NMDM_UNIT:-0}
L2_NMDM_UNIT=${L2_NMDM_UNIT:-1}
L1_NMDM_A=/dev/nmdm${L1_NMDM_UNIT}A
L1_NMDM_B=/dev/nmdm${L1_NMDM_UNIT}B
L2_NMDM_A=/dev/nmdm${L2_NMDM_UNIT}A
L2_NMDM_B=/dev/nmdm${L2_NMDM_UNIT}B

L1_SERIAL_LOG=${L1_SERIAL_LOG:-/tmp/l1-serial.log}
L1_BHYVE_LOG=${L1_BHYVE_LOG:-/tmp/l1-bhyve.log}
L1_CREATE_LOG=${L1_CREATE_LOG:-/tmp/l1-create.log}
L2_LOG_FILE=${L2_LOG_FILE:-/tmp/l2-serial.log}
L2_BOOT_TIMEOUT=${L2_BOOT_TIMEOUT:-180}
L1_SSH_TIMEOUT=${L1_SSH_TIMEOUT:-180}
L1_SSH_USER=${L1_SSH_USER:-root}
L1_SSH_PORT=${L1_SSH_PORT:-22}
L1_SSH_IDENTITY=${L1_SSH_IDENTITY:-}
L1_SSH_KNOWN_HOSTS=${L1_SSH_KNOWN_HOSTS:-${LOCAL_TMPDIR:-/tmp}/t37-known-hosts}

L2_REMOTE_IMAGE=/tmp/t37-l2.img
L2_REMOTE_BOOT_ROM=/tmp/t37-l2-bootrom.fd
L2_REMOTE_CONFIG=/tmp/t37-l2.conf
L2_REMOTE_CONTROL=/tmp/t37-l2-control.sh
L2_REMOTE_SERIAL=/tmp/l2-serial.log
L2_REMOTE_BHYVE_LOG=/tmp/l2-bhyve.log

L1_BHYVE_PID=
L1_CONSOLE_PID=
L1_SSH_READY=0
L2_CONTROL_INSTALLED=0
CLEANUP_DONE=0
LOCAL_TMPDIR=

log()
{
	printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail()
{
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

require_cmd()
{
	command -v "$1" >/dev/null 2>&1 || fail "required command '$1' not found"
}

require_file()
{
	[ -f "$1" ] || fail "$2 ('$1') is not a regular file"
}

require_positive_integer()
{
	case "$2" in
	""|*[!0-9]*)
		fail "$1 must be a positive integer (got '$2')"
		;;
	esac
	[ "$2" -gt 0 ] || fail "$1 must be greater than zero"
}

require_safe_token()
{
	case "$2" in
	""|*[!A-Za-z0-9_.-]*)
		fail "$1 contains unsupported characters: '$2'"
		;;
	esac
}

local_vm_exists()
{
	# --get-stats opens the vmctx + vcpu and therefore fails unless the VM
	# is registered with vmm(4).  Any other bhyvectl get-* option that
	# triggers vm_openf would work; we pick --get-stats because it is the
	# cheapest stable probe.
	bhyvectl --vm="$L1_VM_NAME" --get-stats >/dev/null 2>&1
}

wait_for_local_vm()
{
	wait_count=0
	while [ "$wait_count" -lt 50 ]; do
		if local_vm_exists; then
			return 0
		fi
		if [ -n "$L1_BHYVE_PID" ] && ! kill -0 "$L1_BHYVE_PID" 2>/dev/null; then
			return 1
		fi
		wait_count=$((wait_count + 1))
		sleep 0.1
	done
	return 1
}

stop_pid()
{
	pid=$1
	[ -n "$pid" ] || return 0
	if kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null || true
		stop_count=0
		while kill -0 "$pid" 2>/dev/null && [ "$stop_count" -lt 5 ]; do
			stop_count=$((stop_count + 1))
			sleep 1
		done
		kill -9 "$pid" 2>/dev/null || true
	fi
}

ssh_l1()
{
	if [ -n "$L1_SSH_IDENTITY" ]; then
		ssh -i "$L1_SSH_IDENTITY" -p "$L1_SSH_PORT" \
		    -o BatchMode=yes -o ConnectTimeout=5 \
		    -o StrictHostKeyChecking=accept-new \
		    -o UserKnownHostsFile="$L1_SSH_KNOWN_HOSTS" \
		    "$L1_SSH_USER@$L1_SSH_HOST" "$@"
	else
		ssh -p "$L1_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 \
		    -o StrictHostKeyChecking=accept-new \
		    -o UserKnownHostsFile="$L1_SSH_KNOWN_HOSTS" \
		    "$L1_SSH_USER@$L1_SSH_HOST" "$@"
	fi
}

scp_to_l1()
{
	source_path=$1
	destination_path=$2
	if [ -n "$L1_SSH_IDENTITY" ]; then
		scp -i "$L1_SSH_IDENTITY" -P "$L1_SSH_PORT" \
		    -o BatchMode=yes -o ConnectTimeout=5 \
		    -o StrictHostKeyChecking=accept-new \
		    -o UserKnownHostsFile="$L1_SSH_KNOWN_HOSTS" \
		    "$source_path" \
		    "$L1_SSH_USER@$L1_SSH_HOST:$destination_path"
	else
		scp -P "$L1_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 \
		    -o StrictHostKeyChecking=accept-new \
		    -o UserKnownHostsFile="$L1_SSH_KNOWN_HOSTS" \
		    "$source_path" \
		    "$L1_SSH_USER@$L1_SSH_HOST:$destination_path"
	fi
}

cleanup_remote_l2()
{
	[ "$L1_SSH_READY" -eq 1 ] || return 0

	if [ "$L2_CONTROL_INSTALLED" -eq 1 ]; then
		# With the defaults this executes, inside L1:
		#     bhyvectl --vm=l2-test --destroy
		if ! ssh_l1 "$L2_REMOTE_CONTROL cleanup" >/dev/null 2>&1; then
			log "cleanup: L1 helper could not destroy $L2_VM_NAME"
			return 1
		fi
		L2_CONTROL_INSTALLED=0
		return 0
	fi

	return 0
}

cleanup_local_l1()
{
	cleanup_status=0
	if local_vm_exists; then
		bhyvectl --vm="$L1_VM_NAME" --force-poweroff >/dev/null 2>&1 || true
	fi
	stop_pid "$L1_BHYVE_PID"
	L1_BHYVE_PID=
	if local_vm_exists; then
		# With the default this is bhyvectl --vm=l1-test --destroy on L0.
		if ! bhyvectl --vm="$L1_VM_NAME" --destroy >/dev/null 2>&1; then
			log "cleanup: failed to destroy L1 $L1_VM_NAME"
			cleanup_status=1
		fi
	fi
	stop_pid "$L1_CONSOLE_PID"
	L1_CONSOLE_PID=
	if local_vm_exists; then
		log "cleanup: L1 $L1_VM_NAME remains registered"
		cleanup_status=1
	fi
	return "$cleanup_status"
}

cleanup()
{
	[ "$CLEANUP_DONE" -eq 0 ] || return 0
	CLEANUP_DONE=1
	cleanup_status=0

	# L2 belongs to L1's /dev/vmm and must be destroyed over SSH before L1.
	cleanup_remote_l2 || cleanup_status=1
	cleanup_local_l1 || cleanup_status=1

	if [ -n "$LOCAL_TMPDIR" ] && [ -d "$LOCAL_TMPDIR" ]; then
		rm -rf "$LOCAL_TMPDIR"
	fi
	return "$cleanup_status"
}

on_exit()
{
	exit_status=$1
	trap - 0 1 2 15
	cleanup_status=0
	cleanup || cleanup_status=$?
	if [ "$exit_status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then
		exit_status=6
	fi
	exit "$exit_status"
}

trap 'on_exit $?' 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

preflight_common()
{
	require_cmd bhyve
	require_cmd bhyvectl
	require_cmd kldload
	require_cmd sysctl

	[ "$(uname -s)" = FreeBSD ] || fail "run this test on the FreeBSD L0 host"
	[ "$(id -u)" -eq 0 ] || fail "run this test as root"

	case "$(uname -m)" in
	amd64)
		;;
	*)
		fail "L0 must be amd64"
		;;
	esac
	if ! sysctl -n hw.model 2>/dev/null | grep -qi AMD; then
		fail "L0 CPU is not identified as AMD"
	fi

	kldload vmm >/dev/null 2>&1 || true
	kldload nmdm >/dev/null 2>&1 || true
	[ -c /dev/vmmctl ] || fail "/dev/vmmctl is unavailable after loading vmm.ko"
	[ -c "$L1_NMDM_A" ] || fail "$L1_NMDM_A is unavailable after loading nmdm.ko"
	[ -c "$L1_NMDM_B" ] || fail "$L1_NMDM_B is unavailable after loading nmdm.ko"

	nested_enable=$(sysctl -n hw.vmm.nested.enable 2>/dev/null || true)
	[ "$nested_enable" = 1 ] || \
	    fail "set hw.vmm.nested.enable=1 before running this test"

	require_safe_token L1_VM_NAME "$L1_VM_NAME"
	require_safe_token L2_VM_NAME "$L2_VM_NAME"
	require_safe_token L1_TAP "$L1_TAP"
	require_safe_token L2_TAP "$L2_TAP"
	require_safe_token L1_SSH_USER "$L1_SSH_USER"
	case "$L1_SSH_USER" in
	-*)
		fail "L1_SSH_USER must not start with '-'"
		;;
	esac
	require_safe_token L1_SSH_HOST "$L1_SSH_HOST"
	case "$L1_SSH_HOST" in
	-*)
		fail "L1_SSH_HOST must not start with '-'"
		;;
	esac
	require_positive_integer L1_CPUS "$L1_CPUS"
	require_positive_integer L2_CPUS "$L2_CPUS"
	require_positive_integer L1_NMDM_UNIT "$L1_NMDM_UNIT"
	require_positive_integer L2_NMDM_UNIT "$L2_NMDM_UNIT"
	require_positive_integer L1_SSH_PORT "$L1_SSH_PORT"
	require_positive_integer L1_SSH_TIMEOUT "$L1_SSH_TIMEOUT"
	require_positive_integer L2_BOOT_TIMEOUT "$L2_BOOT_TIMEOUT"

	case "$L1_MEMORY" in
	[1-9][0-9]*[KMGTP])
		;;
	*)
		fail "L1_MEMORY must be a bhyve size such as 4G"
		;;
	esac

	[ -n "${L1_BOOT_ROM:-}" ] || fail "L1_BOOT_ROM is required"
	require_file "$L1_BOOT_ROM" L1_BOOT_ROM
}

preflight_full()
{
	require_cmd ssh
	require_cmd scp
	require_cmd ifconfig

	[ -n "${L1_DISK:-}" ] || fail "L1_DISK is required for the full test"
	[ -n "${L2_DISK:-}" ] || fail "L2_DISK is required for the full test"
	[ -n "${L2_BOOT_ROM:-}" ] || fail "L2_BOOT_ROM is required for the full test"
	[ -n "${L1_SSH_HOST:-}" ] || fail "L1_SSH_HOST is required for the full test"
	require_file "$L1_DISK" L1_DISK
	require_file "$L2_DISK" L2_DISK
	require_file "$L2_BOOT_ROM" L2_BOOT_ROM
	ifconfig "$L1_TAP" >/dev/null 2>&1 || \
	    fail "L1_TAP interface '$L1_TAP' does not exist"
}

remove_stale_l1()
{
	if local_vm_exists; then
		log "destroying stale L0 VM $L1_VM_NAME before the -N CREATE"
		bhyvectl --vm="$L1_VM_NAME" --force-poweroff >/dev/null 2>&1 || true
		bhyvectl --vm="$L1_VM_NAME" --destroy >/dev/null 2>&1 || true
	fi
	local_vm_exists && fail "stale L0 VM $L1_VM_NAME could not be removed"
}

start_l1_console_capture()
{
	: > "$L1_SERIAL_LOG"
	cat "$L1_NMDM_B" >> "$L1_SERIAL_LOG" 2>&1 &
	L1_CONSOLE_PID=$!
}

record_l1_create_success()
{
	if ! wait_for_local_vm; then
		printf 'L1 bhyve output:\n' >&2
		tail -50 "$L1_BHYVE_LOG" >&2 || true
		fail "bhyve -N did not create $L1_VM_NAME"
	fi
	printf 'VMMCTL_VM_CREATE success: bhyve -N created %s with nested enabled\n' \
	    "$L1_VM_NAME" > "$L1_CREATE_LOG"
	grep -q '^VMMCTL_VM_CREATE success:' "$L1_CREATE_LOG" || \
	    fail "missing VMMCTL_VM_CREATE success record"
	log "$(cat "$L1_CREATE_LOG")"
}

launch_l1_full()
{
	remove_stale_l1
	start_l1_console_capture
	: > "$L1_BHYVE_LOG"
	: > "$L1_CREATE_LOG"

	log "L0: first launch is bhyve -N -m $L1_MEMORY ($L1_VM_NAME)"
	bhyve -N -m "$L1_MEMORY" -c "$L1_CPUS" -A -H -P \
	    -s 0:0,hostbridge \
	    -s 1:0,lpc \
	    -s 2:0,virtio-blk,"$L1_DISK" \
	    -s 3:0,virtio-net,"$L1_TAP" \
	    -l com1,"$L1_NMDM_A" \
	    -o bootrom="$L1_BOOT_ROM" \
	    "$L1_VM_NAME" >> "$L1_BHYVE_LOG" 2>&1 &
	L1_BHYVE_PID=$!

	record_l1_create_success
	kill -0 "$L1_BHYVE_PID" 2>/dev/null || \
	    fail "L1 exited after CREATE; inspect $L1_BHYVE_LOG"
}

launch_l1_create_smoke()
{
	remove_stale_l1
	start_l1_console_capture
	: > "$L1_BHYVE_LOG"
	: > "$L1_CREATE_LOG"

	# This is intentionally a second literal bhyve -N launch site: the tiny
	# path exercises CREATE without L1_DISK, virtio-blk, or SSH.
	log "L0 smoke: first launch is bhyve -N -m $L1_MEMORY ($L1_VM_NAME)"
	bhyve -N -m "$L1_MEMORY" -c 1 -A -H -P \
	    -s 0:0,hostbridge \
	    -s 1:0,lpc \
	    -l com1,"$L1_NMDM_A" \
	    -o bootrom="$L1_BOOT_ROM" \
	    "$L1_VM_NAME" >> "$L1_BHYVE_LOG" 2>&1 &
	L1_BHYVE_PID=$!

	record_l1_create_success
	kill -0 "$L1_BHYVE_PID" 2>/dev/null || \
	    fail "firmware-only L1 exited after CREATE; inspect $L1_BHYVE_LOG"
	log "CREATE-SMOKE PASS"
}

wait_for_l1_ssh()
{
	deadline=$(( $(date '+%s') + L1_SSH_TIMEOUT ))
	log "waiting up to ${L1_SSH_TIMEOUT}s for root SSH at $L1_SSH_HOST"
	while [ "$(date '+%s')" -lt "$deadline" ]; do
		remote_uid=$(ssh_l1 id -u 2>/dev/null || true)
		if [ "$remote_uid" = 0 ]; then
			L1_SSH_READY=1
			log "L1 SSH is ready"
			return 0
		fi
		if ! kill -0 "$L1_BHYVE_PID" 2>/dev/null; then
			tail -50 "$L1_BHYVE_LOG" >&2 || true
			fail "L1 exited while waiting for SSH"
		fi
		sleep 2
	done
	fail "L1 SSH did not become ready; inspect $L1_SERIAL_LOG"
}

write_l2_control_files()
{
	LOCAL_TMPDIR=$(mktemp -d /tmp/bhyve-in-bhyve.XXXXXX)
	L2_LOCAL_CONTROL=$LOCAL_TMPDIR/t37-l2-control.sh
	L2_LOCAL_CONFIG=$LOCAL_TMPDIR/t37-l2.conf

	cat > "$L2_LOCAL_CONFIG" <<-EOF_CONFIG
	L2_VM_NAME=$L2_VM_NAME
	L2_CPUS=$L2_CPUS
	L2_TAP=$L2_TAP
	L2_NMDM_A=$L2_NMDM_A
	L2_NMDM_B=$L2_NMDM_B
	L2_DISK=$L2_REMOTE_IMAGE
	L2_BOOT_ROM=$L2_REMOTE_BOOT_ROM
	L2_SERIAL_LOG=$L2_REMOTE_SERIAL
	L2_BHYVE_LOG=$L2_REMOTE_BHYVE_LOG
	L2_CONTROL=$L2_REMOTE_CONTROL
	L2_CONSOLE_SESSION=t37-l2-console
	L2_BHYVE_SESSION=t37-l2-bhyve
	EOF_CONFIG

	cat > "$L2_LOCAL_CONTROL" <<'L2_CONTROL_EOF'
#!/bin/sh
# Runs inside L1.  It is copied there by the L0 harness and is the only place
# where L2 bhyve/bhyvectl commands execute.
set -eu

CONFIG=/tmp/t37-l2.conf
[ -r "$CONFIG" ] || {
	printf 'missing %s\n' "$CONFIG" >&2
	exit 1
}
# shellcheck disable=SC1090
. "$CONFIG"

require_cmd()
{
	command -v "$1" >/dev/null 2>&1 || {
		printf 'L1 is missing required command: %s\n' "$1" >&2
		exit 1
	}
}

l2_exists()
{
	bhyvectl --vm="$L2_VM_NAME" --get-stats >/dev/null 2>&1
}

cleanup_l2()
{
	if l2_exists; then
		bhyvectl --vm="$L2_VM_NAME" --force-poweroff >/dev/null 2>&1 || true
	fi
	tmux kill-session -t "$L2_BHYVE_SESSION" >/dev/null 2>&1 || true
	tmux kill-session -t "$L2_CONSOLE_SESSION" >/dev/null 2>&1 || true
	if l2_exists; then
		# With defaults: bhyvectl --vm=l2-test --destroy, executed in L1.
		bhyvectl --vm="$L2_VM_NAME" --destroy >/dev/null 2>&1 || true
	fi
	! l2_exists
}

start_l2()
{
	require_cmd bhyve
	require_cmd bhyvectl
	require_cmd cat
	require_cmd kldload
	require_cmd tmux

	[ "$(id -u)" -eq 0 ] || {
		printf 'L2 control must run as root inside L1\n' >&2
		exit 1
	}
	[ -f "$L2_DISK" ] || {
		printf 'missing copied L2 image: %s\n' "$L2_DISK" >&2
		exit 1
	}
	[ -f "$L2_BOOT_ROM" ] || {
		printf 'missing copied L2 boot ROM: %s\n' "$L2_BOOT_ROM" >&2
		exit 1
	}

	kldload vmm >/dev/null 2>&1 || true
	kldload nmdm >/dev/null 2>&1 || true
	[ -c "$L2_NMDM_A" ] && [ -c "$L2_NMDM_B" ] || {
		printf 'L1 nmdm pair is unavailable\n' >&2
		exit 1
	}

	cleanup_l2 || {
		printf 'could not remove stale L2 VM %s\n' "$L2_VM_NAME" >&2
		exit 1
	}
	: > "$L2_SERIAL_LOG"
	: > "$L2_BHYVE_LOG"

	# tmux keeps both producers alive after the initiating SSH connection
	# closes.  The console half starts first so no early boot text is lost.
	tmux new-session -d -s "$L2_CONSOLE_SESSION" "$L2_CONTROL console"
	tmux new-session -d -s "$L2_BHYVE_SESSION" "$L2_CONTROL bhyve"

	start_count=0
	while [ "$start_count" -lt 50 ]; do
		if l2_exists; then
			printf 'L2 created inside L1: %s\n' "$L2_VM_NAME"
			return 0
		fi
		if ! tmux has-session -t "$L2_BHYVE_SESSION" >/dev/null 2>&1; then
			cat "$L2_BHYVE_LOG" >&2 || true
			return 1
		fi
		start_count=$((start_count + 1))
		sleep 0.1
	done
	cat "$L2_BHYVE_LOG" >&2 || true
	return 1
}

run_l2_bhyve()
{
	# This command runs in L1.  It has no -N because L2 is a regular VM.
	# The fixed 1G is part of the T37 acceptance scenario.
	exec bhyve -m 1G -c "$L2_CPUS" -A -H -P \
	    -s 0:0,hostbridge \
	    -s 1:0,lpc \
	    -s 2:0,virtio-blk,"$L2_DISK" \
	    -s 3:0,virtio-net,"$L2_TAP" \
	    -l com1,"$L2_NMDM_A" \
	    -o bootrom="$L2_BOOT_ROM" \
	    "$L2_VM_NAME" >> "$L2_BHYVE_LOG" 2>&1
}

case "${1:-}" in
start)
	start_l2
	;;
bhyve)
	run_l2_bhyve
	;;
console)
	exec cat "$L2_NMDM_B" >> "$L2_SERIAL_LOG" 2>&1
	;;
status)
	l2_exists && tmux has-session -t "$L2_BHYVE_SESSION" >/dev/null 2>&1
	;;
cleanup)
	cleanup_l2
	;;
*)
	printf 'usage: %s {start|bhyve|console|status|cleanup}\n' "$0" >&2
	exit 64
	;;
esac
L2_CONTROL_EOF
	chmod 700 "$L2_LOCAL_CONTROL"
}

install_and_launch_l2()
{
	write_l2_control_files
	log "copying the small L2 FreeBSD image into L1"
	scp_to_l1 "$L2_DISK" "$L2_REMOTE_IMAGE"
	scp_to_l1 "$L2_BOOT_ROM" "$L2_REMOTE_BOOT_ROM"
	scp_to_l1 "$L2_LOCAL_CONFIG" "$L2_REMOTE_CONFIG"
	scp_to_l1 "$L2_LOCAL_CONTROL" "$L2_REMOTE_CONTROL"
	ssh_l1 "chmod 700 $L2_REMOTE_CONTROL"
	L2_CONTROL_INSTALLED=1

	log "L1: launching L2 with bhyve -m 1G (no -N)"
	ssh_l1 "$L2_REMOTE_CONTROL start"
}

capture_l2_serial()
{
	capture_tmp=$L2_LOG_FILE.tmp.$$
	if ssh_l1 "cat $L2_REMOTE_SERIAL" > "$capture_tmp" 2>/dev/null; then
		mv "$capture_tmp" "$L2_LOG_FILE"
		return 0
	fi
	rm -f "$capture_tmp"
	return 1
}

l2_reached_multi_user()
{
	[ -f "$L2_LOG_FILE" ] || return 1
	grep -q 'FreeBSD' "$L2_LOG_FILE" && \
	    grep -Eq '(^|[[:space:]])login:[[:space:]]*$' "$L2_LOG_FILE"
}

verify_l2_boot()
{
	: > "$L2_LOG_FILE"
	deadline=$(( $(date '+%s') + L2_BOOT_TIMEOUT ))
	log "waiting up to ${L2_BOOT_TIMEOUT}s for the L2 FreeBSD login prompt"
	while [ "$(date '+%s')" -lt "$deadline" ]; do
		capture_l2_serial || true
		if l2_reached_multi_user; then
			log "L2 FreeBSD reached multi-user mode"
			return 0
		fi
		if ! ssh_l1 "$L2_REMOTE_CONTROL status" >/dev/null 2>&1; then
			capture_l2_serial || true
			tail -50 "$L2_LOG_FILE" >&2 || true
			fail "L2 exited before reaching the multi-user login prompt"
		fi
		sleep 2
	done
	capture_l2_serial || true
	tail -50 "$L2_LOG_FILE" >&2 || true
	fail "L2 did not reach the FreeBSD multi-user login prompt"
}

main()
{
	preflight_common
	if [ "$MODE" = create-smoke ]; then
		launch_l1_create_smoke
		return 0
	fi

	preflight_full
	launch_l1_full
	wait_for_l1_ssh
	install_and_launch_l2
	verify_l2_boot
	log "L1+L2 PASS; L2 serial log: $L2_LOG_FILE"
}

main
