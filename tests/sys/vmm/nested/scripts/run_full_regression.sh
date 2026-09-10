#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
#
# Full nested-virt regression: sysctls, preflight matrix, optional
# vmx_nested_test.ko, bhyve -N presence.
#
# This is the ON-HOST matrix. It is not a substitute for the VM boot
# gate (run_vm_boot_gate.sh), which must PASS before a candidate kernel
# is installed on bare metal. Nested features are not required for that
# gate.

set -eu

preflight_dir=$(cd "$(dirname "$0")/../hw/preflight" && pwd)
status=0

echo "=== host ==="
hostname
uname -v
sysctl hw.model hw.ncpu kern.vm_guest 2>/dev/null | cat

echo "=== vmm ==="
if ! kldstat -q -n vmm; then
	echo "vmm.ko not loaded; attempting kldload"
	sudo -n kldload vmm || sudo -n kldload /boot/kernel/vmm.ko || true
fi
kldstat | grep vmm || true

echo "=== sysctl ==="
sudo -n sysctl hw.vmm.nested.enable=1 2>/dev/null || true
sysctl hw.vmm.nested.enable hw.vmm.nested.vmx hw.vmm.nested.svm 2>&1 | tee /tmp/nv-sysctl.txt

echo "=== preflight.sh ==="
if [ -x /usr/local/bin/preflight ]; then
	sudo -n env PREFLIGHT_DMESG=/var/run/dmesg.boot /usr/local/bin/preflight | tee /tmp/nv-preflight.txt | tail -20
elif [ -x "${preflight_dir}/../../../../../../tools/preflight.sh" ]; then
	sudo -n env PREFLIGHT_DMESG=/var/run/dmesg.boot \
	    "${preflight_dir}/../../../../../../tools/preflight.sh" | tee /tmp/nv-preflight.txt | tail -20
else
	echo "SKIP preflight.sh binary"
fi

echo "=== 17-test matrix ==="
sudo -n env PREFLIGHT_DMESG=/var/run/dmesg.boot \
    bash "${preflight_dir}/run_preflight_tests.sh" | tee /tmp/nv-tests.txt
test_rc=${PIPESTATUS[0]}
if [ "$test_rc" -ne 0 ]; then
	status=1
fi

echo "=== vmx_nested_test.ko ==="
#
# This section had two defects and the second is the worse one.
#
# It searched /boot/modules before /boot/kernel, so on a host that had ever
# hand-placed a module there the matrix loaded that one in preference to the
# one installkernel had just put down. Measured on an AMD test host: a
# three-week-old module reported "1/5 PASS" while the module belonging to the
# kernel under test reported "8/12 PASS", and tests 6 through 12 never ran.
#
# And it never read the verdict. It printed dmesg and set no status, so a
# module reporting every sub-test FAIL exited this script 0. It was a printer,
# not a check.
#
# There is deliberately no environment override for the path. An earlier
# version took one so that using a hand-placed module would at least be a
# visible decision, but an environment variable naming a file this script then
# hands to kldload as root is a larger hole than the problem it solved. Load
# such a module by hand instead.
#
mod=
_modfail=no
_bad() {	# one place that records a failure, so no path forgets half of it
	echo "FAIL: $*"
	status=1
	_modfail=yes
	mod=
}

[ -e /boot/kernel/vmx_nested_test.ko ] && mod=/boot/kernel/vmx_nested_test.ko

# The running kernel is kern.bootfile, not /boot/kernel/kernel: booted from
# kernel.old or under a loader override, those differ. Not being able to
# establish it is its own failure -- "could not look" is not "looked and it was
# fine".
if [ -n "$mod" ]; then
	bootfile=$(sysctl -n kern.bootfile 2>/dev/null || true)
	[ -n "$bootfile" ] && [ -r "$bootfile" ] ||
	    _bad "cannot establish the running kernel (kern.bootfile)"
fi

