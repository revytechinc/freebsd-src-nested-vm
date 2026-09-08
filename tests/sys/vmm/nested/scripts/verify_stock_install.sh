#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# verify_stock_install.sh -- prove a STOCK FreeBSD can install the published
# packages and come up able to nest.
#
# This is a different claim from the media gate, and neither covers the other.
# The media gate boots images we built, where every package came from the same
# build and nothing else is installed. This exercises the route the front page
# actually tells people to take:
#
#   - the repository as PUBLISHED, fetched over the network, not a local tree
#   - pkg resolving our packages against a base system we did not build, with
#     its own FreeBSD-* packages to replace
#   - the file conflicts that come from replacing rather than supplementing
#   - a reboot onto a kernel installed by package rather than by an installer
#
# Every one of those has failed at least once. A release can pass the media
# gate completely and still be uninstallable by the documented route.
#
# The image is fetched from FreeBSD's own snapshot mirror and checked against
# FreeBSD's own manifest. That check is what makes the word "stock" mean
# anything: an image we built, or one we cannot verify, tests our build
# against our build.
#
# Usage:
#   verify_stock_install.sh [workdir]
#
# Exit 0 only if a stock system, after following the published instructions,
# reboots onto our kernel with nesting available.

set -u

PROGRAM="${0##*/}"
WORKDIR=${1:-$HOME/stock-test}
MIRROR=${MIRROR:-https://download.freebsd.org/snapshots/VM-IMAGES/16.0-CURRENT/amd64/Latest}
INSTALLER_URL=${INSTALLER_URL:-https://nested.cloudbsd.cat/install.sh}
# NOT written as ${PKG_REPO_URL:-...${ABI}/latest}. Inside a :- default the
# first unquoted } closes the expansion, so the brace after ABI ended it early
# and the URL came out as .../pkg/${ABI/latest} -- which pkg dutifully requested
# and the site answered 404. Single quotes keep ${ABI} literal for pkg to
# expand itself.
if [ -z "${PKG_REPO_URL:-}" ]; then
	PKG_REPO_URL='https://nested.cloudbsd.cat/pkg/${ABI}/latest'
fi
BHYVE_PKG_URL=${BHYVE_PKG_URL:-https://nested.cloudbsd.cat/pkg/FreeBSD:16:amd64/latest/CloudBSD-bhyve.pkg}
BRIDGE=${BRIDGE:-ix0bridge}
UEFI=${UEFI:-/usr/local/share/uefi-firmware/BHYVE_UEFI.fd}
VMNAME=stockinst$$
NMDM=/dev/nmdm${VMNAME}
# Installing a kernel package over the network onto a cold guest is not fast.
BOOT_TIMEOUT=${BOOT_TIMEOUT:-600}
# Derived from the boot budget rather than fixed: the machines that needed a
# larger budget to boot need one to shut down too, and a fixed bound would fail
# them for rebooting normally but slowly.
SHUTDOWN_TIMEOUT=${SHUTDOWN_TIMEOUT:-$((BOOT_TIMEOUT / 4))}
INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-1800}
# A prompt, loose enough for the official image's shell.
SHELL_PROMPT=${SHELL_PROMPT:-'[#$] $'}
# The published journey includes getting back out again. Set to "no" to test
# only the install half.
TEST_REVERT=${TEST_REVERT:-yes}

# Which published route to follow. The site prints two, and they are different
# instructions with different failure modes -- the one-command installer, and a
# step-by-step sequence for people who would rather see what is happening.
#
#   installer  fetch -qo - .../install.sh | sh
#   manual     the numbered steps: add the repo, pkg update, install the kernel,
#              pkg add bhyve, set vmm_load, lock bhyve
#
# The manual route is not a paraphrase of the installer. It installs TWO
# packages where the installer installs four in one transaction, and the same
# page elsewhere says naming all four together is what lets pkg resolve the file
# ownership. Whether that matters is a question for a machine, not an argument.
INSTALL_METHOD=${INSTALL_METHOD:-installer}
case "$INSTALL_METHOD" in
installer|manual)	;;
*)			echo "$PROGRAM: unknown INSTALL_METHOD: $INSTALL_METHOD" >&2
			echo "$PROGRAM: expected 'installer' or 'manual'" >&2
			exit 2 ;;
