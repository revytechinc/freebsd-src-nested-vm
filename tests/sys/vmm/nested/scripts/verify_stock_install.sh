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
# The site publishes three routes in, and they are different instructions with
# different failure modes rather than three phrasings of one. All three are
# tested; INSTALL_METHOD below picks which. The boot-environment route also
# makes a promise the other two do not -- that a kernel which fails to come up
# reverts by itself, with nobody at the console -- and that promise is tested
# as directly as the install, by rebooting a second time without confirming and
# requiring the machine to come back on the system it started with.
#
# Usage:
#   verify_stock_install.sh [workdir]
#   INSTALL_METHOD=installer|manual|be verify_stock_install.sh [workdir]
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
# The signing fingerprint, and where pkg looks for it. The published route
# takes this BEFORE it configures anything, so this gate does too -- a gate
# that installs by a simpler route than the page prints is not testing the
# page.
FINGERPRINT_URL=${FINGERPRINT_URL:-https://nested.cloudbsd.cat/cloudbsd-fingerprint}
FINGERPRINT_DIR=${FINGERPRINT_DIR:-/usr/share/keys/pkg/fingerprints/CloudBSD}
# Optional, and the only thing that makes the fingerprint check mean anything.
#
# Fetching a key from the same origin as the packages and then verifying the
# packages against it establishes self-consistency and nothing else -- whoever
# controls that host supplies both halves. That is what the published route
# does and this gate tests the published route, so it is not a defect to fix
# here. But a gate runs on our own infrastructure and CAN hold an anchor the
# reader has no way to hold: set EXPECT_FINGERPRINT to the sha256 of the
# signing key's public half and the fetched file is checked against it.
# Unset, the gate confirms the file's SHAPE and says so rather than implying
# more.
EXPECT_FINGERPRINT=${EXPECT_FINGERPRINT:-}
# Refused rather than used if it is not a digest. An anchor that cannot match
# anything is worse than no anchor: the step passes or fails for a reason that
# has nothing to do with the key.
if [ -n "$EXPECT_FINGERPRINT" ]; then
	case "$EXPECT_FINGERPRINT" in
	*[!0-9a-f]*|"")
		echo "$PROGRAM: EXPECT_FINGERPRINT is not a hex digest" >&2; exit 2 ;;
	esac
	case "${#EXPECT_FINGERPRINT}" in
	64)	;;
	*)	echo "$PROGRAM: EXPECT_FINGERPRINT is ${#EXPECT_FINGERPRINT} characters, not 64" >&2; exit 2 ;;
	esac
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

# Which published route to follow. The site prints three, and they are
# different instructions with different failure modes.
#
#   installer  fetch -qo - .../install.sh | sh
#   manual     the numbered steps: add the repo, pkg update, install the four
#              packages, set vmm_load, lock bhyve
#   be         install into a second boot environment with pkg -r and activate
#              it for ONE boot -- the route the page recommends for a machine
#              whose console you cannot reach
#
# None of the three is a paraphrase of another. The manual route installs by a
# different mechanism than the installer script; the boot-environment route
# installs into a filesystem that is not running, and is the only one that
# makes a promise about what happens when the new kernel does NOT come up.
# Whether any of that holds is a question for a machine, not an argument.
INSTALL_METHOD=${INSTALL_METHOD:-installer}
case "$INSTALL_METHOD" in
installer|manual|be)	;;
*)			echo "$PROGRAM: unknown INSTALL_METHOD: $INSTALL_METHOD" >&2
			echo "$PROGRAM: expected 'installer', 'manual' or 'be'" >&2
			exit 2 ;;
esac

# How long a published command may leave the console completely silent before
# the harness looks at what it is sitting ON.
#
# Silence is ambiguous. A guest that died and a command waiting for an answer
# nobody will type produce exactly the same nothing, and reporting the second
# as the first sends the reader to look at the guest instead of at the
# instruction. Two of the faults already found on this page were published
# commands that stop on a y/N prompt.
STALL_SECS=${STALL_SECS:-180}

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