# Booted from somewhere else entirely: the module found under /boot/kernel
# belongs to a kernel that is not running.
if [ -n "$mod" ]; then
	case "$bootfile" in
	/boot/kernel/*) ;;
	*)	_bad "running $bootfile, but the module found is $mod --" \
		    "they are not from the same install" ;;
	esac
fi

# Installed but not rebooted: kern.bootfile still READS /boot/kernel/kernel,
# because installkernel replaced the file underneath it, so the path check
# above passes and the pairing is still wrong. Asked, not parsed -- does the
# running kernel's exact version line occur in the file on disk? Picking "the
# first ^FreeBSD N.N string" out of a binary and calling it the version is two
# guesses about a file layout, and the question needs neither.
if [ -n "$mod" ]; then
	_kv=$(sysctl -n kern.version 2>/dev/null | head -1)
	if [ -z "$_kv" ]; then
		_bad "cannot read kern.version"
	elif ! _kimg=$(strings -a "$bootfile" 2>/dev/null); then
		# strings missing or failing is not evidence about the kernel.
		_bad "cannot read $bootfile (strings failed)"
	elif ! printf '%s\n' "$_kimg" | grep -qxF "$_kv"; then
		_bad "$bootfile has been replaced since boot;" \
		    "the module beside it belongs to a different build"
		echo "      running: $_kv"
	fi
fi

# A second, independent signal, because the version line cannot see everything.
# Under WITH_REPRODUCIBLE_BUILD the first line of kern.version carries no
# timestamp and no user@host -- just the release, the build number from the obj
# directory, and the git description. A rebuild of the same commit on another
# host, or of a dirty tree with any set of uncommitted edits, produces the same
# line. So also ask whether the file was written after this boot: it cannot
# have been the file that booted if it was.
#
# ctime, not mtime. install -p and cp -p preserve mtime, so a three-week-old
# module copied into place today keeps its three-week-old mtime and an mtime
# check waves it through -- which is precisely the defect this section was
# written for. ctime is set by the kernel on any inode change and cannot be
# preserved by either, so "placed here after this boot" is answerable
# regardless of when the file was built.
if [ -n "$mod" ]; then
	# Anchored on "{ sec =", not ".*sec = ": the value is printed as
	# "{ sec = N, usec = M } ...", and a greedy .* matches through to
	# "usec = " and captures the MICROSECONDS. Measured: that returns a
	# six-digit number, every comparison against it fails, and the check
	# refuses every correct host.
	_bt=$(sysctl -n kern.boottime 2>/dev/null |
	    sed -n 's/^{ sec = \([0-9][0-9]*\).*/\1/p')
	_km=$(stat -f %c "$bootfile" 2>/dev/null)
	if [ -z "$_bt" ] || [ -z "$_km" ]; then
		_bad "cannot compare $bootfile against the boot time"
	elif [ "$_km" -gt "$_bt" ]; then
		_bad "$bootfile was written after this boot;" \
		    "it is not the file that booted"
	fi
fi

# And the same question about the MODULE, which is the thing actually loaded:
# every check above interrogates the kernel file, and a module dropped into
# /boot/kernel leaves the kernel untouched, so all of them pass.
#
# This BOUNDS the module rather than pairing it. "Not placed here since the
# machine booted" catches a module copied in after an installkernel, which is
# how the measured defect arose. It does not catch a stale module copied in
# BEFORE a reboot: its ctime then predates boot and every check here passes.
#
# Pairing is not answerable from the filesystem. It needs the module to carry
# the kernel identity it was built against -- the first line of kern.version,
# embedded at build time and printed at load -- and this script to compare that
# against the running kernel. That is one line in the module and it would
# retire both this check and the buffer-clearing below, since a per-load
# identity line is also a per-load boundary.
if [ -n "$mod" ]; then
	_mm=$(stat -f %c "$mod" 2>/dev/null)
	if [ -z "$_mm" ]; then
		_bad "cannot stat $mod"
	elif [ "$_mm" -gt "$_bt" ]; then
		_bad "$mod was written after this boot;" \
		    "it is not from the install that booted"
	fi
fi

# dmesg has to work before its silence can mean anything. With
# security.bsd.unprivileged_read_msgbuf=0 an unprivileged dmesg reads nothing,
# and "the module printed no summary" would be the diagnosis for "I could not
# read the message buffer".
if [ -n "$mod" ]; then
	dmesg >/dev/null 2>&1 ||
	    _bad "cannot read the kernel message buffer (dmesg failed)"
