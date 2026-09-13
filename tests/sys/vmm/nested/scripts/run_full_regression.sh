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

# PATH is pinned for the whole run, not for one section.
#
# Every verifier this script relies on -- sysctl, kldstat, pkg, realpath,
# mktemp -- is invoked by bare name, and FreeBSD cron's default PATH is
# /usr/bin:/bin, which contains none of /sbin/sysctl, /sbin/kldstat or
# /usr/sbin/pkg. Run from cron the script died before reaching most of its
# checks. In the other direction a shim earlier on PATH answers whatever it
# likes, and a check that asks "is this the packaged file" would take its
# answer from that: the one question this script exists to settle would be
# settled by the attacker.
#
# It also retires an argument this file has had with itself twice, about
# whether to fall back to /usr/sbin/bhyve when PATH does not resolve it. With
# PATH pinned, "the bhyve PATH resolves" and "the bhyve a standard environment
# runs" are the same file, and the fallback is a note rather than a decision.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

# Pinning PATH stops a shim placed EARLIER than the real tool. It does not stop
# a RELOCATED one: these are bare names, and /usr/local/sbin is on the path
# because bash lives under /usr/local. Remove /usr/sbin/pkg and the next hit is
# /usr/local/sbin/pkg, which could answer whatever it liked about ownership and
# checksums.
#
# So resolve each oracle once, NAME it in the output, and call it by the
# resolved path. Naming a tool does not make it trustworthy and that is not
# claimed; it makes a relocated one visible as the path it was found at instead
# of answering silently, and it refuses to run at all when one is missing rather
# than discovering that in the middle of a verdict. Note that realpath is
# /bin/realpath here, not /usr/bin/realpath, which is why the paths are
# resolved rather than written down.
echo "=== verifiers ==="
_oracle_bad=0
# grep and sed are in this list for one reason: if either is ABSENT, the
# classifiers below (_unexplained, _mismatch_set, _mismatch) quietly produce
# "nothing unexplained" and "not one of my files", and a branch that reads those
# as good news prints PASS. A missing text filter must be fatal, not silently
# permissive. They are NOT called by the resolved path afterwards, and the scope
# of this block is therefore worth stating plainly rather than leaving implied:
# it pins the tools that ANSWER QUESTIONS ABOUT THE SYSTEM -- sysctl, kldstat,
# pkg -- and it makes the absence of a text filter fatal. A substituted grep or
# sed is outside it, and deliberately so: on a host where /usr/bin/grep has been
# replaced, nothing is measurable, pkg included, and a harness is the wrong place
# to pretend otherwise.
_SYSCTL=; _KLDSTAT=; _REALPATH=; _MKTEMP=
for _o in sysctl kldstat realpath mktemp grep sed; do
	if _op=$(command -v "$_o" 2>/dev/null) && [ -x "$_op" ]; then
		printf '  %-9s %s\n' "$_o" "$_op"
		case "$_o" in
		sysctl)		_SYSCTL=$_op ;;
		kldstat)	_KLDSTAT=$_op ;;
		realpath)	_REALPATH=$_op ;;
		mktemp)		_MKTEMP=$_op ;;
		esac
	else
		printf '  %-9s NOT FOUND on the pinned PATH\n' "$_o"
		_oracle_bad=1
	fi
done

# pkg is resolved by hand, because the first `pkg' on PATH is not the one that
# answers. /usr/sbin/pkg is FreeBSD-pkg-bootstrap; the tool that reads the
# database is /usr/local/sbin/pkg from the pkg port, and the bootstrapper
# execs it. Printing /usr/sbin/pkg as the oracle would therefore name a binary
# that answered nothing while a replaced /usr/local/sbin/pkg gave every verdict
# in this file -- exactly the relocated-oracle case this block exists to expose.
#
# Only-the-bootstrapper is refused rather than used. On such a host pkg is not
# installed, and running `pkg check' there does not fail: the bootstrapper
# FETCHES AND INSTALLS pkg from the configured packagesite, silently under
# ASSUME_ALWAYS_YES, which is how a read-only identity check turns into a
# package installation over the network.
# command -v is not consulted at all. It answers with the first `pkg' on PATH,
# and PATH begins /sbin:/bin:/usr/sbin:/usr/bin -- so a `pkg' dropped in any of
# those four wins and becomes the ownership and checksum oracle, which is the
# substitution this whole block exists to refuse. Only the two paths the pkg
# port installs to are accepted.
_PKG=
for _c in /usr/local/sbin/pkg /usr/local/bin/pkg; do
	if [ -x "$_c" ]; then _PKG=$_c; break; fi
