#!/bin/sh
#
# nested-demo.sh - CloudBSD bhyve nested-virtualization live demo
# =================================================================
#
#   Downloads a small, self-contained demo disk image and boots it as an
#   L1 guest on THIS CloudBSD nested host.  That L1 guest then automatically
#   boots a *second* guest (L2) INSIDE itself -- a VM inside a VM -- and shows
#   both consoles on your screen.  When the inner L2 guest reaches its login
#   marker, nested virtualization has been demonstrated end to end:
#
#         this host (L0)  ->  L1 guest  ->  L2 guest (nested!)
#
#   Home:  https://nested.cloudbsd.cat/
#
# -----------------------------------------------------------------------------
#   *** EXPERIMENTAL - NOT FOR PRODUCTION ***
#   bhyve nested virtualization is brand-new, unaudited code.  Run this ONLY on
#   a dedicated test machine you can afford to reboot.  Do not run it on
#   production equipment or anything you care about.
# -----------------------------------------------------------------------------
#
# Requirements: a CloudBSD "nested" kernel + nested bhyve (install via
#   https://nested.cloudbsd.cat/install.sh), run as root, ~10 GB free space.
#
# Everything this script creates is namespaced "nesteddemo-" and cleaned up on
# exit (pass --keep to leave artifacts behind).  It never touches VMs, taps,
# bridges or md devices it did not create.
#
# POSIX /bin/sh.
#
set -eu

# ---------------------------------------------------------------------------
# The greeting. Inlined rather than sourced, because this script is fetched and
# run on its own. Colour only when stdout is a terminal that can show it: piped
# into a log it degrades to plain text instead of spraying escape sequences.
# The warning is not decoration -- this is new, unaudited kernel code, and it
# says so every time it runs.
# ---------------------------------------------------------------------------
# The banner is one program, ${SELFDIR}/demo-banner, not a copy of it here.
# This driver used to carry its own second implementation of the same box, so
# run-auto-demo -- which prints the shared one before invoking this -- greeted
# the room twice, in two subtly different styles.
#
# DEMO_BANNER_SHOWN is set by a launcher that has already printed it. Running
# this driver directly leaves it unset, and the banner still appears, because
# the EXPERIMENTAL warning has to be seen every time and not only when someone
# came in through a launcher.
SELFDIR=${SELFDIR:-$(dirname "$0")}

demo_banner() {
	[ "${DEMO_BANNER_SHOWN:-0}" = 1 ] && return 0
	for _b in "${SELFDIR}/demo-banner" \
	    /usr/local/libexec/cloudbsd-demo/demo-banner; do
		# The banner is cosmetic and this driver runs under set -e: a
		# banner that somehow exits non-zero must not take a live demo
		# down with it.
		[ -x "${_b}" ] && { "${_b}" || true; return 0; }
	done
	# Not installed -- running straight from a source tree. Do not
	# reintroduce a second copy of the box; just make sure the warning
	# that matters is still impossible to miss.
	echo
	echo "bhyve -- NESTED VIRTUALIZATION   (hello, bhyvecon)"
	echo "EXPERIMENTAL - new, unaudited kernel code. Not for production."
	echo
	return 0
}
demo_banner

# ----------------------------- configuration ---------------------------------
# All of these can be overridden from the environment.

# Where to cache the downloaded image and run the demo (needs ~10 GB free).
WORKDIR=${WORKDIR:-/var/tmp/nesteddemo}

# Memory for the L1 guest (it needs room for itself plus a 1 GB inner L2).
MEM=${MEM:-4G}

# vCPUs for the L1 guest, and for the L2 guest it boots inside itself.
# The literal "all" means every core this host has.  One vCPU is the default
# because it is the configuration the demo is known to complete on; anything
# above that exercises nested SMP, which is the part still being stabilised.
CORES=${CORES:-1}

# Seconds for the inner guest to spin on arithmetic before powering off, or 0.
# The ordinary demo is dominated by EPT faults, so L2 never executes long enough
# to say whether its slice is bounded; a stretch with no I/O and no new pages is
# what makes the VMX-preemption timer observable at all.
L2SPIN=${L2SPIN:-0}
case "$L2SPIN" in ''|*[!0-9]*) L2SPIN=0 ;; esac

# How long (seconds) to wait for the inner L2 guest to reach its marker.
TIMEOUT=${TIMEOUT:-480}