# Is the guest sitting on a yes/no question right now?
#
# Only the very end of the console counts. pkg prints the same question when it
# is going to answer it itself, and then keeps going, so a prompt that is not
# the last thing written is not a prompt anybody is waiting at.
console_ends_in_question() {
	tail -c 200 "$CONSOLE" 2>/dev/null | tr -d '\r' |
	    grep -qE '\[[yY]/[nN]\]:?[[:space:]]*$'
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
#
# Returns 0 if the step reported back, 1 if the guest went silent or died, and
# 2 if it went silent while a question was still on the screen. The third is
# worth its own status because the fix for it is in the instruction, not in the
# guest, and folding it into "the guest stopped answering" sends the reader to
# look at the wrong thing.
STEP=0
guest_step() {
	_cmd=$1
	_secs=$2
	STEP=$((STEP + 1))
	_tok="ST${STEP}X$$"
	send "m=$_tok; $_cmd; echo \${m}_DONE_\$?"
	_end=$(( $(date +%s) + _secs ))
	_seen=$(console_size)
	_quiet=$(date +%s)
	while [ "$(date +%s)" -lt "$_end" ]; do
		grep -q "${_tok}_DONE_" "$CONSOLE" 2>/dev/null && return 0
		kill -0 "$BHYVE_PID" 2>/dev/null || return 1
		_now=$(console_size)
		if [ "$_now" != "$_seen" ]; then
			_seen=$_now
			_quiet=$(date +%s)
		elif [ $(( $(date +%s) - _quiet )) -ge "$STALL_SECS" ] &&
		    console_ends_in_question; then
			# Nothing has moved for a long time and the last thing on
			# the console is a question. This is only the early exit:
			# it saves the rest of a long budget, and cannot be the
			# only check, because a step whose own timeout is shorter
			# than STALL_SECS would leave the loop before ever
			# reaching it and report a prompt as a dead guest.
			return 2
		fi
		sleep 3
	done
	# Out of time. Say WHY before giving up: a question still on the screen
	# is a different finding from a guest that stopped talking, whatever the
	# step's budget happened to be.
	console_ends_in_question && return 2
	return 1
}
# Did the last step report success?
step_ok() { grep -q "ST${STEP}X$$_DONE_0" "$CONSOLE"; }
# Did the last step's output contain something?
step_saw() { grep -q "$1" "$CONSOLE"; }

# Run a command in the guest and insist that it REPORTED BACK, without caring
# what it reported. Its result is left for the caller to read with step_ok.
#
# Every step goes through here rather than testing guest_step's status inline,
# because there are three outcomes and only one of them is "the guest stopped
# answering". Folding the question case back into silence is the exact
# misattribution the third status exists to prevent, and an inline
# `|| die "stopped answering"` does precisely that.
guest_probe() {
	_what=$1
	_cmd=$2
	_secs=$3
	guest_step "$_cmd" "$_secs"
	_st=$?
	[ "$_st" -eq 0 ] && return 0
	log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
	if [ "$_st" -eq 2 ]; then
		die "stopped on a question at: $_what
The command was: $_cmd
Nothing answers that prompt. A reader at a keyboard can type through it; a
reader who pastes the block, or anything automated, waits there forever."
	fi
	die "the guest stopped answering during: $_what
The command was: $_cmd"
}

# Run ONE published command as its own checked step, and require it to succeed.
#
# Every published instruction is checked separately so that a failure names the
# instruction a reader would have been standing on when it failed. Running a
# route as one blob reports that "the route" did not work, which is not a thing
# anybody can go and fix.
pub_step() {
	_pwhat=$1
	guest_probe "$@"
	if ! step_ok; then
		log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
		die "the published route failed at: $_pwhat
The command was: $2"
	fi
	log "  ok: $_pwhat"
}

# Reboot the guest, judge how it went down, and log back in.
#
# bhyve EXITS when the guest reboots -- status 0 means "the guest asked for a
# reset", and the supervisor is expected to destroy the VM and start it again.
# It is not a failure and it is not the guest disappearing. Treating that exit
# as "the machine never came back" turned a perfectly good reboot into a
# reported defect in the shipped release, which is why this is a function.
#
# The other statuses are different events and must not be folded into it:
#
#   0  the guest asked for a reset. This is the reboot we told it to do.
#   1  the guest powered off instead.
#   2  the guest halted instead.
#   3+ a triple fault or a crash.
#
# Relaunching regardless would make an installed kernel that triple-faults come
# back on its second boot and report the whole run as a success -- hiding
# exactly the failure this test exists to find.
#
# The watchdog bounds the wait without polling for a zombie: kill -0 succeeds
# against a child that has exited and not yet been reaped, so it cannot tell
# "still running" from "finished". wait(1) can.
#
# MARK is left at where the console stood when the reboot was asked for, so
# everything checked afterwards reads only what THIS boot wrote. The console
# file accumulates for the whole run; without that, a post-reboot grep matches
# the previous boot's output and returns instantly.
reboot_guest() {
	_why=$1
	MARK=$(console_size)
	send "reboot"
	( sleep "$SHUTDOWN_TIMEOUT"; kill -TERM "$BHYVE_PID" 2>/dev/null ) &
	_watch=$!
	wait "$BHYVE_PID"
	_rc=$?
	kill "$_watch" 2>/dev/null
	case "$_rc" in
	0)	log "guest reset as asked; starting it again" ;;
	1)	die "$_why: the guest POWERED OFF instead of rebooting" ;;
	2)	die "$_why: the guest HALTED instead of rebooting" ;;
	143|137)
		die "$_why: the guest did not shut down within