esac

log() { printf '%s: %s\n' "$PROGRAM" "$*"; }
die() { log "FAIL: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "need root"
[ -f "$UEFI" ] || die "no UEFI firmware at $UEFI"
kldload vmm 2>/dev/null || true
kldstat -q -m vmm || die "vmm will not load on this host"
kldstat -q -m nmdm || kldload nmdm 2>/dev/null || die "no nmdm"

mkdir -p "$WORKDIR"
cd "$WORKDIR" || die "cannot use $WORKDIR"

TAP=""
cleanup() {
	[ -n "${READER_PID:-}" ] && kill "$READER_PID" 2>/dev/null || true
	bhyvectl --vm="$VMNAME" --destroy >/dev/null 2>&1 || true
	if [ -n "$TAP" ]; then
		ifconfig "$BRIDGE" deletem "$TAP" 2>/dev/null || true
		ifconfig "$TAP" destroy 2>/dev/null || true
	fi
	[ "${KEEP_RAW:-0}" = 1 ] || rm -f "${RAW:-}"
	return 0
}
trap cleanup EXIT INT TERM

# ---- 1. the stock image, and proof that it is stock ------------------------
log "fetching FreeBSD's own checksum manifest"
fetch -q -o CHECKSUM.SHA256 "$MIRROR/CHECKSUM.SHA256" ||
    die "cannot reach the FreeBSD snapshot mirror"

# Fetch from the DATED snapshot directory, by the exact filename the manifest
# names.
#
# The Latest/ directory also serves each image under a shortened name with the
# date, git hash and build number stripped -- and that shortened file does NOT
# hash to the manifest entry it appears to correspond to. Downloading it and
# checking it against the manifest fails, which looks like a corrupted download
# and is not one. Latest/ also moves, so a run tomorrow would silently test a
# different image. The dated directory is unambiguous and reproducible.
MANIFEST_NAME=$(grep -o 'FreeBSD-16\.0-CURRENT-amd64-zfs-[^)]*\.raw\.xz' CHECKSUM.SHA256 | head -1)
[ -n "$MANIFEST_NAME" ] || die "no ZFS raw image listed in the manifest"
SNAPDATE=$(echo "$MANIFEST_NAME" | sed -n 's/.*-zfs-\([0-9]\{8\}\)-.*/\1/p')
[ -n "$SNAPDATE" ] || die "cannot derive the snapshot date from $MANIFEST_NAME"
SNAPDIR="${MIRROR%/Latest}/$SNAPDATE"
IMG=$MANIFEST_NAME
# ZFS deliberately: the published install takes a boot environment first, and
# bectl needs a ZFS root. A UFS image would fail for a reason that has nothing
# to do with this release.

if [ ! -f "$IMG" ]; then
	log "fetching $IMG (this is large)"
	fetch -q -o "$IMG" "$SNAPDIR/$IMG" || die "cannot fetch $SNAPDIR/$IMG"
fi

WANT=$(sed -n "s/^SHA256 ($MANIFEST_NAME) = //p" CHECKSUM.SHA256)
GOT=$(sha256 -q "$IMG")
[ -n "$WANT" ] || die "manifest has no checksum for $MANIFEST_NAME"
if [ "$WANT" != "$GOT" ]; then
	log "manifest: $WANT"
	log "actual:   $GOT"
	die "the downloaded image is not the one FreeBSD published -- refusing to
call anything tested against it a stock install"
fi
log "stock image verified against FreeBSD's manifest: $MANIFEST_NAME"

RAW="$WORKDIR/stock.$$.raw"
log "decompressing"
xz -dc "$IMG" > "$RAW" || die "cannot decompress $IMG"

# ---- 2. a network, because the whole point is installing from the repo -----
TAP=$(ifconfig tap create) || die "cannot create a tap"
ifconfig "$TAP" up
ifconfig "$BRIDGE" addm "$TAP" || die "cannot add $TAP to $BRIDGE"
log "network: $TAP on $BRIDGE"

# ---- 3. boot it ------------------------------------------------------------
CONSOLE=$WORKDIR/${VMNAME}.console
: > "$CONSOLE"
# One descriptor, held for the run: see verify_media_nested.sh for why a
# separate stty is a race that resets termios and produces a getty loop.
( exec 3< "${NMDM}B" || exit 1
  stty raw -echo clocal <&3 2>/dev/null || true
  cat <&3 ) > "$CONSOLE" 2>/dev/null &
READER_PID=$!

# bhyve EXITS when the guest reboots -- status 0 means "the guest asked for a
# reset", and the supervisor is expected to destroy the VM and start it again.
# It is not a failure and it is not the guest disappearing. Treating that exit
# as "the machine never came back" turned a perfectly good reboot into a
# reported defect in the shipped release, which is why this is a function now
# rather than a single launch.
start_guest() {
	bhyvectl --vm="$VMNAME" --destroy >/dev/null 2>&1 || true
	bhyve -c 2 -m 4G -A -H -P \
		-s 0,hostbridge \
		-s 2,virtio-blk,"$RAW" \
		-s 3,virtio-net,"$TAP" \
		-s 31,lpc \
		-l com1,"${NMDM}A" \
		-l bootrom,"$UEFI" "$VMNAME" >/dev/null 2>&1 &
	BHYVE_PID=$!
}

log "booting the stock image"
start_guest

wait_for() {
	_pat=$1
	_end=$(( $(date +%s) + $2 ))
	while [ "$(date +%s)" -lt "$_end" ]; do
		grep -qE "$_pat" "$CONSOLE" 2>/dev/null && return 0
		kill -0 "$BHYVE_PID" 2>/dev/null || return 1
		sleep 3
	done
	return 1
}
send() { printf '%s\r' "$1" > "${NMDM}B"; }

# The console file accumulates for the whole run, so a bare grep finds text
# from before a reboot and every post-reboot wait returns instantly against the
# FIRST boot's output. Match only what was written after a recorded point.
console_size() { wc -c < "$CONSOLE" 2>/dev/null | tr -d ' '; }
wait_for_new() {
	_off=$1
	_pat=$2
	_end=$(( $(date +%s) + $3 ))
	while [ "$(date +%s)" -lt "$_end" ]; do
		tail -c "+$(( _off + 1 ))" "$CONSOLE" 2>/dev/null |
		    grep -qE "$_pat" && return 0
		kill -0 "$BHYVE_PID" 2>/dev/null || return 1
		sleep 3
	done
	return 1
}

# Run a command in the guest and wait for a marker that only its OUTPUT can
# produce.
#
# Two traps, both of which this harness fell into and both of which produce a
# PASS that means nothing:
#
#  - the getty echoes the command line back onto the same console we grep, so
#    a marker written literally in the command matches its own echo. The guest
#    assembles it from a variable instead; the echo shows ${m}_..., only the
#    output carries the whole word.
#  - the console accumulates, so a marker from an earlier step (or from before
#    a reboot) is still sitting there. Every marker carries a per-step serial,
#    so it cannot match anything written earlier.
STEP=0
guest_step() {
	_cmd=$1
	_secs=$2
	STEP=$((STEP + 1))
	_tok="ST${STEP}X$$"
	send "m=$_tok; $_cmd; echo \${m}_DONE_\$?"
	wait_for "${_tok}_DONE_" "$_secs"
}
# Did the last step report success?
step_ok() { grep -q "ST${STEP}X$$_DONE_0" "$CONSOLE"; }
# Did the last step's output contain something?
step_saw() { grep -q "$1" "$CONSOLE"; }

if ! wait_for "login:" "$BOOT_TIMEOUT"; then
	# Distinguish "the guest did not get there" from "we never saw anything".
	if ! kill -0 "$READER_PID" 2>/dev/null; then
		die "the console reader died -- the console was never captured, so
this says nothing about whether the guest booted"
	fi
	[ "$(console_size)" = 0 ] &&
	    die "nothing was ever captured from the console: check the nmdm pair,
not the guest"
	die "the stock image never reached a login prompt"
fi
log "stock system is up; logging in"
send "root"
# A password prompt is not certain on an official image, so answer it only if
# it appears and do not fail when it does not.
if wait_for "Password:" 15; then
	send ""
fi
wait_for "$SHELL_PROMPT" 90 || die "no shell prompt after login"

# Confirm this really is an unmodified system before crediting the install.
# The exit status carries the answer, so nothing has to be pattern-matched
# against text we also typed.
guest_step "sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 30 ||
    die "the guest did not answer whether it has a nested sysctl"
if step_ok; then
	die "this system reports a nested sysctl BEFORE installing anything -- it
is not stock, and a pass here would mean nothing"
fi
log "confirmed stock: no nested support before the install"

# ---- 3b. the escape route the page tells a reader to set up FIRST ----------
#
# The install page opens by telling the reader to take a boot environment named
# preinstall before touching anything, and closes by telling them that
# "bectl activate preinstall; reboot" is the whole way back. That is the most
# safety-critical instruction on the site: it is read by someone whose machine
# is already not doing what they wanted. Until now nothing tested it. The
# evidence box under it described a different flow -- a one-shot activation
# that reverts by itself -- and said in as many words that no revert command
# was run.
#
# So the BE is taken here, in the published order, and the revert is exercised
# at the end of this run.
if [ "$TEST_REVERT" = yes ]; then
	guest_step "bectl create preinstall" 120 ||
	    die "the guest stopped answering while creating a boot environment"
	if ! step_ok; then
		log "console tail:"; tail -20 "$CONSOLE" | sed 's/^/  /'
		die "'bectl create preinstall' failed on a stock ZFS-root system,
which is the first instruction on the install page"
	fi
	log "took the preinstall boot environment, as the page instructs"
fi

# The guest needs to reach the repository. The official images DHCP by default.
# Check what the URL returns, not merely that it answers. This site is a
# single-page app behind a fallback: a missing or misdeployed installer comes
# back as the index page with status 200, and fetch(1) calls that a success.
# Feeding that to sh produces a spray of syntax errors attributed to the
# installer, which is the wrong thing to go and look at -- the same trap
# already cost a run here when a wrong URL was saved as a release image.
#
# So the probe insists on a shebang and a plausible size before anything is
# executed. The install step below still runs the published command verbatim;
# this only decides whether it is worth running.
guest_step "dhclient vtnet0 >/dev/null 2>&1; fetch -qo /tmp/probe.sh $INSTALLER_URL && head -1 /tmp/probe.sh | grep -q '^#!' && [ \$(wc -c < /tmp/probe.sh) -gt 1000 ]" 240 ||
    die "the guest never answered the fetch of $INSTALLER_URL"
if ! step_ok; then
	log "console tail:"; tail -20 "$CONSOLE" | sed 's/^/  /'
	die "the stock guest did not get a usable installer from $INSTALLER_URL.
Either there is no route to the published site, or what came back is not a
script -- the site answers 200 with its index page for a URL it does not have,
so a reachable URL is not evidence the installer is there"
fi
log "guest reached the published site"

# ---- 4. follow the published instructions, exactly -------------------------
[ "$INSTALL_METHOD" = manual ] || log "running the published one-command installer"
# Run the command the site actually publishes, pipe and all. Fetching to a file
# and running that is a different command: piping leaves the script's stdin
# attached to the pipe rather than a terminal, so anything it ran that read
# stdin would behave differently here than in the form we had been testing.
# Testing a convenient variant of the published instruction tests an
# instruction nobody was given.
#
# The hazard of the pipe is that a failed fetch feeds sh an empty script, which
# exits 0 -- a silent pass. Two things cover it: the reachability probe above
# fails first if the site cannot be reached at all, and the assertions after
# the reboot are mandatory, so an installer that did nothing cannot reach a
# PASS regardless of what the pipeline reported.
if [ "$INSTALL_METHOD" = manual ]; then
	log "following the published step-by-step route instead of the installer"
	# Each step is one published command, run in the published order, and each
	# is checked on its own. Running them as one blob would report "the manual
	# route failed" without saying which instruction a reader would have been
	# standing on when it did.
	manual_step() {
		_what=$1; _cmd=$2; _secs=$3
		guest_step "$_cmd" "$_secs" ||
		    die "the guest stopped answering during: $_what"
		if ! step_ok; then
			log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
			die "the published manual route failed at: $_what
The command was: $_cmd"
		fi
		log "  ok: $_what"
	}

	# The page prints this as a heredoc. A heredoc cannot be sent here: every
	# step goes to the guest as ONE line, so a multi-line command hangs
	# waiting for input that never arrives -- which is what happened, and it
	# reported as "the guest stopped answering" rather than as a harness
	# fault. printf writes the identical file, and the file is what the
	# instruction is actually for, so the content is asserted immediately
	# afterwards rather than assumed.
	manual_step "step 1, add the CloudBSD repository" \
	    "printf 'CloudBSD: {\\n  url: \"%s\",\\n  mirror_type: \"none\",\\n  enabled: yes,\\n  priority: 10\\n}\\n' '$PKG_REPO_URL' > /etc/pkg/CloudBSD.conf" 60
	manual_step "step 1a, the repository file says what the page says" \
	    "grep -q 'url: \"$PKG_REPO_URL\"' /etc/pkg/CloudBSD.conf && grep -q 'enabled: yes' /etc/pkg/CloudBSD.conf" 60
	manual_step "step 2, pkg update" \
	    "env IGNORE_OSVERSION=yes pkg update" 600
	# One transaction, all four, by NAME from the repository configured above.
	#
	# The page printed `pkg add -f <url>/CloudBSD-bhyve.pkg`, and that URL has
	# never existed: the repository stores packages under versioned filenames
	# (CloudBSD-bhyve-16.0.20260908.deepnest12.pkg), so the unversioned address
	# 404s. Publishing the versioned one would only move the problem -- it
	# would be wrong again on the next release.
	#
	# Installing by name lets pkg resolve the version and the dependencies,
	# which is also why all four are named together: the page's own
	# troubleshooting section says that is what allows pkg to settle the file
	# ownership between these packages and the FreeBSD ones they replace. The
	# page said "two packages, nothing else changed"; two is not enough.
	manual_step "step 3, install the nested-virt kernel and bhyve toolset" \
	    "env IGNORE_OSVERSION=yes pkg install -y -f CloudBSD-kernel-generic CloudBSD-bhyve CloudBSD-lib9p CloudBSD-acpi" "$INSTALL_TIMEOUT"
	manual_step "step 4, load vmm at boot" \
	    "echo 'vmm_load=\"YES\"' >> /boot/loader.conf" 60
	manual_step "step 5, lock bhyve against a base upgrade" \
	    "pkg lock -y CloudBSD-bhyve" 60
	log "manual route completed"
else
	guest_step "fetch -qo - $INSTALLER_URL | sh" "$INSTALL_TIMEOUT" || {
		log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
		die "the installer did not finish within ${INSTALL_TIMEOUT}s"
	}
	if ! step_ok; then
		log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
		die "the published installer exited non-zero on a stock system"
	fi
	log "installer completed"
fi

# ---- 5. the reboot is part of the instructions, so it is part of the test --
log "rebooting onto the installed kernel"
# Everything after this must be judged on output written AFTER this point --
# the first boot's login prompt and shell prompt are still in the file.
MARK=$(console_size)
send "reboot"

# Wait for bhyve to exit, which is how a guest reboot presents to us -- and
# READ ITS STATUS, because bhyve says which of several very different things
# happened:
#
#   0  the guest asked for a reset. This is the reboot we told it to do.
#   1  the guest powered off instead.
#   2  the guest halted instead.
#   3+ a triple fault or a crash.
#
# Only 0 means "restart it and carry on". Relaunching regardless would make an
# installed kernel that triple-faults come back on its second boot and report
# the whole run as a success -- hiding exactly the failure this test exists to
# find.
#
# The watchdog bounds the wait without polling for a zombie: kill -0 succeeds
# against a child that has exited and not yet been reaped, so it cannot tell
# "still running" from "finished". wait(1) can.
( sleep "$SHUTDOWN_TIMEOUT"; kill -TERM "$BHYVE_PID" 2>/dev/null ) &
_watch=$!
wait "$BHYVE_PID"
_rc=$?
kill "$_watch" 2>/dev/null

case "$_rc" in
0)
	log "guest reset as asked; starting it again"
	;;
