#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Build CloudBSD *base* packages once (pkgbase grammar).
#
# FreeBSD pkgbase already has:
#   PKG_NAME_PREFIX  (bsd.pkg.pre.mk / Makefile.inc1) defaults to FreeBSD
#                    upstream; this script overrides it to CloudBSD locally
#                    (see PKG_NAME_PREFIX below) and never edits those files
#   name = ${PKG_NAME_PREFIX}-${component}
#   origin = base/${PKG_NAME_PREFIX}-${component}
#   repo layout ${REPODIR}/${ABI}/${PKG_VERSION}/ plus a `latest` symlink
#     (Makefile.inc1: REPODIR/${PKG_ABI}/latest -> version dir)
# There is no channel string in the filename. Public pkgbase uses repo
# names (base_latest vs base_release_N) as different URLs, not -dev in
# the pkg name. Ports are not pkgbase: do not set PKG_NAME_PREFIX when
# building third-party ports.
#
#   sudo ./tests/sys/vmm/nested/scripts/build_packages.sh
#   NESTED_SKIP_BUILDKERNEL=1
#
# Output: ${NESTED_PKGDIR}/${ABI}/${VERSION}/CloudBSD-*.pkg
#         ${NESTED_PKGDIR}/${ABI}/latest -> ${VERSION}
# Does not install on any host.

# shellcheck shell=sh
set -eu

PROGRAM="${0##*/}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SRCTOP=$(CDPATH= cd -- "${SCRIPT_DIR}/../../../../.." && pwd)
JOBS=${NESTED_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}
# A plain positive integer, nothing else. It reaches `-j` and, through the
# environment, a generated shell script that runs as root.
case "$JOBS" in
""|*[!0-9]*) echo "$PROGRAM: NESTED_JOBS must be a positive integer: $JOBS" >&2; exit 2 ;;
0) echo "$PROGRAM: NESTED_JOBS must be greater than zero" >&2; exit 2 ;;
esac
KERNCONF=${NESTED_KERNCONF:-GENERIC}
# Match Makefile.inc1 REPODIR/${ABI}/${VERSION} + latest symlink.
PKGDIR=${NESTED_PKGDIR:-${HOME}/nested-packages}
STAGE=${NESTED_STAGE:-/tmp/nested-pkg-stage}
SKIP_KERN=${NESTED_SKIP_BUILDKERNEL:-0}
# Channel pointer (directory name of the symlink), not a filename tag.
# pkgbase uses "latest"; later release channels can add another symlink.
CHANNEL=${PKG_CHANNEL:-latest}
PKG_NAME_PREFIX=${PKG_NAME_PREFIX:-CloudBSD}

log() { printf '%s: %s\n' "$PROGRAM" "$*"; }
die() { log "FAIL: $*"; exit 1; }

[ -f "${SRCTOP}/sys/conf/kern.pre.mk" ] || die "SRCTOP not a src tree: $SRCTOP"
# ROOT IS NOT REQUIRED, and deliberately so. The installs below use NO_ROOT,
# which records intended ownership in a METALOG instead of calling chown, and
# pkg create takes that ownership from the plist rather than from the staged
# files on disk. Both halves measured: a file staged as an unprivileged user
# comes out of pkg query as root:wheel with the right mode.
#
# The alternative was a doas rule letting the build user run this script as
# root. That cannot be made safe here: the Jenkins agent owns its own
# workspace, so any allowlist naming a path under it is writable by the very
# principal the rule grants, and the realpath gate that would guard it adds
# nothing when the caller owns every path component.
#
# Run as root anyway and it still works -- the flags are harmless there.
if [ "$(id -u)" -eq 0 ]; then
	log "running as root; NO_ROOT staging is used regardless"
fi