${SHUTDOWN_TIMEOUT}s of being told to reboot" ;;
	127)	die "$_why: lost track of the bhyve process, so this reboot cannot
be judged. That is a fault in the harness, not a verdict on the release" ;;
	*)	die "$_why: bhyve exited $_rc, which is a crash or a triple fault
rather than a reset" ;;
	esac
	start_guest

	wait_for_new "$MARK" "login:" "$BOOT_TIMEOUT" ||
	    die "$_why: the machine did not reach a login prompt"
	send "root"
	if wait_for_new "$MARK" "Password:" 15; then
		send ""
	fi
	wait_for_new "$MARK" "$SHELL_PROMPT" 120 ||
	    die "$_why: no shell prompt after the reboot"
}

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
guest_probe "asking a stock system whether it already has a nested sysctl" \
    "sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 30
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
#
# The boot-environment route is excluded because it does not have this problem:
# it never touches the running system, so the system it would revert TO is the
# one it is already running. Taking a preinstall copy there would test a
# sentence the page does not print in that section.
if [ "$TEST_REVERT" = yes ] && [ "$INSTALL_METHOD" != be ]; then
	guest_probe "bectl create preinstall" "bectl create preinstall" 120
	if ! step_ok; then
		log "console tail:"; tail -20 "$CONSOLE" | sed 's/^/  /'
		die "'bectl create preinstall' failed on a stock ZFS-root system,
which is the first instruction on the install page"
	fi
	log "took the preinstall boot environment, as the page instructs"
fi

# The official images DHCP on boot, but every route below needs the network and
# nothing so far has depended on it, so it is brought up explicitly. This step
# is not what judges the network: it reports success whether or not a lease
# arrived, and the first published command that needs the repository is the one
# that says so.
guest_probe "bringing the guest's network up" \
    "dhclient vtnet0 >/dev/null 2>&1; true" 240

# Only the installer route fetches install.sh, so only it is probed for it. The
# other two reach the package repository instead, and their own first published
# step is what reports on that.
#
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
if [ "$INSTALL_METHOD" = installer ]; then
	guest_probe "fetching $INSTALLER_URL, to see what the site answers with" \
	    "fetch -qo /tmp/probe.sh $INSTALLER_URL && head -1 /tmp/probe.sh | grep -q '^#!' && [ \$(wc -c < /tmp/probe.sh) -gt 1000 ]" 240
	if ! step_ok; then
		log "console tail:"; tail -20 "$CONSOLE" | sed 's/^/  /'
		die "the stock guest did not get a usable installer from $INSTALLER_URL.