1)
	die "after the install the guest POWERED OFF instead of rebooting"
	;;
2)
	die "after the install the guest HALTED instead of rebooting"
	;;
143|137)
	die "the guest did not shut down within ${SHUTDOWN_TIMEOUT}s of being told to reboot"
	;;
*)
	die "bhyve exited $_rc after the reboot: that is a crash or triple fault,
not a reset, and the installed kernel is the thing that changed"
	;;
esac
start_guest

wait_for_new "$MARK" "login:" "$BOOT_TIMEOUT" ||
    die "the installed system did not reach a login prompt after the reboot"
log "came back up on the installed kernel"
send "root"
if wait_for_new "$MARK" "Password:" 15; then
	send ""
fi
wait_for_new "$MARK" "$SHELL_PROMPT" 120 || die "no shell prompt after the reboot"

# Per-step marker again: unique, so it cannot match the pre-reboot half of the
# file, and assembled in the guest, so it cannot match its own echo.
# Exactly what the install page tells a reader to do after rebooting. If this
# fails the instructions are wrong, whatever the cause turns out to be.
guest_step "sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 60 ||
    die "could not read the nested sysctl after the reboot"
AS_DOCUMENTED=no
step_ok && AS_DOCUMENTED=yes

# If it failed, find out WHICH failure it is before reporting one. The sysctl
# only exists once vmm(4) is loaded, so "nesting is broken" and "the module is
# not loaded" look identical from the outside and have completely different
# fixes.
if [ "$AS_DOCUMENTED" = no ]; then
	log "the documented check found no nested sysctl; loading vmm and retrying"
	guest_step "kldload vmm >/dev/null 2>&1; sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 90 ||
	    die "the guest stopped answering while loading vmm"
	if step_ok; then
		log "FAIL: nesting works, but only after loading vmm by hand."
		log "      The published instructions say to reboot and read"
		log "      hw.vmm.nested.enable, and on a fresh install that sysctl"
		log "      does not exist yet -- nothing arranges for vmm to load."
		log "      The kernel is right; the instructions are incomplete."
		log "console: $CONSOLE"
		exit 1
	fi
	log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
	die "installed and rebooted, and nesting is unavailable even with vmm