GITREV=$(git -C "$SRCTOP" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
GITFULL=$(git -C "$SRCTOP" rev-parse HEAD 2>/dev/null || echo unknown)
DATEUTC=$(date -u +%Y%m%d)
VERSION=${PKG_VERSION:-${NESTED_PKG_VERSION:-16.0.${DATEUTC}.${GITREV}}}
ABI=$(pkg config ABI 2>/dev/null || echo FreeBSD:16:amd64)
OUTDIR="${PKGDIR}/${ABI}/${VERSION}"

log "srctop=$SRCTOP git=$GITFULL"
log "PKG_NAME_PREFIX=$PKG_NAME_PREFIX version=$VERSION abi=$ABI channel=$CHANNEL"
log "outdir=$OUTDIR"

rm -rf "$STAGE"
mkdir -p "$OUTDIR" \
	"$STAGE/kernel" \
	"$STAGE/bhyve/usr/lib" "$STAGE/bhyve/usr/sbin" "$STAGE/bhyve/usr/include" \
	"$STAGE/bhyve/usr/libexec" \
	"$STAGE/bhyve/usr/share/man/man5" "$STAGE/bhyve/usr/share/man/man8" \
	"$STAGE/bhyve/usr/lib/debug/usr/lib" \
	"$STAGE/bhyve/usr/lib/debug/usr/sbin" \
	"$STAGE/bhyve/usr/lib/debug/usr/libexec"

if [ "$SKIP_KERN" != 1 ]; then
	log "buildkernel $KERNCONF"
	make -C "$SRCTOP" -j"$JOBS" buildkernel KERNCONF="$KERNCONF"
else
	log "skip buildkernel (NESTED_SKIP_BUILDKERNEL=1)"
fi

log "installkernel DESTDIR=$STAGE/kernel (NO_ROOT)"
# A TOP-LEVEL make, so Makefile.inc1's own
#	METALOG_INSTALLFLAGS = -U -M ${METALOG} -D ${INSTALL_DDIR}
# applies and no INSTALL override is needed here. That is not true of the leaf
# makes further down, which is why they carry one.
KERN_METALOG="$STAGE/kernel/METALOG"
make -C "$SRCTOP" installkernel KERNCONF="$KERNCONF" DESTDIR="$STAGE/kernel" \
	-DNO_ROOT METALOG="$KERN_METALOG"
find "$STAGE/kernel" \( -name '*.debug' -o -name '*.full' -o -name '*.symbols' \) -delete
rm -rf "$STAGE/kernel/usr/lib/debug" || true

# THE WORLD HAS TO EXIST IN THIS OBJECT TREE.
#
# The bhyve tools are built inside `make buildenv', which compiles against the
# world's staged headers and libraries. This script used to assume they were
# already there, which was true only because it had always run against a warm
# /usr/obj that somebody had built a world in by hand. Point it at a fresh
# object tree -- as the Jenkins job now does, because /usr/obj is not writable
# by the agent user -- and every file fails with
#
#	sys/sys/types.h:43:10: fatal error: 'machine/endian.h' file not found
#
# which names a header rather than the missing world and sends you looking in
# the wrong place. Measured on the first Jenkins run to get this far: the
# kernel built and installed fine, and then all eight userland objects failed
# on that line.
#
# WITH_META_MODE is on for these builds, so a warm tree makes this close to a
# no-op; it is the FIRST build in a new object tree that pays.
if [ "${NESTED_SKIP_BUILDWORLD:-0}" != 1 ]; then
	log "buildworld (needed by buildenv; cheap on a warm META_MODE tree)"
	make -C "$SRCTOP" -j"$JOBS" buildworld
else
	log "skip buildworld (NESTED_SKIP_BUILDWORLD=1)"
fi

log "libvmmapi + bhyve"
# -DWITHOUT_TESTS on the installs: these tools have test directories now, and
# the bhyve package is not where tests belong -- they ship in the tests
# package, staged from its own hierarchy. Without this the install walks into
# usr.sbin/bhyveload/tests and fails, because this stage has only the handful
# of directories created above and no /usr/tests tree to install into.
#
# WITHOUT_TESTS rather than MK_TESTS=no: the MK_ variables are derived from the
# WITH_/WITHOUT_ knobs by bsd.mkopt.mk, so setting the derived one is the
# indirect way round and depends on precedence rules that are not worth
# relying on.
# Everything below runs inside `make buildenv`, the world's own build
# environment, and NOT as a plain make in a subdirectory.
#
# A bare `make -C ${SRCTOP}/usr.sbin/bhyve all` compiles with the HOST's
# compiler and the HOST's /usr/include, while `-I${SRCTOP}/sys` pulls headers
# out of the source tree. That works only for as long as the two agree, and
# they stop agreeing the moment the tree moves ahead of the world installed on
# the builder. Merging 147 upstream commits did exactly that:
#
#   sys/sys/stdint.h:72: error: 'WCHAR_WIDTH' macro redefined
#   /usr/include/x86/_stdint.h:210: note: previous definition is here
#
# and the release build stopped with 0 packages after four hours of work that
# had already succeeded. buildenv supplies --sysroot and -B pointing at the
# world this build just produced, so these compile against the tree they belong
# to. It also keeps -ffile-prefix-map, which is the whole point of this release.
#
# One script rather than a chain of BUILDENV_SHELL invocations: each one is a
# fresh environment, and the quoting needed to nest a multi-command pipeline
# inside BUILDENV_SHELL is not reviewable.
# One trap for both generated scripts. A second `trap ... EXIT` REPLACES the
# first rather than adding to it, so two of them means the earlier file is only
# cleaned up by the explicit rm on the success path and leaks on every failure
# between the two.
_be=""; _be9=""
trap 'rm -f "$_be" "$_be9"' EXIT INT TERM
_be=$(mktemp) || { log "ERROR: cannot create a temporary file"; exit 1; }
# A QUOTED heredoc, and the values arrive through the environment.
#
# With an unquoted heredoc, $SRCTOP, $STAGE and $JOBS stop being make arguments
# and become shell SOURCE in a file that then gets executed: a value carrying a
# quote, a semicolon or a newline is a second command rather than a bad path.
# The generated script is run as root during a release, so it is written the
# way any other generated program should be -- with the data kept out of the
# code.
BHYVE_METALOG="$STAGE/bhyve/METALOG"
export NP_SRCTOP="$SRCTOP" NP_STAGE="$STAGE" NP_JOBS="$JOBS" \
	NP_METALOG="$BHYVE_METALOG"
cat > "$_be" <<'BUILDENV_EOF'
#!/bin/sh
# Generated; runs inside 'make buildenv'.
set -eu
make -C "${NP_SRCTOP}/lib/libvmmapi" -j"${NP_JOBS}" all
make -C "${NP_SRCTOP}/usr.sbin/bhyve" -j"${NP_JOBS}" all
make -C "${NP_SRCTOP}/usr.sbin/bhyvectl" -j"${NP_JOBS}" all
make -C "${NP_SRCTOP}/usr.sbin/bhyveload" -j"${NP_JOBS}" all
# INSTALL is overridden, not INSTALLFLAGS. These are LEAF makes, so
# Makefile.inc1 is not in play and nothing appends the metalog flags for
# them. INSTALLFLAGS alone is not enough either: bsd.man.mk builds its own
# command from ${INSTALL} and never looks at INSTALLFLAGS, so the manual
# pages would still try to chown and the install would stop. Overriding
# INSTALL covers every consumer -- programs, manual pages, files, links.
# Measured on each variant.
_ni="install -U -M ${NP_METALOG} -D ${NP_STAGE}/bhyve"
_nf="-DNO_ROOT -DWITHOUT_TESTS -DWITHOUT_DEBUG_FILES"
make -C "${NP_SRCTOP}/lib/libvmmapi" install DESTDIR="${NP_STAGE}/bhyve" ${_nf} METALOG="${NP_METALOG}" INSTALL="${_ni}"
make -C "${NP_SRCTOP}/usr.sbin/bhyve" install DESTDIR="${NP_STAGE}/bhyve" ${_nf} METALOG="${NP_METALOG}" INSTALL="${_ni}"
make -C "${NP_SRCTOP}/usr.sbin/bhyvectl" install DESTDIR="${NP_STAGE}/bhyve" ${_nf} METALOG="${NP_METALOG}" INSTALL="${_ni}"
# Ship bhyveload too: it is what creates the VM, so an installed system needs
# the matching one.
make -C "${NP_SRCTOP}/usr.sbin/bhyveload" install DESTDIR="${NP_STAGE}/bhyve" ${_nf} METALOG="${NP_METALOG}" INSTALL="${_ni}"
BUILDENV_EOF
chmod 0700 "$_be"
log "building the bhyve toolset inside the world build environment"
make -C "$SRCTOP" buildenv BUILDENV_SHELL="$_be"
rm -f "$_be"

# bhyve links libprivate9p.so.1 (lib9p), which is newer than any published stock
# base snapshot -- bundle it so the package installs standalone on a stock
# FreeBSD 16. libuvmem.so.1 IS in stock base (FreeBSD-runtime), so leave that one.
# Same reason as above: inside buildenv, not as a bare subdirectory make.
_be9=$(mktemp) || { log "ERROR: cannot create a temporary file"; exit 1; }
cat > "$_be9" <<'BUILDENV9_EOF'
#!/bin/sh
set -eu
make -C "${NP_SRCTOP}/lib/lib9p" -j"${NP_JOBS}" all
BUILDENV9_EOF
chmod 0700 "$_be9"
make -C "$SRCTOP" buildenv BUILDENV_SHELL="$_be9"
rm -f "$_be9"
# Copy just the runtime shared object (not headers/man, which would need
# staging dirs and aren't part of a base package) into the bhyve stage.
#
# -V reads a variable and builds nothing, so it is safe outside buildenv --
# and it must stay outside, because BUILDENV_SHELL swallows stdout.
_l9p_obj=$(make -C "${SRCTOP}/lib/lib9p" -V .OBJDIR)
mkdir -p "$STAGE/bhyve/usr/lib"
cp -a "${_l9p_obj}/libprivate9p.so.1" "$STAGE/bhyve/usr/lib/libprivate9p.so.1"
# Drop bhyve-slirp-helper: on a stock system it is owned by the un-removable
# FreeBSD-utilities base package, so bundling it makes `pkg add` conflict.
rm -f "$STAGE/bhyve/usr/libexec/bhyve-slirp-helper" \
      "$STAGE/bhyve/usr/lib/debug/usr/libexec/bhyve-slirp-helper.debug"

write_manifest() {
	_pkg=$1
	_comment=$2
	_m=$3
	_shlibs=${4:-}
	_name="${PKG_NAME_PREFIX}-${_pkg}"
	cat > "$_m" <<MAN
name: ${_name}
version: "${VERSION}"
origin: base/${_name}
comment: "${_comment}"
desc: "${_comment}. Git ${GITFULL}. Built $(date -u +%Y-%m-%dT%H:%M:%SZ)."
maintainer: mark@cloudbsd.org
www: https://www.cloudbsd.org
abi: "${ABI}"
arch: "${ABI}"
prefix: /
licenselogic: single
licenses: [BSD2CLAUSE]
MAN
	if [ -n "$_shlibs" ]; then
		printf 'shlibs_provided: [%s]\n' "$_shlibs" >> "$_m"
	fi
}

# Base packages only. Maps to FreeBSD-kernel-generic / FreeBSD-bhyve.
# Do not emit CloudBSD-* names for ports or extra test scripts.
pkg_from_stage() {
	_pkg=$1
	_comment=$2
	_root=$3
	_shlibs=${4:-}
	_name="${PKG_NAME_PREFIX}-${_pkg}"
	_man=$(mktemp /tmp/cbsd-manifest.XXXXXX)
	_plist=$(mktemp /tmp/cbsd-plist.XXXXXX)
	write_manifest "$_pkg" "$_comment" "$_man" "$_shlibs"
	# The plist carries OWNERSHIP, taken from the METALOG the NO_ROOT
	# install wrote. A bare `find' lists the staged files, and those are
	# owned by whoever ran the build -- so a package built unprivileged
	# would install every file owned by that user. pkg honours
	# `@(user,group,mode) path', which is what makes an unprivileged build
	# produce a root-owned package.
	#
	# No fallback to `find' when the METALOG is missing. A fallback would
	# quietly emit a package with the build user's ownership baked in,
	# which is the failure this whole change exists to avoid, and it would
	# look exactly like a successful build.
	_meta="$_root/METALOG"
	[ -r "$_meta" ] || die "no METALOG under $_root -- the install did not run with NO_ROOT, and a plist without ownership would ship files owned by $(id -un)"

	# Last entry wins: mtree logs may name a path more than once. Only
	# paths that still EXIST are emitted, because the debug and symbol
	# files are deleted after install and would otherwise be listed and
	# then missing at pkg create time.
	awk -v root="$_root" '''
	{
		path = $1
		sub(/^\.\//, "", path)
		u = ""; g = ""; m = ""; t = ""
		for (i = 2; i <= NF; i++) {
			if ($i ~ /^uname=/) { u = substr($i, 7) }
			else if ($i ~ /^gname=/) { g = substr($i, 7) }
			else if ($i ~ /^mode=/)  { m = substr($i, 6) }
			else if ($i ~ /^type=/)  { t = substr($i, 6) }
		}
		if (t == "dir" || path == "" || path == "METALOG") next
		if (u == "" || g == "" || m == "") next
		own[path] = "@(" u "," g "," m ") " path
		order[path] = NR
	}
	END {
		for (p in own) print order[p] "\t" own[p]
	}''' "$_meta" | sort -n | cut -f2- | while read -r _line; do
		_p=${_line##*) }
		[ -e "$_root/$_p" ] || [ -L "$_root/$_p" ] || continue
		printf '''%s\n''' "$_line"
	done > "$_plist"

	[ -s "$_plist" ] || die "empty plist for $_name under $_root"
	# Every line must carry ownership. One that does not would install as
	# the build user, and would be invisible among thousands that do.
	if grep -qv '''^@(.*,.*,.*) ''' "$_plist"; then
		grep -v '''^@(.*,.*,.*) ''' "$_plist" | head -3 >&2
		die "plist lines without ownership for $_name (see above)"
	fi
	pkg create -M "$_man" -p "$_plist" -r "$_root" -o "$OUTDIR"
	rm -f "$_man" "$_plist"
	log "created $_name"
}

pkg_from_stage kernel-generic \
	"CloudBSD GENERIC kernel + modules (incl. vmm.ko, zfs.ko)" \
	"$STAGE/kernel"

pkg_from_stage bhyve \
	"CloudBSD bhyve + bhyveload + bhyvectl + libvmmapi (nested-virt)" \
	"$STAGE/bhyve" \
	"libprivate9p.so.1"

# Generate the pkg(8) repository catalog (meta.conf + packagesite + data) in the
# version directory so clients can `pkg update` / `pkg install` from this repo.
# Without it the repo has only raw .pkg files and the pkg-install path
# (install.sh) fails. Run it BEFORE the stable-alias symlinks below so the
# packages are not double-indexed under two filenames.
# Signed when a signing command is configured.
#
# NESTED_SIGNING_COMMAND is the command pkg pipes the repository digest to and
# reads a signature back from. It is a command rather than a key path so that
# the key can stay on the machine that holds it, reached over ssh.
#
# How much that is worth depends entirely on the account the command runs as,
# and it is worth being exact rather than reassuring. If the build host can ssh
# to the signing host as a user who can READ the key file, then the separation
# is cosmetic: a compromised builder takes the key and can sign anything for
# ever. The property only exists when the key is owned by an account the
# builder cannot become -- a forced command in that account's authorized_keys,
# so the builder can ask for a signature and get nothing else.
#
# What signing buys unconditionally is different and still worth having:
# tampering AFTER the build -- at the webroot, at a cache, on a mirror -- is
# detected by every client. That does not depend on where the key lives.
#
# Unsigned is still reachable, because that is what the current release is and
# refusing it outright would make this script unable to reproduce it -- but only
# by saying NESTED_ALLOW_UNSIGNED=1 out loud. An unsigned repository sits above
# the signed FreeBSD one at priority 10 on every host that installs from us, and
# it ships pkg itself, so it is not something a build should be able to arrive
# at by forgetting a variable.

# has_signature: does this catalogue archive carry a signature member?
#
# The member names are MEASURED, on pkg 2.8.4, by building the same repository
# three ways and listing what came out. They are not what one would guess, and
# the two signing modes do not agree with each other:
#
#   mode                  data.pkg                packagesite.pkg
#   --------------------  ----------------------  ---------------------------
#   unsigned              data                    packagesite.yaml
#   rsa:<keyfile>         signature, data         signature, packagesite.yaml
#   signing_command: ...  data.sig, data.pub,     packagesite.yaml.sig,
#                         data                    packagesite.yaml.pub,
#                                                 packagesite.yaml
#
# So a check for a member named "signature" -- which is what this originally
# had -- reports EVERY command-signed repository as unsigned, and the build
# would have aborted on the release it had just signed correctly. The check
# accepts either shape: "signature", or "<content member>.sig".
#
# Exact member names, never a substring: `grep signature` over a listing is
# also satisfied by a package named something-signature-something. And the
# expected name is derived from THIS archive's content member -- passing $2 --
# rather than accepting any member ending in .sig, so a stray or mismatched
# signature member cannot stand in for the one that covers this catalogue.
#
#   has_signature <archive> <content member>
has_signature() {
	[ -f "$1" ] || return 1
	tar -tf "$1" 2>/dev/null | grep -qxF -e signature -e "$2.sig"
}

if [ -n "${NESTED_SIGNING_COMMAND:-}" ]; then
	log "pkg repo: signing with: $NESTED_SIGNING_COMMAND"
	_siglog="$OUTDIR/.pkg-repo-sign.log"
	# $NESTED_SIGNING_COMMAND is deliberately UNQUOTED. pkg takes the signing
	# command as its remaining arguments -- the documented form is
	# "signing_command: ssh signing-server sign.sh" -- so the words have to
	# reach pkg as separate arguments, and quoting it would hand pkg one
	# argument containing spaces. `set -f` for the duration is the missing
	# half: word splitting is wanted here, pathname expansion is not, and
	# without it a signing command containing a "*" would be replaced by
	# whatever happens to be in the current directory.
	#
	# The `if` condition form, not a bare command followed by `$?`: this
	# script runs under `set -e`, so a bare failing pkg would end the run
	# before the status could be read AND before `set -f` was turned back off.
	set -f
	if pkg repo "$OUTDIR" signing_command: $NESTED_SIGNING_COMMAND >"$_siglog" 2>&1; then
		set +f
		log "pkg repo: catalog generated and SIGNED in $OUTDIR"
		# Prove it rather than trust the exit status: pkg reports success for a
		# catalogue it wrote, and the signature is a separate member inside it.
		#
		# This used to run `pkg repo -l "$OUTDIR"` first and grep its output.
		# That was actively destructive: -l is --list-files, so it REGENERATED
		# the catalogue -- with no signing argument, hence unsigned -- and then
		# the check ran against the catalogue it had just stripped. Signing
		# could never have reported success, and a repository that had been
		# signed correctly came out unsigned. Verification must not be able to
		# change what it verifies.
		if has_signature "$OUTDIR/data.pkg" data &&
		   has_signature "$OUTDIR/packagesite.pkg" packagesite.yaml; then
			log "pkg repo: signature present in data.pkg and packagesite.pkg"
			rm -f "$_siglog"
		else
			log "ERROR: signing was requested but a catalogue carries no signature"
			has_signature "$OUTDIR/data.pkg" data ||
			    log "       data.pkg (the catalogue clients read) is unsigned"
			has_signature "$OUTDIR/packagesite.pkg" packagesite.yaml ||
			    log "       packagesite.pkg is unsigned"
			exit 1
		fi
	else
		set +f
		log "ERROR: signing failed -- refusing to leave an unsigned repository"
		log "       where a signed one was asked for"
		# pkg's own diagnostic, which this used to discard: the only symptom
		# of a broken signing command was this message and nothing else.
		#
		# An `if`, not `[ -s ... ] && sed ...`: under `set -e` a false test
		# ends the whole compound non-zero and the script exits THERE, so the
		# `exit 1` below is never reached. The status happens to match today,
		# which is exactly what makes it a trap for the next edit.
		if [ -s "$_siglog" ]; then
			sed 's/^/       pkg: /' "$_siglog"
		fi
		exit 1
	fi
elif [ "${NESTED_ALLOW_UNSIGNED:-0}" != 1 ]; then
	# Unsigned is a decision, not a default.
	#
	# Without this, a build whose NESTED_SIGNING_COMMAND simply failed to
	# reach the environment -- a typo, a variable not exported through one
	# more layer of shell -- produces an unsigned repository and a green
	# build, and nothing anywhere says the release was downgraded. That
	# repository installs at priority 10 above the signed FreeBSD one on
	# every host that follows our instructions, and it ships pkg itself.
	#
	# So the two ways to get an unsigned repository are now both explicit:
	# set NESTED_SIGNING_COMMAND and get a signed one, or say
	# NESTED_ALLOW_UNSIGNED=1 and mean it.
	log "ERROR: no NESTED_SIGNING_COMMAND, and NESTED_ALLOW_UNSIGNED is not 1."
	log "       Refusing to build an unsigned repository by omission."
	log "       Set NESTED_SIGNING_COMMAND to sign, or NESTED_ALLOW_UNSIGNED=1"
	log "       to say plainly that this release ships unsigned."
	exit 1
else
	# Symmetric with the signed path above: pkg's diagnostic is kept, and a
	# failure is fatal. It used to discard the output and merely warn, so a
	# build host where `pkg repo` could not run published a directory of raw
	# .pkg files with no catalogue at all -- which every client reads as an
	# empty repository -- and still exited 0 with the one line explaining it
	# thrown away.
	_repolog="$OUTDIR/.pkg-repo.log"
	if pkg repo "$OUTDIR" >"$_repolog" 2>&1; then
		log "pkg repo: catalog generated in $OUTDIR"
		log "pkg repo: UNSIGNED, by explicit NESTED_ALLOW_UNSIGNED=1"
		rm -f "$_repolog"
	else
		log "ERROR: 'pkg repo $OUTDIR' failed -- no catalog was written, so"
		log "       pkg update and pkg install will see an empty repository"
		if [ -s "$_repolog" ]; then
			sed 's/^/       pkg: /' "$_repolog"
		fi
		exit 1
	fi
fi

# pkgbase: ${REPODIR}/${ABI}/latest -> version directory (Makefile.inc1).
ln -sfn "$VERSION" "${PKGDIR}/${ABI}/${CHANNEL}"

# Stable, version-independent package filenames so published install URLs do not
# change every build (e.g. .../latest/CloudBSD-bhyve.pkg).
for _p in "${PKG_NAME_PREFIX}-kernel-generic" "${PKG_NAME_PREFIX}-bhyve"; do
	_f=$(cd "$OUTDIR" && ls "${_p}"-*.pkg 2>/dev/null | head -1)
	[ -n "$_f" ] && ln -sfn "$_f" "${OUTDIR}/${_p}.pkg"
done

log "packages:"
ls -lh "$OUTDIR"/"${PKG_NAME_PREFIX}"-*.pkg
log "channel pointer: ${PKGDIR}/${ABI}/${CHANNEL} -> $VERSION"
log "DONE git=$GITREV (base packages only; not installed on other hosts)"