Either there is no route to the published site, or what came back is not a
script -- the site answers 200 with its index page for a URL it does not have,
so a reachable URL is not evidence the installer is there"
	fi
	log "guest reached the published site"
fi

# ---- 4a. the boot-environment route, and the promise it makes -------------
#
# The page recommends this one for a machine whose console you cannot reach.
# The install goes into a boot environment that is not running, that boot
# environment is activated for ONE boot, and the page's claim is that if the new
# kernel does not come up you do nothing at all: the machine returns to the
# system you started with, by itself, with nobody at the console.
#
# That promise is the entire reason the route is offered, so it is tested as
# directly as the install itself. After the one-shot boot the guest is rebooted
# again WITHOUT the confirming command, and it has to come back on the original
# system. A gate that walked only the happy path would pass a page whose safety
# net does not exist -- on the one route recommended to people who cannot go
# and look at the machine.
#
# Which boot environment is running is read out of bectl every time, never
# inferred from a missing sysctl. The nested sysctls exist only while vmm(4) is
# loaded, so their absence is also what an unloaded module looks like, and a
# machine that never reverted at all would read exactly like one that did.
#
# bectl list -H is used rather than the human listing: it is tab separated with
# one line per boot environment, so the flags are a field to match rather than a
# column to count. The original boot environment is matched by NOT being
# "nested" instead of by name, because the page's sample listing calls it
# "default" and the name is the installer's choice, not the route's.
if [ "$INSTALL_METHOD" = be ]; then
	log "following the published boot-environment route"

	# The repository goes on the host FIRST, and the order is not
	# decoration: bectl create copies the running system, so a repository
	# added afterwards would not be inside the boot environment that pkg -r
	# is about to install into.
	pub_step "step 1, take the signing fingerprint" \
	    "mkdir -p '$FINGERPRINT_DIR/trusted' && fetch -o '$FINGERPRINT_DIR/trusted/CloudBSD' '$FINGERPRINT_URL' && grep -q '^fingerprint:' '$FINGERPRINT_DIR/trusted/CloudBSD'" 120
	# Identity, not just shape -- when an anchor was supplied.
	if [ -n "$EXPECT_FINGERPRINT" ]; then
		# Extracted and compared as a STRING. Interpolating it into a
		# grep pattern makes it a regular expression, where a `.' is any
		# character -- so a value one digit off could still match, which
		# is the opposite of what an anchor is for.
		pub_step "step 1a, the fingerprint is the one we expect" \
		    "test \"\$(sed -n 's/^fingerprint: *\"\\(.*\\)\"/\\1/p' '$FINGERPRINT_DIR/trusted/CloudBSD')\" = '$EXPECT_FINGERPRINT'" 60
	fi
	pub_step "step 2, add the CloudBSD repository" \
	    "printf 'CloudBSD: {\\n  url: \"%s\",\\n  mirror_type: \"none\",\\n  signature_type: \"fingerprints\",\\n  fingerprints: \"%s\",\\n  enabled: yes,\\n  priority: 10\\n}\\n' '$PKG_REPO_URL' '$FINGERPRINT_DIR' > /etc/pkg/CloudBSD.conf" 60
	pub_step "step 2a, the repository file says what the page says" \
	    "grep -q 'url: \"$PKG_REPO_URL\"' /etc/pkg/CloudBSD.conf && grep -q 'enabled: yes' /etc/pkg/CloudBSD.conf && grep -q 'signature_type: \"fingerprints\"' /etc/pkg/CloudBSD.conf" 60
	pub_step "step 2b, pkg update" \
	    "env IGNORE_OSVERSION=yes pkg update" 600
	# A REJECTED SIGNATURE IS SILENT. pkg prints "No trusted public keys
	# found", reports the repository up to date, and exits 0 -- measured.
	# So the exit status of the step above establishes nothing about
	# verification, and without this the gate certifies an install that
	# verified nothing, which is exactly what two fleet hosts turned out to
	# be doing.
	#
	# The count works HERE because this is a stock machine with an empty
	# package database: a refused catalogue leaves nothing behind. On a host
	# that already holds a good catalogue the previous one survives the
	# refusal and the count stays high, so this is not a check to lift
	# somewhere else unmodified.
	pub_step "step 3, the repository actually offers packages" \
	    "test \$(pkg rquery -r CloudBSD %n 2>/dev/null | wc -l) -gt 100" 300

	pub_step "bectl create nested" "bectl create nested" 180
	pub_step "bectl mount nested /mnt" "bectl mount nested /mnt" 180
	# The page prints this one with a note that a reader coming from a stock
	# FreeBSD can skip it, because there is no lock yet -- and this guest is
	# exactly that reader. So its result is recorded rather than required:
	# failing the route here would be reporting a defect in an instruction
	# the page told this reader not to run. What is worth knowing is what
	# happens to somebody who runs it anyway, which is most people.
	# pkg -r has to be reading the boot environment's own package database
	# for any of the rest to mean what the page says it means. The boot
	# environment was cloned moments ago, so the two databases have to agree
	# right now; if they do not, pkg is writing records into a copy that the
	# booted system will not be reading. Recorded rather than required,
	# because the files still land in the right place either way, and what
	# boots is decided by the files.
	# Compared as SETS, not as counts. Two databases holding the same number
	# of packages are not the same database, and one package added against
	# one removed is exactly the shape of the mistake this is looking for.
	#
	# pkg query rather than pkg info, because info prints a description
	# column whose padding is a property of the listing rather than of the
	# database. Comparing that would report a difference that is not one.
	guest_probe "comparing the boot environment's package database with the live one" \
	    "pkg -r /mnt query -a %n-%v | sort > /tmp/be.pkgs && pkg query -a %n-%v | sort > /tmp/live.pkgs && cmp -s /tmp/be.pkgs /tmp/live.pkgs" 180
	if step_ok; then
		log "  the boot environment's package database is the one pkg -r reads"
	else
		log "  note: pkg -r /mnt and the live system do not list the same