done
if [ -n "$_PKG" ]; then
	# Pinning the binary is not enough: pkg's identity answers come from a
	# DATABASE, and the environment chooses the database. Measured --
	# `PKG_DBDIR=/tmp/nosuchdb pkg which /usr/sbin/bhyve' answers "not found
	# in the database" without a word of complaint, so an inherited
	# PKG_DBDIR turns every ownership and checksum verdict below into a
	# statement about some other machine while this line prints the right
	# binary. Pinned to the base default, which `pkg config PKG_DBDIR'
	# reports on a fleet host, and asserted to exist.
	#
	# The limit, stated rather than implied: this pins the database. It does
	# not enumerate every knob pkg reads.
	PKG_DBDIR=/var/db/pkg
	export PKG_DBDIR
	# PKG_ROOTDIR is the same hole one level up, and it is the worse of the
	# two. Measured: `PKG_ROOTDIR=/tmp/nosuchroot pkg check -s
	# CloudBSD-bhyve' EXITS 0 and prints "Checking CloudBSD-bhyve: . done".
	# A clean pass, for a root that does not exist -- so an inherited
	# variable does not merely answer about another machine, it answers
	# about no machine and calls it good. Everything in this section
	# believes that answer.
	PKG_ROOTDIR=/
	export PKG_ROOTDIR
	unset PKG_CHROOTDIR 2>/dev/null || :
	if [ -d "$PKG_DBDIR" ]; then
		printf '  %-9s %s (db %s)\n' pkg "$_PKG" "$PKG_DBDIR"
	else
		printf '  %-9s %s -- database %s is missing\n' \
		    pkg "$_PKG" "$PKG_DBDIR"
		_oracle_bad=1
	fi
else
	printf '  %-9s NOT INSTALLED (only the bootstrapper is present)\n' pkg
	_oracle_bad=1
fi

if [ "$_oracle_bad" -ne 0 ]; then
	echo "FATAL: a verifier this script reads its answers from is missing,"
	echo "       so no verdict below would mean anything"
	exit 2
fi
# _probe <command...> -- run it, keep BOTH halves of the answer. Sets
# _probe_rc, _probe_out and _probe_err; returns 3 when the run could not be
# attempted at all, 0 otherwise. The point is that a command's exit status and
# its stderr are different facts, and collapsing them is how "I could not ask"
# became a confident wrong diagnosis: `sysctl -n <oid> 2>/dev/null || echo
# absent' reports an unreadable, unexecutable or permission-denied sysctl as a
# kernel with no nested-virt support, which is the loudest wrong answer
# available. Same temporary-file rule as _pkg_ask: no fallback path, because
# unlinking a fallback as root deletes whatever it pointed at.
_probe() {
	_probe_rc=0; _probe_out=; _probe_err=
	if ! _pe=$("$_MKTEMP" /tmp/nvreg-probe.XXXXXXXX); then
		echo "cannot create a temporary file" >&2
		return 3
	fi
	_probe_out=$("$@" 2>"$_pe") || _probe_rc=$?
	_probe_err=$(cat "$_pe" 2>/dev/null)
	rm -f "$_pe"
	return 0
}


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
# Read BEFORE the set below. The verdict near the end of this script reports
# hw.vmm.nested.enable, and on a root or cron run this line has already made it
# 1 -- so a machine that booted with nesting off produced "PASS: ... is 1"
# about a value the harness itself wrote, and the FAIL saying nesting is turned
# off was reachable only when this set FAILED. A check that causes the
# condition it asserts cannot fail, which is the shape this file keeps finding
# and removing.
# Read through _probe, not `|| echo unknown': a sysctl that could not run and
# a kernel without the OID are different facts, and the verdict below
# distinguishes them. The write's status is kept for the same reason -- `||
# true' made a failed set and a successful one the same sentence, so the
# verdict could claim this run turned nesting on when it had not.
_ne_boot=unreadable
if _probe "$_SYSCTL" -n hw.vmm.nested.enable; then
	if [ "$_probe_rc" -eq 0 ]; then
		_ne_boot=$_probe_out
	elif printf '%s\n' "$_probe_err" | grep -q 'unknown oid'; then
		_ne_boot=absent
	fi
fi
_ne_set=no
if sudo -n "$_SYSCTL" hw.vmm.nested.enable=1 >/dev/null 2>&1; then
	_ne_set=yes
fi
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