# Where to fetch the demo image from, and its expected SHA-256.
# Override NESTED_DEMO_URL to point at a local copy; set NESTED_DEMO_SHA256=SKIP
# to skip verification (not recommended).
NESTED_DEMO_URL=${NESTED_DEMO_URL:-https://nested.cloudbsd.cat/nested-demo.raw.xz}
NESTED_DEMO_SHA256=${NESTED_DEMO_SHA256:-1a91b0a18adc92129791c134a247e009c00c0fbb769428fbc34d7f3555296794}

# bhyve tool binaries (default to the system-installed nested build).
BHYVE=${BHYVE:-/usr/sbin/bhyve}
BHYVELOAD=${BHYVELOAD:-/usr/sbin/bhyveload}
BHYVECTL=${BHYVECTL:-/usr/sbin/bhyvectl}

# Namespacing - everything we create starts with this.
NS=nesteddemo
# Honour a name supplied by a launcher.  run-auto-demo names the VM it is going
# to watch and hands that name to its watchdog; while this line ignored it, the
# watchdog was destroying a VM that had never existed, so the protection it
# exists to provide was not there at all.
VM="${VM:-${NS}-l1-$$}"

KEEP=0

# ----------------------------- pretty output ---------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
	B=$(tput bold); R=$(tput sgr0); GRN=$(tput setaf 2); RED=$(tput setaf 1); YEL=$(tput setaf 3); CYN=$(tput setaf 6)
else
	B=''; R=''; GRN=''; RED=''; YEL=''; CYN=''
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s[nested-demo]%s %s\n' "$CYN" "$R" "$*"; }
warn() { printf '%s[nested-demo]%s %s\n' "$YEL" "$R" "$*" >&2; }
err()  { printf '%s[nested-demo] ERROR:%s %s\n' "$RED" "$R" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
	cat <<EOF
Usage: nested-demo.sh [options]

Boots a demo VM (L1) on this CloudBSD nested host; that VM automatically boots
a nested VM (L2) inside itself and shows both consoles, proving nested
virtualization works (L0 host -> L1 -> L2).

Options:
  -c N, --cpus N Give the L1 guest N vCPUs, and the nested L2 guest inside it
                 the same.  "-c all" uses every core on this host.  Above one
                 vCPU this is the nested-SMP path: it is the interesting case,
                 and it is the one that can still wedge a guest.
  --all-cores    Shorthand for "-c all".
  --keep         Do not delete the run disk / logs on exit (for inspection).
  -h, --help     Show this help.

Environment knobs:
  WORKDIR              Cache + scratch dir           (default: $WORKDIR)
  MEM                  L1 guest memory               (default: $MEM)
  CORES                vCPUs per guest, or "all"     (default: $CORES)
  L2SPIN               seconds for L2 to spin        (default: $L2SPIN)
  TIMEOUT              Seconds to wait for L2 marker  (default: $TIMEOUT)
  NESTED_DEMO_URL      Image URL                     (default: $NESTED_DEMO_URL)
  NESTED_DEMO_SHA256   Expected sha256 of the .xz    (or SKIP)
  BHYVE / BHYVELOAD / BHYVECTL   Tool paths          (default: /usr/sbin/*)

*** EXPERIMENTAL - not for production. Run only on a dedicated test host. ***
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		-c|--cpus)
			[ $# -ge 2 ] || { usage; die "$1 needs a value"; }
			CORES=$2; shift ;;
		--all-cores) CORES=all ;;
		--keep)  KEEP=1 ;;
		-h|--help) usage; exit 0 ;;
		*) usage; die "unknown argument: $1" ;;
	esac
	shift
done

# Resolve and sanity-check the vCPU count before anything else uses it.  An
# unusable value has to be rejected here rather than reaching bhyve, where it
# surfaces as a bare usage message from a program the caller never invoked.
NCPU_HOST=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
[ "$CORES" = all ] && CORES=$NCPU_HOST
case "$CORES" in
	''|*[!0-9]*) die "--cpus takes a positive number or \"all\", not \"$CORES\"" ;;
esac
[ "$CORES" -ge 1 ] || die "--cpus must be at least 1"
if [ "$CORES" -gt "$NCPU_HOST" ]; then
	warn "asked for $CORES vCPUs but this host has $NCPU_HOST cores; using $NCPU_HOST."
	CORES=$NCPU_HOST
fi

# ----------------------------- banner ----------------------------------------
say ""
say "${B}==============================================================${R}"
say "${B}   CloudBSD  -  bhyve NESTED VIRTUALIZATION live demo${R}"
say "${B}==============================================================${R}"
say "   ${YEL}*** EXPERIMENTAL - unaudited code, NOT for production. ***${R}"
say "   Boots:  this host (L0)  ->  L1 guest  ->  L2 guest (nested)"
say "   Home:   https://nested.cloudbsd.cat/"
say "${B}==============================================================${R}"
say ""

# ----------------------------- cleanup / trap --------------------------------
RUNRAW=""
TAILPID=""
cleanup() {
	# Only ever touches things WE created (our VM name + our temp files).
	[ -n "${TAILPID}" ] && kill "${TAILPID}" 2>/dev/null || true
	"$BHYVECTL" --vm="$VM" --destroy >/dev/null 2>&1 || true
	if [ "$KEEP" -eq 1 ]; then
		[ -n "$RUNRAW" ] && info "kept run disk: $RUNRAW"
		[ -n "${CONSOLE:-}" ] && info "kept console log: $CONSOLE"
	else
		# Remove the throwaway run disk and chatty per-run logs.
		# The console log is left in place (the verdict points at it).
		[ -n "$RUNRAW" ] && rm -f "$RUNRAW" 2>/dev/null || true
		rm -f "$WORKDIR/${NS}-load-$$.log" "$WORKDIR/${NS}-bhyve-$$.log" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

# ----------------------------- preflight -------------------------------------
info "Running preflight checks..."

# 1) root
if [ "$(id -u)" -ne 0 ]; then
	die "must run as root.  Try:  doas sh $0   (or  sudo sh $0 )"
fi

# 2) nested kernel present?
if ! sysctl hw.vmm.nested >/dev/null 2>&1; then
	err "this kernel has no 'hw.vmm.nested' - it is NOT a CloudBSD nested kernel."
	err "Install the nested kernel + tools first:"
	err "    fetch -o - https://nested.cloudbsd.cat/install.sh | sh"
	exit 1
fi

# 3) is vmm loaded / usable?
if ! sysctl hw.vmm.nested.enable >/dev/null 2>&1; then
	warn "vmm module not loaded; attempting 'kldload vmm'..."
	kldload vmm 2>/dev/null || die "could not load vmm.ko - is this the nested kernel?"
fi

# 4) which arch are we on, and is nesting supported by hardware?
SVM=$(sysctl -n hw.vmm.nested.svm 2>/dev/null || echo 0)
VMX=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null || echo 0)
if [ "$SVM" != "0" ]; then
	info "Host CPU: AMD SVM nested virtualization available (hw.vmm.nested.svm=$SVM)."
elif [ "$VMX" != "0" ]; then
	info "Host CPU: Intel VMX nested virtualization available (hw.vmm.nested.vmx=$VMX)."
else
	err "neither hw.vmm.nested.svm nor .vmx is enabled - this CPU/kernel cannot"
	err "host nested guests.  You need an Intel VT-x or AMD-V host running the"
	err "CloudBSD nested kernel."
	exit 1
fi

# 5) is this the nested build? ask the kernel, not a deprecated flag
for t in "$BHYVE" "$BHYVELOAD" "$BHYVECTL"; do
	[ -x "$t" ] || die "missing tool: $t (install nested bhyve from https://nested.cloudbsd.cat/install.sh)"
done
if ! sysctl -n hw.vmm.nested.enable >/dev/null 2>&1; then
	err "hw.vmm.nested.enable is absent: this kernel has no nested-virt support."
	err "You are running stock bhyve, not the CloudBSD nested build."
	err "Install it:  fetch -o - https://nested.cloudbsd.cat/install.sh | sh"
	exit 1
fi
if [ "$(sysctl -n hw.vmm.nested.vmx 2>/dev/null || echo 0)" = 0 ] && \
   [ "$(sysctl -n hw.vmm.nested.svm 2>/dev/null || echo 0)" = 0 ]; then
	err "no nested-capable CPU reported (hw.vmm.nested.vmx/svm both 0)."
	exit 1
fi
info "CloudBSD nested bhyve detected."

# 6) disk space (need room for the .xz + decompressed raw + a run copy).
mkdir -p "$WORKDIR"
NEED_MB=10240
AVAIL_MB=$(df -m "$WORKDIR" | awk 'NR==2 {print $4}')
if [ "${AVAIL_MB:-0}" -lt "$NEED_MB" ]; then
	die "not enough free space in $WORKDIR: have ${AVAIL_MB}MB, need >= ${NEED_MB}MB.
     Set WORKDIR=/path/with/space and re-run."
fi
info "Free space in $WORKDIR: ${AVAIL_MB}MB (OK)."

# ----------------------------- enable nesting --------------------------------
ENABLE_WAS=$(sysctl -n hw.vmm.nested.enable 2>/dev/null || echo 0)
if [ "$ENABLE_WAS" = "1" ]; then
	info "Nested virtualization already enabled (hw.vmm.nested.enable=1)."
else
	# Nesting is on by default in this build, so finding it off means somebody
	# turned it off on this host.  Saying "it is off by default" there told the
	# operator the opposite of what had happened.
	info "hw.vmm.nested.enable is 0 on this host - it has been turned off."
	info "  Turning it back on for this run."
	sysctl hw.vmm.nested.enable=1 >/dev/null 2>&1 || \
		die "could not set hw.vmm.nested.enable=1"
fi

# ----------------------------- obtain media ----------------------------------
XZ="$WORKDIR/nested-demo.raw.xz"
RAW="$WORKDIR/nested-demo.raw"          # cached master (kept pristine)

verify_sha() {  # $1=file  $2=expected
	[ "$2" = "SKIP" ] && { warn "checksum verification skipped (NESTED_DEMO_SHA256=SKIP)."; return 0; }
	info "Verifying SHA-256 of $(basename "$1")..."
	got=$(sha256 -q "$1" 2>/dev/null || sha256sum "$1" 2>/dev/null | awk '{print $1}')
	if [ "$got" != "$2" ]; then
		err "checksum MISMATCH for $1"
		err "  expected: $2"
		err "  got:      $got"
		return 1
	fi
	info "Checksum OK."
	return 0
}

if [ -f "$RAW" ]; then
	# Cached, already-verified image from a previous run - fast re-runs.
	info "Using cached demo image: $RAW  (delete it to force a fresh download)."
else
	# Need the .xz (download if missing), verify, then decompress.
	if [ ! -f "$XZ" ]; then
		info "Demo image not cached - fetching it now."
		info "  FROM: $NESTED_DEMO_URL"
		info "  TO:   $XZ"
		if command -v fetch >/dev/null 2>&1; then
			fetch -o "$XZ.part" "$NESTED_DEMO_URL" || die "download failed (fetch). Is $NESTED_DEMO_URL reachable?"
		elif command -v curl >/dev/null 2>&1; then
			curl -fL -o "$XZ.part" "$NESTED_DEMO_URL" || die "download failed (curl). Is $NESTED_DEMO_URL reachable?"
		else
			die "no 'fetch' or 'curl' available to download $NESTED_DEMO_URL"
		fi
		mv "$XZ.part" "$XZ"
	else
		info "Found cached compressed image: $XZ"
	fi
	verify_sha "$XZ" "$NESTED_DEMO_SHA256" || die "refusing to use a corrupt/altered image."
	info "Decompressing $(basename "$XZ") -> $(basename "$RAW") ..."
	xz -d -k -f -c "$XZ" > "$RAW.part" || die "decompression failed."
	mv "$RAW.part" "$RAW"
fi
[ -f "$RAW" ] || die "demo image missing after fetch: $RAW"
info "Demo image ready: $RAW ($(du -h "$RAW" | awk '{print $1}'))."

# ----------------------------- per-run copy ----------------------------------
# Boot a throwaway COPY so re-runs are safe and the cached master stays clean.
RUNRAW="$WORKDIR/${NS}-run-$$.raw"
CONSOLE="$WORKDIR/${NS}-console-$$.log"
info "Preparing run disk: $RUNRAW"
cp "$RAW" "$RUNRAW"
: > "$CONSOLE"

# ----------------------------- boot L1 ---------------------------------------
say ""
say "${B}--------------------------------------------------------------${R}"
say "${B} Booting the L1 guest now — an ordinary bhyve command.${R}"
say " Watch below: you will first see the ${B}L1 guest${R} boot, then it will"
say " automatically boot an ${B}L2 guest INSIDE itself${R} (labeled banners)."
say " Full console log: $CONSOLE"
say "${B}--------------------------------------------------------------${R}"
say ""

info "Loading L1 kernel..."
# nested_demo_l2_cpus reaches the guest as a kernel environment variable, which
# is how its rc.local learns how many vCPUs to give the L2 guest.  An older
# image that does not read it simply boots L2 with one vCPU.
"$BHYVELOAD" -c stdio -m "$MEM" -d "$RUNRAW" \
	-e console=comconsole -e autoboot_delay=1 \
	-e nested_demo_l2_cpus="$CORES" \
	-e nested_demo_l2_spin="$L2SPIN" "$VM" \
	>"$WORKDIR/${NS}-load-$$.log" 2>&1 </dev/null \
	|| { cat "$WORKDIR/${NS}-load-$$.log" >&2; die "bhyveload failed."; }

if [ "$CORES" -eq 1 ]; then
	info "Starting L1 guest (1 vCPU)..."
else
	info "Starting L1 guest ($CORES vCPUs; L2 will get $CORES too)..."
	warn "nested SMP is the path still being stabilised.  A wide guest has"
	warn "stalled at its root mount, aborted its L2 with a VM-entry failure,"
	warn "and on one Intel host at 4 vCPUs it panicked the host itself."
	warn "Run this on a machine you can afford to lose, not a busy one."
fi
# com1 is written to the console log; we tail it live so you SEE both guests.
"$BHYVE" -c "$CORES" -m "$MEM" -A -H -P \
	-s 0,hostbridge \
	-s 3,virtio-blk,"$RUNRAW" \
	-s 31,lpc -l com1,stdio "$VM" \
	</dev/null >"$CONSOLE" 2>"$WORKDIR/${NS}-bhyve-$$.log" &
BHYVE_PID=$!

# Live-stream the guest console to the user's terminal.
tail -n +1 -f "$CONSOLE" &
TAILPID=$!

# ----------------------------- watch for markers -----------------------------
elapsed=0
step=3
RESULT=timeout
while [ "$elapsed" -lt "$TIMEOUT" ]; do
	if grep -q 'NESTED_DEMO_L2_OK' "$CONSOLE" 2>/dev/null; then
		RESULT=ok
		# give the L2 guest a moment to finish printing and power off
		sleep 4
		break
	fi
	if ! kill -0 "$BHYVE_PID" 2>/dev/null; then
		grep -q 'NESTED_DEMO_L2_OK' "$CONSOLE" 2>/dev/null && RESULT=ok || RESULT=exited
		break
	fi
	sleep "$step"
	elapsed=$((elapsed + step))
done

# stop live tail + guest
kill "$TAILPID" 2>/dev/null || true; TAILPID=""
"$BHYVECTL" --vm="$VM" --destroy >/dev/null 2>&1 || true
kill "$BHYVE_PID" 2>/dev/null || true
wait "$BHYVE_PID" 2>/dev/null || true

# ----------------------------- verdict ---------------------------------------
say ""
if [ "$RESULT" = "ok" ]; then
	L2LINE=$(grep 'NESTED_DEMO_L2_OK' "$CONSOLE" | head -1 | tr -d '\r' | sed 's/^#* *//')
	say "${GRN}${B}==================================================================${R}"
	say "${GRN}${B}  NESTED VIRTUALIZATION CONFIRMED${R}"
	say "${GRN}${B}  An L2 guest booted INSIDE an L1 guest INSIDE this host.${R}"
	say "${GRN}${B}==================================================================${R}"
	say "   L0 host : $(uname -sr) $(uname -m)  [$( [ "$SVM" != 0 ] && echo AMD-SVM || echo Intel-VMX )]"
	say "   L1 guest: an ordinary bhyve guest — it hosted the nested guest"
	say "   vCPUs   : ${CORES} per guest (host has ${NCPU_HOST} cores)"
	say "   L2 guest: ${B}${L2LINE}${R}"
	say ""
	say "   Full console log (both guests): $CONSOLE"
	[ "$KEEP" -eq 0 ] && say "   (run disk removed; use --keep to retain artifacts)"
	say ""
	exit 0
else
	say "${RED}${B}==================================================================${R}"
	say "${RED}${B}  NESTED DEMO DID NOT COMPLETE  (result: $RESULT)${R}"
	say "${RED}${B}==================================================================${R}"
	if [ "$RESULT" = timeout ]; then
		say "   The inner L2 guest did not reach its marker within ${TIMEOUT}s."
	elif [ "$RESULT" = exited ]; then
		say "   The L1 guest exited before the L2 marker appeared."
	fi
	say "   Diagnosis hints:"
	say "     - Confirm this is a nested kernel:  sysctl hw.vmm.nested"
	say "     - Confirm nesting is on:            sysctl hw.vmm.nested.enable"
	say "     - Try more memory/time:  MEM=6G TIMEOUT=600 $0"
	[ "$CORES" -gt 1 ] && \
	    say "     - Retry with one vCPU:   $0   (you used -c $CORES)"
	say ""
	say "   Last 40 lines of the console:"
	say "   ------------------------------------------------------------"
	tail -40 "$CONSOLE" | tr -d '\r' | sed 's/^/   | /'
	say "   ------------------------------------------------------------"
	say "   Full console log: $CONSOLE"
	exit 1
fi