installed packages, moments after one was cloned from the other, so the boot
environment's records are not the ones being updated. The files still land in
the boot environment; its bookkeeping does not follow them."
	fi

	guest_probe "unlock bhyve inside the boot environment" \
	    "pkg -r /mnt unlock -y CloudBSD-bhyve" 180
	# The trust material has to be INSIDE the boot environment, not merely
	# on the host that made it. bectl create copies the running root, so a
	# fingerprint written before that copy is carried in -- which is the
	# ordering above. Asserted rather than relied on, because if it is ever
	# missing `pkg -r' installs from an unverified repository and says
	# nothing: the failure this whole route is here to detect, one level
	# down and invisible.
	pub_step "step 4a, the fingerprint is inside the boot environment" \
	    "test -s /mnt${FINGERPRINT_DIR}/trusted/CloudBSD" 60
	if step_ok; then
		log "  ok: unlock bhyve inside the boot environment (harmless on a
stock host, so the page's 'skip it' is optional rather than required)"
	else
		log "  note: 'pkg -r /mnt unlock -y CloudBSD-bhyve' returns non-zero
on a stock host, where the package is not installed. The page already tells
that reader to skip it; this records that the note is load-bearing rather than
tidy, and the route continues."
	fi
	# The page printed this without -y, unlike the same install in the
	# step-by-step route above it and unlike the pkg unlock beside it, and it
	# was run here exactly as printed. pkg stopped on
	#
	#   Proceed with this action? [y/N]:
	#
	# and stayed there. A reader at a keyboard types y and never notices; a
	# reader who pastes the block, and anything automated, waits forever. The
	# page now prints -y, and this is that command.
	pub_step "install the four packages into the boot environment" \
	    "env IGNORE_OSVERSION=yes pkg -r /mnt install -y -f CloudBSD-kernel-generic CloudBSD-bhyve CloudBSD-lib9p CloudBSD-acpi" "$INSTALL_TIMEOUT"
	# The page says "-r targets it; the running system is not modified by
	# this command". Checked rather than taken on trust: if that were wrong
	# the reader would already be on the new kernel before ever choosing to
	# boot it, and the one-shot activation would be protecting nothing.
	pub_step "the install landed in the boot environment and left the running system alone" \
	    "pkg -r /mnt info -e CloudBSD-kernel-generic && ! pkg info -e CloudBSD-kernel-generic" 180
	# Package records are one kind of evidence; the kernel on disk is another,
	# and it is the one that decides what boots. These two files were
	# identical when the boot environment was created, so they must not be
	# identical now.
	pub_step "the boot environment holds a different kernel from the one running" \
	    "! cmp -s /mnt/boot/kernel/kernel /boot/kernel/kernel" 180
	pub_step "bectl umount nested" "bectl umount nested" 180
	pub_step "bectl activate -t nested" "bectl activate -t nested" 60
	# The page prints this listing and annotates both flags. Together they
	# are the safety claim in one line: T is one boot only, and the original
	# keeps the R that the machine goes back to.
	pub_step "bectl list shows nested T, and the original still holds the R" \
	    "bectl list -H | grep -qE '^nested[[:space:]]+T[[:space:]]' && bectl list -H | grep -vE '^nested[[:space:]]' | grep -qE '^[^[:space:]]+[[:space:]]+NR[[:space:]]'" 60

	log "rebooting into the boot environment, for one boot"
	reboot_guest "the one-shot boot"

	# Both halves matter here. Running the new system is the happy path;
	# the original still holding the R is what makes the next reboot safe.
	# If nested had taken the R, the reader would already be committed to a
	# kernel they have not decided to keep.
	pub_step "the one-shot boot runs nested, and the original is still the fallback" \
	    "bectl list -H | grep -qE '^nested[[:space:]]+N[[:space:]]' && bectl list -H | grep -vE '^nested[[:space:]]' | grep -qE '^[^[:space:]]+[[:space:]]+R[[:space:]]'" 60

	# Nothing in this route writes vmm_load, and the page does not ask it
	# to: it prints "kldstat -q -m vmm || kldload vmm" in the block a reader
	# lands on after this reboot. Both answers are recorded, because "it
	# needed loading" and "it is not there at all" are different findings
	# and only one of them is a defect.
	guest_probe "asking whether vmm is loaded on the one-shot boot" \
	    "sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 60
	if step_ok; then
		log "  vmm was already loaded on this boot"
	else
		log "  vmm is not loaded yet, which is what the page's"
		log "  'kldstat -q -m vmm || kldload vmm' line is for"
	fi
	pub_step "after the one-shot boot, nesting is available as the page says" \
	    "{ kldstat -q -m vmm || kldload vmm; } >/dev/null 2>&1; sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 120
	log "the one-shot boot came up on the nested-virt kernel"

	# ---- the promise --------------------------------------------------
	#
	# Now do nothing, which is exactly what the page tells a reader whose
	# machine did not come up: no confirming command, just another boot.
	# This is the only thing on the install page that promises something
	# about a machine nobody is standing at.
	log "rebooting WITHOUT confirming -- the case the page makes a promise about"
	reboot_guest "the unconfirmed second boot"

	pub_step "an unconfirmed reboot came back on the ORIGINAL boot environment" \
	    "bectl list -H | grep -vE '^nested[[:space:]]' | grep -qE '^[^[:space:]]+[[:space:]]+NR[[:space:]]' && ! bectl list -H | grep -qE '^nested[[:space:]]+N'" 60
	# A second opinion from a different mechanism. On its own this would be
	# weak -- the sysctl is absent whenever vmm is unloaded, so it cannot
	# tell a revert from a module that simply was not loaded -- but next to
	# the bectl check it is something that fails for a different reason.
	guest_probe "asking the reverted system for a nested sysctl" \
	    "sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 60
	if step_ok; then
		log "console tail:"; tail -20 "$CONSOLE" | sed 's/^/  /'
		die "after an unconfirmed reboot the machine still reports a