echo "=== bhyve and the kernel are the ones their packages installed ==="
#
# This asked whether some bhyve advertised -N, and that was wrong twice over.
#
# -N is a deprecated flag: not in this tree's usr.sbin/bhyve, and the packaged
# bhyve rejects it ("illegal option -- N", no N in its usage). The demo runner
# already says so in its own comment -- "ask the kernel, not a deprecated flag"
# -- and nothing on the public site mentions -N or bhyve-nested.
#
# So the check could only pass on a host carrying a hand-placed bhyve-nested.
# Measured across two AMD hosts running one kernel: one had an August binary in
# /usr/local/sbin linking stock FreeBSD's lib9p.so.1 and "passed"; the other
# lacked that unpackaged library, so the same binary could not start and the
# host "failed". Neither verdict described the release, and the PASS was the
# worse of the two because nobody investigates a PASS.
#
# What is asked instead: are the files that carry the nested-virt code the ones
# their packages installed, and does the kernel report nesting?

# Each pkg question keeps its stderr, because pkg exits 1 both for "not in the
# database" and for "I could not open the database" -- a locked database
# otherwise becomes a confident wrong answer. Failures print on STDOUT with
# every other verdict: sending them to stderr left a stdout log ending with no
# FAIL line beside a non-zero exit, which is "I could not look" made invisible.
# No fallback for the temporary file: an earlier version used
# `|| _tmp=/dev/null' and then unlinked it, which as root deletes the node.
_pkg_ask() {	# _pkg_ask <label> <pkg args...>  -> stdout, 0 ok / 1 empty / 3 error
	_lbl=$1; shift
	# An explicit template, so a caller TMPDIR does not choose where
	# this lands.
	if ! _e=$("$_MKTEMP" /tmp/nvreg-pkg.XXXXXXXX); then
		echo "cannot create a temporary file" >&2
		return 3
	fi
	_rc=0
	_o=$("$_PKG" "$@" 2>"$_e") || _rc=$?
	_m=$(cat "$_e" 2>/dev/null)
	rm -f "$_e"
	# A non-zero exit is never promoted to an answer. Exit 1 with nothing
	# at all is pkg's "no such row", which is a real result and returns 1
	# below. Exit 1 that nevertheless PRINTED something is a partial
	# answer -- some rows resolved, then the query failed -- and an earlier
	# version returned that text as though the question had been answered,
	# so a caller compared a truncated list against the release and
	# reported on whatever had made it out before the failure.
	if [ "$_rc" -gt 1 ] ||
	    { [ "$_rc" -ne 0 ] && { [ -n "$_m" ] || [ -n "$_o" ]; }; }; then
		# Detail on stderr, where command substitution does not eat it.
		# The caller prints the FAIL line itself, on stdout with every
		# other verdict -- an earlier version printed it here and every
		# caller captured it into a variable and threw it away, so the
		# fix for "invisible on stderr" produced a different
		# invisibility.
		echo "pkg $_lbl:" >&2
		[ -n "$_m" ] && printf '%s\n' "$_m" | sed 's/^/      /' >&2
		return 3
	fi
	printf '%s' "$_o"
	[ -n "$_o" ]
}


# _canon <path> -- the path pkg and the checksum lines will name. _mismatch is
# a byte-exact tail compare against what the manifest recorded, so an
# equivalent-but-differently-spelled path ("/boot//kernel/kernel", a symlinked
# /boot) is read as "a mismatch on some other file" and the section passes a
# replaced kernel. bhyve was already canonicalised for exactly this reason; the
# booted kernel and the loaded module were not.
_canon() {
	"$_REALPATH" "$1" 2>/dev/null
}

# _mismatch <pkg-check-output> <path>  -- true when THAT path is named.
# The line pkg prints is exactly "<pkg>-<ver>: checksum mismatch for <path>",
# measured, so the path anchors to the end. A substring match was wrong:
# /usr/sbin/bhyve is a prefix of /usr/sbin/bhyvectl and /usr/sbin/bhyveload.
# _unexplained <pkg-check-output> -- lines that are neither pkg's progress
# chatter nor a checksum mismatch. A mismatch line anywhere used to make the
# whole output "explained", so an unreadable or missing file reported in the
# same run was masked by an unrelated mismatch and the section printed PASS.
# ONE selector for what counts as a mismatch line, shared by everything that
# asks. Three patterns for one concept used to disagree: _unexplained stripped
# "checksum mismatch for ", _mismatch_set extracted only from
# ": checksum mismatch for ", and the leftover branch tested "checksum
# mismatch". A line the first two classified differently fell through every
# guard into a PASS. Whatever the selector admits must therefore be parsed by
# _mismatch_set or reported UNRESOLVED by it -- there is no third outcome.
_unexplained() {
	printf '%s\n' "$1" |
	    grep -v '^Checking ' |
	    grep -v 'checksum mismatch' |
	    grep -v '^[[:space:]]*$'
}