fi

if [ -n "$mod" ]; then
	echo "using $mod ($(sha256 -q "$mod" | cut -c1-16)...)"
	# ctime beside mtime, because ctime is what the check above uses. Showing
	# only mtime put a three-week-old date on screen directly above "was
	# written after this boot", so the evidence appeared to contradict the
	# verdict in exactly the case this was written for.
	echo "  module: mtime $(stat -f '%Sm' -t '%F %T' "$mod")" \
	    "ctime $(stat -f '%Sc' -t '%F %T' "$mod")"
	echo "  kernel: mtime $(stat -f '%Sm' -t '%F %T' "$bootfile")" \
	    "ctime $(stat -f '%Sc' -t '%F %T' "$bootfile")"
	echo "  booted: $(sysctl -n kern.boottime |
	    sed -n 's/.*} //p')  ($bootfile)"

	sudo -n kldunload vmx_nested_test 2>/dev/null || true

	# Empty the message buffer, so what is in it afterwards is provably
	# this load's.
	#
	# Three boundaries were tried before this one and all three were worse.
	# A line count taken before the load assumes the ring only grows, and
	# it does not: on a host with any uptime each new line evicts one and
	# the count barely moves. `dmesg | tail -1' as a mark fails in the case
	# it was written for -- if the summary is the last line the module
	# prints, then on a second identical run the mark IS that summary and
	# the last occurrence is this run's own, leaving nothing after it. A
	# nonce cannot be injected: with kern.log_console_output=1 a userland
	# write to /dev/console never reaches dmesg, because that sysctl logs
	# the KERNEL's console output.
	#
	# Clearing removes the class instead of navigating it. Being unable to
	# clear is a failure, not a reason to fall back to slicing -- an
	# uncleared buffer is exactly the state where a previous run's
	# byte-identical summary gets reported as this one's.
	# Saved first, and the save is required. The claim "nothing is lost,
	# syslogd has it" assumes syslogd is running and that kern.* is routed
	# to a file, neither of which this script establishes -- and on a
	# minimal test image the clear would destroy what the preflight
	# sections and any prior activity put in the buffer, mid-run, before
	# anyone read it.
	# mktemp, not a predictable name under a world-writable directory. A
	# redirect onto $$-derived path in /tmp follows a symlink a local user
	# can plant, and as root that overwrites whatever it points at -- and
	# the script would read the successful write as a good save and go on
	# to clear the live buffer. LOGDIR is checked rather than trusted: an
	# unset or wrong value would put the file somewhere nobody looks.
	_savedir=${LOGDIR:-/tmp}
	if [ ! -d "$_savedir" ]; then
		_bad "LOGDIR=$_savedir is not a directory"
	elif ! _dmesgsave=$(mktemp "$_savedir/dmesg-before-vmx.XXXXXX"); then
		_bad "cannot create a file in $_savedir to save the buffer"
	elif ! dmesg > "$_dmesgsave" 2>/dev/null; then
		_bad "cannot save the message buffer to $_dmesgsave"
	else
		echo "  buffer saved to $_dmesgsave before clearing"
		sudo -n sysctl kern.msgbuf_clear=1 >/dev/null 2>&1 ||
		    _bad "cannot clear the kernel message buffer"
	fi
fi