loaded by hand -- this is the kernel, not the instructions"
fi

if step_ok; then
	log "a stock FreeBSD installed the published packages and came back with
nesting available"
	if [ "$TEST_REVERT" != yes ]; then
		log "PASS: install verified (revert not requested)"
		log "console: $CONSOLE"
		exit 0
	fi

	# ---- 6. the way back, exactly as published -------------------------
	#
	# Someone running this has already decided the experiment is over. If it
	# does not work they are stranded on a kernel they did not want, which
	# is a worse place to leave a reader than never having offered the
	# route at all.
	log "reverting with the published escape route"
	guest_step "bectl activate preinstall" 120 ||
	    die "the guest stopped answering while activating the preinstall
boot environment"
	if ! step_ok; then
		log "console tail:"; tail -20 "$CONSOLE" | sed 's/^/  /'
		die "'bectl activate preinstall' failed -- the published way back
does not work, and a reader who followed the install instructions has no
one-command route off this kernel"
	fi

	MARK=$(console_size)
	send "reboot"
	( sleep "$SHUTDOWN_TIMEOUT"; kill -TERM "$BHYVE_PID" 2>/dev/null ) &
	_watch=$!
	wait "$BHYVE_PID"
	_rc=$?
	kill "$_watch" 2>/dev/null
	case "$_rc" in
	0)       log "guest reset as asked; starting it again" ;;
	1)       die "after the revert the guest POWERED OFF instead of rebooting" ;;
	2)       die "after the revert the guest HALTED instead of rebooting" ;;
	143|137) die "the guest did not shut down within ${SHUTDOWN_TIMEOUT}s