# _mismatch_set <pkg-check-output> -- every path pkg named as a checksum
# mismatch, canonicalised the same way the paths it gets compared against are.
#
# Canonicalising only one side was a fail-open. The paths this is compared with
# come from kern.bootfile, kldstat and `command -v bhyve', all put through
# realpath; the paths here come from pkg's manifest, which records whatever was
# recorded at install time. Two spellings of the same file then compare unequal,
# `_mismatch' says no, the line is stripped as "explained", and the branch that
# notes "a mismatch on another of its files" prints PASS for a replaced kernel.
#
# A path that does not resolve is emitted as "UNRESOLVED <path>" rather than
# dropped: pkg named a file whose identity cannot be established, and that is
# not the same fact as a mismatch on some other file.
_mismatch_set() {
	printf '%s\n' "$1" |
	    grep 'checksum mismatch' |
	    while IFS= read -r _ml; do
		_mp=$(printf '%s\n' "$_ml" |
		    sed -n 's/.*: checksum mismatch for //p')
		if [ -z "$_mp" ]; then
			# Admitted by the selector, named no path. pkg's
			# measured form is "<pkg>-<ver>: checksum mismatch for
			# <path>"; a line that does not carry it is a mismatch
			# this code cannot attribute, which is the one thing it
			# must not silently treat as somebody else's file.
			printf 'UNRESOLVED %s\n' "$_ml"
		elif _mc=$("$_REALPATH" "$_mp" 2>/dev/null); then
			printf '%s\n' "$_mc"
		else
			printf 'UNRESOLVED %s\n' "$_mp"
		fi
	    done
}

_mismatch() {
	# -F, with the line split at the marker, because the path is DATA and
	# grep would read it as a pattern: the dot in vmm.ko matches any
	# character, so "/boot/kernel/vmm.ko" also matches "/boot/kernel/vmmXko"
	# and any similarly shaped sibling. Comparing the tail of the line as a
	# fixed string asks the question that was meant.
	_mismatch_set "$1" | grep -qxF "$2"
}

# _mismatch_unresolved <pkg-check-output> -- true when pkg complained about a
# file that cannot be resolved, which is the one case where "not one of mine"
# cannot be established and so must not be read as good news.
_mismatch_unresolved() {
	_mismatch_set "$1" | grep -q '^UNRESOLVED '
}

# The release everything here is compared against, asked before either half
# and independently of both. It used to be asked inside the bhyve branch, so a
# host with no bhyve on PATH skipped the kernel verification as well -- a
# section titled "bhyve and the kernel" that checked neither.
#
# Absent is a failure, not silence: this harness ships inside the release
# package, so a host running it whose kernel came from no package has not got
# the thing the release delivers.
_ask=0
_kpkg=$(_pkg_ask "for the kernel package version" query %v \
    CloudBSD-kernel-generic) || _ask=$?
case $_ask in
0)	: ;;
1)	echo "FAIL: CloudBSD-kernel-generic is not installed, so there is no"
	echo "      release for the files on this host to belong to"
	status=1; _kpkg= ;;
*)	echo "FAIL: could not ask pkg for the kernel package version" \
	    "(detail on stderr)"
	status=1; _kpkg= ;;
esac

_bhyve_ok=no
bhyve_bin=
# PATH first, then the standard location -- and SAY which one was used.
#
# The fallback is unreachable while PATH is pinned at the top of this script,
# because that pin includes /usr/sbin. It is kept so that the message names the
# file examined if the pin is ever loosened, and because a check calling itself
# "the bhyve on PATH" while silently reporting on a different file is the kind
# of quiet subject-change this section exists to remove.
if bhyve_bin=$(command -v bhyve 2>/dev/null) && [ -x "$bhyve_bin" ]; then
	:
elif [ -x /usr/sbin/bhyve ]; then
	bhyve_bin=/usr/sbin/bhyve
	echo "note: bhyve is not on PATH; examining /usr/sbin/bhyve"
else
	bhyve_bin=
fi
if [ -z "$bhyve_bin" ]; then
	echo "FAIL: no bhyve on PATH and none at /usr/sbin/bhyve"
	status=1
elif ! bhyve_bin=$("$_REALPATH" "$bhyve_bin" 2>/dev/null); then
	echo "FAIL: cannot resolve the bhyve on PATH to a real path"
	status=1