nested sysctl, so it is still running the new kernel whatever bectl says"
	fi
	log "the one-shot activation reverted by itself, with nobody at the console"

	# ---- and the other half: keeping it -------------------------------
	#
	# Back on the original system, take the route again and this time say
	# yes. "bectl activate nested" has to survive a reboot to mean anything,
	# so it is checked before one and again after it.
	pub_step "bectl activate -t nested, a second time" \
	    "bectl activate -t nested" 60
	log "rebooting into the boot environment again, to keep it this time"
	reboot_guest "the second one-shot boot"

	# Check where we landed BEFORE confirming anything. Running "bectl
	# activate nested" from the original system would also leave nested
	# holding an R, and every check after it would pass while the machine had
	# never actually booted the thing being kept.
	pub_step "the second one-shot boot is running nested" \
	    "bectl list -H | grep -qE '^nested[[:space:]]+N[[:space:]]'" 60
	pub_step "bectl activate nested makes it permanent" \
	    "bectl activate nested" 60
	pub_step "bectl list now shows nested as both N and R" \
	    "bectl list -H | grep -qE '^nested[[:space:]]+NR[[:space:]]'" 60
	log "rebooting once more, to see whether the choice survives a boot"
	reboot_guest "after making the boot environment permanent"

	pub_step "the confirmed boot environment is still what the machine runs" \
	    "bectl list -H | grep -qE '^nested[[:space:]]+NR[[:space:]]'" 60
	pub_step "and nesting is available on it" \
	    "{ kldstat -q -m vmm || kldload vmm; } >/dev/null 2>&1; sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 120

	log "PASS: the published boot-environment route works in both