if [ -n "$mod" ]; then
	if ! sudo -n kldload "$mod"; then
		_bad "kldload $mod"
	else
		_out=$(dmesg | grep vmx_nested_test || true)
		printf '%s\n' "$_out"
		sudo -n kldunload vmx_nested_test || true

		# The whole summary shape, so every field the verdict uses is
		# known to be present. An earlier version matched only as far
		# as "FAIL" and cut off the skip count -- the one number that
		# says whether anything ran.
		_sum=$(printf '%s\n' "$_out" |
		    grep -E '[0-9]+/[0-9]+ PASS \([0-9]+ FAIL, [0-9]+ SKIP\)$' |
		    tail -1)
		if [ -z "$_sum" ]; then
			echo "FAIL: $mod loaded but printed no summary"
			status=1
		else
			echo "  summary: ${_sum#*: }"
			_n=$(printf '%s\n' "$_sum" |
			    grep -oE '[0-9]+/[0-9]+ PASS \([0-9]+ FAIL, [0-9]+ SKIP\)$')
			_pass=${_n%%/*}
			_total=${_n#*/}; _total=${_total%% *}
			_fail=${_n##*(}; _fail=${_fail%% *}
			_skip=${_n##*FAIL, }; _skip=${_skip%% *}
			if [ $((_pass + _fail + _skip)) -ne "$_total" ]; then
				# Sub-tests that neither passed, failed nor
				# skipped did not run, and no other number here
				# says so.
				echo "FAIL: $_pass+$_fail+$_skip does not" \
				    "account for all $_total sub-tests"
				status=1
			elif [ "$_fail" -ne 0 ]; then
				echo "FAIL: $_fail sub-test(s) failed"
				status=1
			elif [ "$_pass" -eq 0 ]; then
				# "0 failed" is also true of a suite that never
				# started.
				echo "FAIL: 0 sub-tests passed -- nothing ran"
				status=1
			elif [ -z "$(sysctl -n hw.model 2>/dev/null)" ]; then
				echo "FAIL: cannot read hw.model, so the" \
				    "expected skip count is unknown"
				status=1
			elif sysctl -n hw.model 2>/dev/null | grep -qi intel; then
				# Every skip this module emits is guarded by
				# "not Intel", so on an Intel host none should
				# fire and a skip is a test that did not run.
				# That is a fact about the module as it stands,
				# not a rule it is obliged to keep: a future
				# Intel-side skip would fail here, and the fix
				# then is for the module to report its own
				# expected-skip count rather than for this
				# script to guess.
				[ "$_skip" -eq 0 ] || {
					echo "FAIL: $_skip sub-test(s) skipped" \
					    "on Intel, where all apply"
					status=1
				}
			fi
		fi
	fi
elif [ "$_modfail" != yes ]; then
	# Absence is only a SKIP on a kernel that never carried the module.
	# Deciding that on hw.vmm.nested.enable alone was wrong: that sysctl
	# exists only while vmm.ko is loaded, so "vmm not loaded" and "stock
	# kernel" collapsed into one SKIP and the whole control was removable
	# by deleting a file.
	sudo -n kldload -n vmm 2>/dev/null || true
	if ! kldstat -q -m vmm; then
		echo "FAIL: cannot establish whether this is a nested-virt" \
		    "kernel (vmm did not load)"
		status=1
	elif sysctl -n hw.vmm.nested.enable >/dev/null 2>&1; then
		echo "FAIL: this is a nested-virt kernel and" \
		    "/boot/kernel/vmx_nested_test.ko is missing"
		status=1
	else
		echo "SKIP: not a nested-virt kernel; no module expected"
	fi
fi

echo "=== bhyve -N ==="
bhyve_bin=""
for b in /usr/local/sbin/bhyve-nested /usr/sbin/bhyve bhyve; do
	if command -v "$b" >/dev/null 2>&1 || [ -x "$b" ]; then
		bhyve_bin=$b
		break
	fi
done
if [ -n "$bhyve_bin" ] && "$bhyve_bin" -h 2>&1 | grep -q -- '-N'; then
	echo "PASS: $bhyve_bin advertises -N"
else
	echo "FAIL: no bhyve with -N (tried bhyve-nested and /usr/sbin/bhyve)"
	status=1
fi

echo "=== nested-off (opt-in) negative ==="
# Nesting must be strictly opt-in: a guest booted without -N must get no
# virtualization. This boots a real L1 (needs L1_IMAGE) and asserts it.
neg_off="$(dirname "$0")/../negative/nested_off.sh"
if [ -n "${L1_IMAGE:-}" ] && [ -r "${L1_IMAGE:-}" ] && [ -r "$neg_off" ]; then
	if sh "$neg_off"; then
		echo "PASS: nested is off in an un-opted-in guest"
	else
		echo "FAIL: nested-off negative test"; status=1
	fi
else
	echo "SKIP: nested_off (set L1_IMAGE to run the guest-level opt-in check)"
fi

echo "=== SUMMARY exit=$status ==="
exit "$status"