else
	# Canonical from here on. command -v returns the PATH entry verbatim,
	# so a trailing slash in PATH gives /usr/sbin//bhyve -- measured -- and
	# a symlink gives the link path, while pkg speaks canonical paths. The
	# ownership question and the checksum verdict must be about one string.
	# `|| _ask=$?' rather than a bare assignment: set -eu is in effect and a
	# command substitution that exits non-zero ends the script there, so
	# the case below never ran and every classified pkg failure was a
	# silent exit with no FAIL line at all.
	_ask=0
	_owner=$(_pkg_ask "who owns $bhyve_bin" which -q "$bhyve_bin") || _ask=$?
	case $_ask in
	0)	: ;;
	1)	echo "FAIL: $bhyve_bin is owned by no package -- hand-placed"
		echo "      binaries drift between hosts and vanish on reinstall"
		status=1; _owner= ;;
	*)	echo "FAIL: could not ask pkg who owns $bhyve_bin" \
		    "(detail on stderr)"
		status=1; _owner= ;;
	esac

	# The kernel package names the release everything else must match.
	# Absent is a failure, not silence: this harness ships inside the
	# release package, so a host running it whose kernel came from no
	# package has not got the thing the release delivers.
	if [ -n "$_owner" ] && [ -n "$_kpkg" ]; then
		if [ "$_owner" = "CloudBSD-bhyve-$_kpkg" ]; then
			_bhyve_ok=yes
		else
			echo "FAIL: $bhyve_bin is from $_owner, not"
			echo "      CloudBSD-bhyve-$_kpkg"
			status=1
		fi
	fi
fi

# Ownership is by PATH, not by content: pkg answers from the database, so a
# binary copied over the packaged path is still "owned". The PASS is withheld
# until this has run -- printing it first put a PASS line directly above a FAIL
# about the same file, and any tally of PASS lines counted a replaced binary.
if [ "$_bhyve_ok" = yes ]; then
	# What this PASS rests on: pkg check -s compares only files that carry a
	# recorded checksum in the manifest. pkgbase packages do record them, so
	# it holds for CloudBSD-bhyve and CloudBSD-kernel-generic today -- but a
	# manifest built without sums would let a replaced file pass on
	# ownership alone, and nothing here would notice.
	_ckrc=0
	_ckout=$("$_PKG" check -s "$_owner" 2>&1) || _ckrc=$?
	# What this section does NOT cover, stated because it reads as though it
	# did: libvmmapi. bhyve links it and the vmm ioctl plumbing lives there,
	# so a replaced libvmmapi is a replaced bhyve for every purpose here --
	# but lib/libvmmapi/Makefile sets PACKAGE=lib${LIB}, so the library is
	# its OWN package and never appears in `pkg check -s' output for the
	# bhyve package. A branch here that scanned this output for libvmmapi
	# could not fire on any host, while reading like coverage. Asking
	# libvmmapi's own owner is a different question and belongs in its own
	# block; until that exists, this is a gap and is written down as one.
	if _mismatch "$_ckout" "$bhyve_bin"; then
		echo "FAIL: $bhyve_bin has been replaced since $_owner"
		echo "      was installed"
		status=1
	elif [ -n "$(_unexplained "$_ckout")" ]; then
		# Tested BEFORE the rc-0 PASS, not only on the non-zero path:
		# pkg can emit a diagnostic and still exit 0, and gating this
		# on the exit status discarded it and printed PASS.
		echo "FAIL: pkg check reported something about $_owner that is"
		echo "      neither a checksum mismatch nor progress output"
		_unexplained "$_ckout" | head -3 | sed 's/^/      /'
		status=1
	elif _mismatch_unresolved "$_ckout"; then
		# Placed ahead of BOTH PASS branches below. "Not one of my two
		# files" is the claim those branches rest on, and a path that
		# does not resolve cannot be shown to be either one -- so the
		# answer is that it could not be established, not that it was
		# somebody else's file.
		echo "FAIL: pkg check named a mismatched file under $_owner"
		echo "      that does not resolve, so whether it is"
		echo "      $bhyve_bin cannot be established"
		_mismatch_set "$_ckout" | grep '^UNRESOLVED ' | head -3 |
		    sed 's/^/      /'
		status=1
	elif [ "$_ckrc" -eq 0 ]; then
		# No "same release as the kernel" clause here: that is the
		# kernel block's verdict, printed below, and asserting it above
		# put a PASS line directly over the FAIL that contradicts it.
		echo "PASS: $bhyve_bin is the file $_owner installed"
	elif [ -n "$(_unexplained "$_ckout")" ]; then
		echo "FAIL: pkg check reported something about $_owner that is"
		echo "      neither a checksum mismatch nor progress output"
		_unexplained "$_ckout" | head -3 | sed 's/^/      /'
		status=1
	elif printf '%s\n' "$_ckout" | grep -q 'checksum mismatch'; then
		echo "PASS: $bhyve_bin is the file $_owner installed"
		echo "note: $_owner has a checksum mismatch on another of its"
		echo "      files, not on $bhyve_bin"
	else
		echo "FAIL: could not verify $bhyve_bin against its package"
		printf '%s\n' "$_ckout" | head -3 | sed 's/^/      /'
		status=1
	fi