directions -- the install went into a boot environment that was not running and
left the live system alone, one boot came up on it with nesting available, an
unconfirmed reboot returned the machine to the original system by itself, and
'bectl activate nested' made the new one permanent across a reboot"
	log "console: $CONSOLE"
	exit 0
fi

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
	# The page prints this as a heredoc. A heredoc cannot be sent here: every
	# step goes to the guest as ONE line, so a multi-line command hangs
	# waiting for input that never arrives -- which is what happened, and it
	# reported as "the guest stopped answering" rather than as a harness
	# fault. printf writes the identical file, and the file is what the
	# instruction is actually for, so the content is asserted immediately
	# afterwards rather than assumed.
	pub_step "step 1, take the signing fingerprint" \
	    "mkdir -p '$FINGERPRINT_DIR/trusted' && fetch -o '$FINGERPRINT_DIR/trusted/CloudBSD' '$FINGERPRINT_URL' && grep -q '^fingerprint:' '$FINGERPRINT_DIR/trusted/CloudBSD'" 120
	# Identity, not just shape -- when an anchor was supplied.
	if [ -n "$EXPECT_FINGERPRINT" ]; then
		# Extracted and compared as a STRING. Interpolating it into a
		# grep pattern makes it a regular expression, where a `.' is any
		# character -- so a value one digit off could still match, which
		# is the opposite of what an anchor is for.
		pub_step "step 1a, the fingerprint is the one we expect" \
		    "test \"\$(sed -n 's/^fingerprint: *\"\\(.*\\)\"/\\1/p' '$FINGERPRINT_DIR/trusted/CloudBSD')\" = '$EXPECT_FINGERPRINT'" 60
	fi
	pub_step "step 2, add the CloudBSD repository" \
	    "printf 'CloudBSD: {\\n  url: \"%s\",\\n  mirror_type: \"none\",\\n  signature_type: \"fingerprints\",\\n  fingerprints: \"%s\",\\n  enabled: yes,\\n  priority: 10\\n}\\n' '$PKG_REPO_URL' '$FINGERPRINT_DIR' > /etc/pkg/CloudBSD.conf" 60
	pub_step "step 2a, the repository file says what the page says" \
	    "grep -q 'url: \"$PKG_REPO_URL\"' /etc/pkg/CloudBSD.conf && grep -q 'enabled: yes' /etc/pkg/CloudBSD.conf && grep -q 'signature_type: \"fingerprints\"' /etc/pkg/CloudBSD.conf" 60
	pub_step "step 2b, pkg update" \
	    "env IGNORE_OSVERSION=yes pkg update" 600
	# A REJECTED SIGNATURE IS SILENT. pkg prints "No trusted public keys
	# found", reports the repository up to date, and exits 0 -- measured.
	# So the exit status of the step above establishes nothing about
	# verification, and without this the gate certifies an install that
	# verified nothing, which is exactly what two fleet hosts turned out to
	# be doing.
	#
	# The count works HERE because this is a stock machine with an empty
	# package database: a refused catalogue leaves nothing behind. On a host
	# that already holds a good catalogue the previous one survives the
	# refusal and the count stays high, so this is not a check to lift
	# somewhere else unmodified.
	pub_step "step 3, the repository actually offers packages" \
	    "test \$(pkg rquery -r CloudBSD %n 2>/dev/null | wc -l) -gt 100" 300
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
	pub_step "step 4, install the nested-virt kernel and bhyve toolset" \
	    "env IGNORE_OSVERSION=yes pkg install -y -f CloudBSD-kernel-generic CloudBSD-bhyve CloudBSD-lib9p CloudBSD-acpi" "$INSTALL_TIMEOUT"
	pub_step "step 6, load vmm at boot" \
	    "echo 'vmm_load=\"YES\"' >> /boot/loader.conf" 60
	pub_step "step 5, lock bhyve against a base upgrade" \
	    "pkg lock -y CloudBSD-bhyve" 60
	log "manual route completed"