after being told to reboot into the preinstall boot environment" ;;
	127)     die "lost track of the bhyve process, so the revert cannot be
judged. This is a fault in the harness, not a verdict on the release" ;;
	*)       die "bhyve exited $_rc after the revert reboot: a crash or triple
fault booting the boot environment that is supposed to be the safe one" ;;
	esac
	start_guest

	wait_for_new "$MARK" "login:" "$BOOT_TIMEOUT" ||
	    die "the machine did not reach a login prompt after reverting -- the
published escape route left it unbootable, which is the worst outcome this
page can produce"
	send "root"
	if wait_for_new "$MARK" "Password:" 15; then send ""; fi
	wait_for_new "$MARK" "$SHELL_PROMPT" 120 ||
	    die "no shell prompt after reverting"
	log "came back up after the revert"

	# It has to be the ORIGINAL system, not merely a system. A revert that
	# boots something is not a revert; the reader asked for the machine they
	# had.
	#
	# Name what booted rather than inferring it. Asking bectl which boot
	# environment is active is a direct answer to "did the published command
	# do what it says"; the sysctl check below is a second, independent
	# opinion. On its own the sysctl would be weak evidence -- it exists only
	# while vmm(4) is loaded, so its absence is also what an unloaded module
	# looks like, and a revert that did nothing would read the same as one
	# that worked. Two checks that fail for different reasons are worth more
	# than one that can be satisfied by accident.
	guest_step "bectl list | grep -qE '^preinstall[[:space:]]+NR'" 60 ||
	    die "the reverted guest stopped answering when asked which boot
environment it is running"
	if ! step_ok; then
		log "console tail:"; tail -20 "$CONSOLE" | sed 's/^/  /'
		die "after 'bectl activate preinstall' and a reboot, preinstall is
not the active boot environment. The machine booted, but not into the system
the reader asked for"
	fi
	log "confirmed: running the preinstall boot environment"

	# Stock FreeBSD has no nested sysctl, which is exactly the check used
	# before the install -- so the same probe that proved it was stock then
	# proves it is stock again now.
	guest_step "sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 60 ||
	    die "the reverted guest stopped answering"
	if step_ok; then
		log "console tail:"; tail -20 "$CONSOLE" | sed 's/^/  /'
		die "after reverting, the machine still reports a nested sysctl.
It booted something, but not the system the reader started with"
	fi
	log "confirmed: back on the original system, with no nested support"

	log "PASS: the published route works in both directions -- a stock
FreeBSD installed the packages and came up nesting, and the published escape
route put the original system back"
	log "console: $CONSOLE"
	exit 0
fi

log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
die "installed and rebooted, but nesting is not available -- the documented
route does not produce a working nested host"