fi

# The kernel's files, asked independently of how bhyve turned out. Under the
# bhyve guard, any bhyve failure skipped this entirely -- a section titled
# "bhyve and the kernel" that checked neither.
if [ -n "$_kpkg" ]; then
	# And whether the KERNEL files are the ones their package installed.
	# The version above comes from the package database, which an
	# installkernel or a hand-copied /boot/kernel leaves untouched -- so
	# "the same release" was true of the database and not of the machine.
	#
	# vmm.ko as well as the kernel: it is the file that actually contains
	# the nested-virt code, it is what `make -C sys/modules/vmm install'
	# and a module-only deploy replace, and a mismatch on it alone matched
	# no branch here at all -- printed nothing, changed no status.
	#
	# Anchored on what BOOTED rather than on /boot/kernel/kernel, because a
	# loader override or a booted kernel.old leaves that file pristine
	# while the verdict is about something else.
	# Through _probe, like the other OID read. This is the sysctl that picks
	# the kernel file under test, so collapsing "sysctl could not run" into
	# "the OID was empty" here is the worst place in the script to do it.
	_bf=
	_bferr=
	if ! _probe "$_SYSCTL" -n kern.bootfile; then
		_bferr="sysctl could not be run"
	elif [ "$_probe_rc" -ne 0 ]; then
		_bferr=$(printf '%s' "$_probe_err" | head -1)
		[ -n "$_bferr" ] || _bferr="sysctl exited $_probe_rc"
	elif [ -z "$_probe_out" ]; then
		_bferr="kern.bootfile is empty"
	else
		_bf=$_probe_out
	fi
	if [ -n "$_bferr" ]; then
		echo "FAIL: cannot read kern.bootfile, so which kernel file to"
		echo "      verify is unknown: $_bferr"
		status=1
	elif ! _bf=$(_canon "$_bf"); then
		echo "FAIL: kern.bootfile names a path that does not resolve"
		echo "      to a file, so the booted kernel cannot be verified"
		status=1
	else
		# The booted kernel must belong to the package before a
		# checksum can say anything about it. `pkg check -s' only
		# reports files in the manifest, so a kernel booted from
		# somewhere else -- /boot/kernel.old/kernel, a loader override
		# -- produces no mismatch line at all and would pass on the
		# absence of a complaint about a file the package never had.
		_ask=0
		_kok=yes
		_bfowner=$(_pkg_ask "who owns $_bf" which -q "$_bf") || _ask=$?
		case $_ask in
		0)	if [ "$_bfowner" != "CloudBSD-kernel-generic-$_kpkg" ]; then
				echo "FAIL: the booted kernel $_bf is from"
				echo "      $_bfowner, not"
				echo "      CloudBSD-kernel-generic-$_kpkg"
				status=1; _kok=no
			fi ;;
		1)	echo "FAIL: the booted kernel $_bf is owned by no package"
			status=1; _kok=no ;;
		*)	echo "FAIL: could not ask pkg who owns $_bf" \
			    "(detail on stderr)"
			status=1; _kok=no ;;
		esac

		# The module beside the kernel that BOOTED, not a fixed path:
		# a kernel booted from another directory takes its vmm.ko from
		# that directory, and checking /boot/kernel/vmm.ko would verify
		# a file the running system is not using.
		# The path the kernel actually loaded, read from kldstat, not
		# the sibling of the boot file. Measured on a build host both
		# ways -- autoloaded at boot and kldload'd by name -- kldstat
		# reports "vmm.ko (/boot/kernel/vmm.ko)" in each case, so the
		# parenthesised path is there to be read. `kldload /usr/obj/.../vmm.ko'
		# or a kern.module_path override leaves the packaged file
		# pristine while the running module is something else, and
		# checking the pristine one would pass.
		# Not loaded, unrunnable kldstat, and a reply that did not
		# carry a path are three different answers. Measured: a module
		# that is not loaded is exit 1 with "kldstat: can't find file
		# vmm" on stderr. Folding all three into an empty variable
		# printed one FAIL naming two of them and no third.
		_vmm=
		if ! _probe "$_KLDSTAT" -v -n vmm; then
			echo "FAIL: could not run kldstat, so the path the"
			echo "      running vmm was loaded from is unknown"
			status=1; _kok=no
		elif [ "$_probe_rc" -ne 0 ]; then
			if printf '%s\n' "$_probe_err" | grep -q "can't find file"; then
				echo "FAIL: vmm is not loaded"
			else
				echo "FAIL: kldstat could not report on vmm, so"
				echo "      the running module is unknown"
				printf '%s\n' "$_probe_err" | head -2 |
				    sed 's/^/      /'
			fi
			status=1; _kok=no
		else
			_vmm=$(printf '%s\n' "$_probe_out" |
			    sed -n 's/.*vmm\.ko (\(.*\))$/\1/p' | head -1)
			if [ -z "$_vmm" ]; then
				echo "FAIL: kldstat reported vmm without the"
				echo "      path it was loaded from"
				status=1; _kok=no
			elif ! _vmm=$(_canon "$_vmm"); then
				echo "FAIL: the module path kldstat reported"
				echo "      does not resolve to a file"
				status=1; _kok=no
				_vmm=
			fi
		fi
		# No fake path. An earlier version substituted /nonexistent so
		# later comparisons had something to hold, and the note below
		# then asserted a mismatch was "not on /nonexistent" -- a
		# sentence about a module path that was never established.
		# Empty means unknown, and every use of it is guarded.
		:
		# The loaded module must BELONG to the package before a
		# checksum can say anything about it. pkg check only reports
		# files in the manifest, so a vmm loaded from an override path
		# -- the very case the comment above describes -- produces no
		# mismatch line, leaves _kckrc 0, and the absence of a
		# complaint about a file the package never had was being read
		# as proof that it matched.
		if [ -n "$_vmm" ]; then
			_ask=0
			_vmmowner=$(_pkg_ask "who owns $_vmm" which -q "$_vmm") ||
			    _ask=$?
			case $_ask in
			0)	if [ "$_vmmowner" != \
				    "CloudBSD-kernel-generic-$_kpkg" ]; then
					echo "FAIL: the loaded $_vmm is from"
					echo "      $_vmmowner, not"
					echo "      CloudBSD-kernel-generic-$_kpkg"
					status=1; _kok=no
				fi ;;
			1)	echo "FAIL: the loaded $_vmm is owned by no package"
				status=1; _kok=no ;;
			*)	echo "FAIL: could not ask pkg who owns $_vmm" \
				    "(detail on stderr)"
				status=1; _kok=no ;;
			esac
		fi

		_kckrc=0
		_kckout=$("$_PKG" check -s CloudBSD-kernel-generic 2>&1) ||
		    _kckrc=$?
		_kbad=
		_mismatch "$_kckout" "$_bf" && _kbad="$_bf"
		if [ -n "$_vmm" ] && _mismatch "$_kckout" "$_vmm"; then
			_kbad="${_kbad:+$_kbad and }$_vmm"
		fi
		if [ -n "$_kbad" ]; then
			case "$_kbad" in
			*" and "*)	_kverb="have" ;;
			*)		_kverb="has" ;;
			esac
			echo "FAIL: $_kbad $_kverb been replaced since"
			echo "      CloudBSD-kernel-generic-$_kpkg was installed,"
			echo "      so that version does not describe this machine"
			status=1; _kok=no
		elif [ -n "$(_unexplained "$_kckout")" ]; then
			# Asked regardless of whether a mismatch line is also
			# present: an unrelated mismatch elsewhere in the
			# package must not hide a real verification failure on
			# the kernel.
			echo "FAIL: could not verify the kernel against"
			echo "      CloudBSD-kernel-generic-$_kpkg"
			_unexplained "$_kckout" | head -3 | sed 's/^/      /'
			status=1; _kok=no
		elif _mismatch_unresolved "$_kckout"; then
			# _kbad above is "neither of my two files was named".
			# A mismatched path that does not resolve cannot be
			# shown to be neither, so the verdict is unknown rather
			# than clean, and _kok must not survive it.
			echo "FAIL: pkg check named a mismatched file under"
			echo "      CloudBSD-kernel-generic that does not"
			echo "      resolve, so whether it is the booted kernel"
			echo "      or the loaded module cannot be established"
			_mismatch_set "$_kckout" | grep '^UNRESOLVED ' |
			    head -3 | sed 's/^/      /'
			status=1; _kok=no
		elif [ "$_kckrc" -ne 0 ]; then
			# Non-zero with nothing unexplained and neither of our
			# two files named. Previously no branch matched at all
			# -- nothing printed and the status untouched, which is
			# the fault this block's own comment attributes to the
			# code it replaced.
			if printf '%s\n' "$_kckout" |
			    grep -q 'checksum mismatch'; then
				echo "note: CloudBSD-kernel-generic has a" \
				    "checksum mismatch on another of its"
				if [ -n "$_vmm" ]; then
					echo "      files, not on $_bf and" \
					    "not on $_vmm"
				else
					# The module path was never
					# established, so the note cannot
					# claim the mismatch is not on it.
					echo "      files, not on $_bf; the" \
					    "loaded module path is unknown"
				fi
			else
				echo "FAIL: pkg check failed on" \
				    "CloudBSD-kernel-generic with no output"
				echo "      this script can attribute"
				status=1; _kok=no
			fi
		fi
		# Gated on every kernel-side check above, not only on the branch
		# last taken: an ownership failure and a missing module path each
		# set status and then fell through to a PASS about the very files
		# they had just failed on.
		if [ "$_kok" = yes ]; then
			echo "PASS: $_bf and $_vmm are the files" \
			    "CloudBSD-kernel-generic-$_kpkg installed"
		fi
	fi