else
	guest_probe "the published one-command installer" \
	    "fetch -qo - $INSTALLER_URL | sh" "$INSTALL_TIMEOUT"
	if ! step_ok; then
		log "console tail:"; tail -30 "$CONSOLE" | sed 's/^/  /'
		die "the published installer exited non-zero on a stock system"
	fi
	log "installer completed"
fi

# ---- 5. the reboot is part of the instructions, so it is part of the test --
log "rebooting onto the installed kernel"
reboot_guest "after the install"
log "came back up on the installed kernel"

# Per-step marker again: unique, so it cannot match the pre-reboot half of the
# file, and assembled in the guest, so it cannot match its own echo.
# Exactly what the install page tells a reader to do after rebooting. If this
# fails the instructions are wrong, whatever the cause turns out to be.
guest_probe "reading the nested sysctl after the reboot, as the page says" \
    "sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 60
AS_DOCUMENTED=no
step_ok && AS_DOCUMENTED=yes

# If it failed, find out WHICH failure it is before reporting one. The sysctl
# only exists once vmm(4) is loaded, so "nesting is broken" and "the module is
# not loaded" look identical from the outside and have completely different
# fixes.
if [ "$AS_DOCUMENTED" = no ]; then
	log "the documented check found no nested sysctl; loading vmm and retrying"
	guest_probe "loading vmm by hand and reading the sysctl again" \
	    "kldload vmm >/dev/null 2>&1; sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 90
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
	guest_probe "bectl activate preinstall" "bectl activate preinstall" 120
	if ! step_ok; then
		log "console tail:"; tail -20 "$CONSOLE" | sed 's/^/  /'
		die "'bectl activate preinstall' failed -- the published way back
does not work, and a reader who followed the install instructions has no
one-command route off this kernel"
	fi

	reboot_guest "after the revert"
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
	guest_probe "asking bectl which boot environment is running" \
	    "bectl list | grep -qE '^preinstall[[:space:]]+NR'" 60
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
	guest_probe "asking the reverted system for a nested sysctl" \
	    "sysctl -n hw.vmm.nested.enable >/dev/null 2>&1" 60
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