fi

# The kernel's own answer, asked whatever bhyve turned out to be. "No such
# sysctl" and "the sysctl says 0" are different machines with different fixes,
# so they get different messages.
# "sysctl could not run" and "the OID does not exist" are different machines.
# Folding both into "absent" reported a missing binary as a kernel without
# nested support, which is the loudest possible wrong diagnosis.
if [ -z "$_SYSCTL" ]; then
	echo "FAIL: sysctl is not executable from this PATH, so the kernel"
	echo "      could not be asked whether nesting is enabled"
	status=1
	_ne=unasked
else
	# Three outcomes, not two. Measured on a fleet host: a missing OID is
	# exit 1 with "sysctl: unknown oid '<name>'" on stderr, and a readable
	# OID is exit 0. Anything else that exits non-zero -- not executable,
	# a loader error, EPERM -- is a question that was never answered, and
	# must not be reported as a kernel lacking the feature.
	if ! _probe "$_SYSCTL" -n hw.vmm.nested.enable; then
		echo "FAIL: could not run sysctl, so the kernel was not asked"
		echo "      whether nesting is enabled"
		status=1
		_ne=unasked
	elif [ "$_probe_rc" -eq 0 ]; then
		_ne=$_probe_out
	elif printf '%s\n' "$_probe_err" | grep -q 'unknown oid'; then
		_ne=absent
	else
		echo "FAIL: sysctl could not answer for hw.vmm.nested.enable,"
		echo "      so whether nesting is enabled is unknown"
		printf '%s\n' "$_probe_err" | head -2 | sed 's/^/      /'
		status=1
		_ne=unasked
	fi
fi
case "$_ne" in
unasked) : ;;
1)	# A PASS either way -- the kernel has the knob and it holds the
	# value, which is what this line is for. What changes is the
	# attribution, because "as booted" and "as left by this script"
	# are different facts, and claiming the wrong one is the failure
	# this branch was rewritten to avoid.
	if [ "$_ne_boot" = 1 ]; then
		echo "PASS: hw.vmm.nested.enable is 1"
	elif [ "$_ne_set" = yes ] && [ "$_ne_boot" = 0 ]; then
		echo "PASS: hw.vmm.nested.enable is 1 (this run set it;"
		echo "      as booted it read 0)"
	else
		echo "PASS: hw.vmm.nested.enable is 1, but what made it 1"
		echo "      is not established: as booted it read"
		echo "      $_ne_boot, and this run's attempt to set it"
		echo "      succeeded=$_ne_set"
	fi ;;
absent)
	echo "FAIL: hw.vmm.nested.enable does not exist -- this kernel has no"
	echo "      nested-virt support, or vmm is not loaded"
	status=1 ;;
*)	echo "FAIL: hw.vmm.nested.enable is $_ne -- this kernel supports"
	echo "      nesting and it is turned off"
	status=1 ;;
esac

echo "=== nested-off (opt-in) negative ==="
# Nesting must be strictly opt-in, and the opt-in is the sysctl: there is no
# per-VM -N flag any more, as negative/nested_off.sh says in its own header.
# With hw.vmm.nested.enable=0 a guest created afterwards must get no nested
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
