# CloudBSD CI: FreeBSD base (pkgbase) from this tree

Track #399. The FreeBSD base system for the fleet is built from THIS tree and
published by Jenkins, not by hand and not by freebsd-update. The pipeline is
the repository-root `Jenkinsfile`; Jenkins discovers it through the GitHub
organization folder `github-revytechinc` (repository topic `cloudbsd-ci`,
branch `main`), so nothing about this job lives in cloudbsd-ci. Automatic
builds are suppressed: start it from Jenkins (`github-revytechinc` ->
`freebsd-src-nested-vm` -> `main` -> Build with Parameters).

| What | Where |
|------|-------|
| Job | `github-revytechinc/freebsd-src-nested-vm/main` (org-folder discovered; pipeline: `/Jenkinsfile`) |
| Scripts | `tools/cloudbsd-ci/pkgbase/{stamp,preflight,build,record,publish-pkgrepo}.sh` |
| Source | this repository, the branch being built (`main`) |
| Builders | label `poudriere-amd64` (freedev005, freedev006), lock `poudriere-amd64-${NODE_NAME}` |
| Repository | InternalPkg `https://pkg.internal.revytechinc.com/FreeBSD:16:amd64/base_latest/` |
| On disk | freedev008 `/usr/local/bastille/jails/pkgrepo/root/usr/local/www/pkgrepo/FreeBSD:16:amd64/base_latest` |
| Client snippet | cloudbsd-ci `pkg/repos/internal-base.conf` -> `/usr/local/etc/pkg/repos/internal-base.conf` |

## Why this source tree

This tree (`revytechinc/freebsd-src-nested-vm` @ `main`) is what the nested VMs
build from: cloudbsd-ci's `cloudbsd-nested-media` job checks it out
(`nested-checkout.sh`: `NESTED_URL`/`NESTED_REF` defaults). `cloudbsdorg/cloudbsd-src`
also exists, but nothing in the nested pipeline builds from it.

## What the job does

1. **Checkout** (Jenkins, shallow clone per the org folder), then `stamp.sh`
   records the commit and refuses a dirty tree.
2. **Preflight**: FreeBSD/amd64, pkg installed, >= 80G free, prints the tree's
   `__FreeBSD_version` against the host's `kern.osreldate`.
3. **Build**, unprivileged, niced, every core:
   `make buildworld buildkernel` then
   `make packages PKG_VERSION=<MAJOR>.snap<UTC timestamp> REPODIR=${WORKSPACE}@pkgbase/repo`
   (objects in `${WORKSPACE}@pkgbase/obj`, outside the tree).
   Host `/etc/src.conf`, `/etc/make.conf`, `/etc/src-env.conf` are ignored
   (`SRCCONF=/dev/null` ...), so both builders produce the same set.
   Package names are FreeBSD's own (`FreeBSD-runtime`, `FreeBSD-kernel-generic`,
   ...), and the version format is FreeBSD's own snapshot format, so an
   upgrade from pkg.FreeBSD.org's base_latest to ours is an ordinary upgrade.
4. **Record**: package list, SHA256, version, commit, OSVERSION, builder and
   path, archived as build artifacts (not the packages: ~1-2G per build).
   Refuses an incomplete set (runtime, kernel-generic, utilities, rc must exist,
   every package must carry the build's version).
5. **Publish** (`PUBLISH=true`), into `<ABI>/base_latest`, signed with the
   existing InternalPkg key on freedev008. The key never leaves the pkgrepo
   jail and this job never reads it.

The world build holds the node's build lock, so it serialises with poudriere
on the same builder and leaves the other builder free.

## Publishing

### `PUBLISH_VIA=handoff` (default until a `pkgrepo` node exists)

The job prints the exact commands and waits at an input gate
(`HANDOFF_WAIT_HOURS`, no executor held). On **freedev008**, as an operator with
sudo on both hosts:

```sh
V=<version from the build description>          # e.g. 16.snap20260929083000
B=<builder from the build description>          # freedev005 or freedev006
SRC=<pkgdir from ci-artifacts/pkgbase-build.properties>   # <workspace>@pkgbase/repo/FreeBSD:16:amd64/$V
STAGE=/var/db/pkgbase-handoff/$V
sudo install -d -o root -g wheel -m 0755 "$STAGE"
ssh $B.cloudbsd.org "sudo tar -C '$SRC' -cf - ." | sudo tar -C "$STAGE" -xf -
sudo /usr/local/sbin/publish-internal-repo.sh -s "$STAGE" \
    -d /usr/local/bastille/jails/pkgrepo/root/usr/local/www/pkgrepo/FreeBSD:16:amd64/base_latest
```

The tar stream is written by root into a root-owned directory; the packages
never pass through a workspace on the repository host. Wait for `PUBLISH_OK`,
check the count against `ci-artifacts/pkgbase-packages.txt`, then answer the
input gate. The staging directory can be removed after verification.

### `PUBLISH_VIA=pkgrepo-node`

When a Jenkins node carries the `pkgrepo` role label (Track #396), the
`Publish: pkgrepo node` stage runs `publish-pkgrepo.sh` there (read with `readTrusted`, no checkout): the same
root-to-root pull (as the ports handoff does), a count check against the
build's record, `publish-internal-repo.sh -d .../base_latest`, and a catalogue
check. It needs the same root ssh from the repo host to the builders and the
same doas rules the ports handoff needs. Flip the default of `PUBLISH_VIA` in the
Jenkinsfile once that node is live.

### Bootstrap (one-off, done 2026-09-29)

`publish-internal-repo.sh` refuses a destination without `meta.conf` (the guard
that catches a mistyped `-d`), and `pkg repo` refuses an empty directory ("No
package files have been found"). The base repository was therefore created
once, on freedev008 as root, owned like `latest`, by copying `latest`'s
`meta.conf` (repository format only, no package data); the first publish
generated the signed catalogue:

```sh
R=/usr/local/bastille/jails/pkgrepo/root/usr/local/www/pkgrepo/FreeBSD:16:amd64
install -d -o root -g wheel -m 0755 $R/base_latest
cp -p $R/latest/meta.conf $R/base_latest/meta.conf
```

### Pruning

Publishing adds; it does not replace. Old snapshot versions accumulate in
`base_latest` (clients only take the newest). Prune by removing older
`FreeBSD-*-<old version>.pkg` files and re-running
`publish-internal-repo.sh` (or `pkg repo <dir> <key>`) on freedev008. Keep at
least the previous set so a host can still reinstall what it runs.

## Verifying a publish

```sh
# catalogue + packages present (from any fleet host with the client cert)
sudo fetch -o - https://pkg.internal.revytechinc.com/FreeBSD:16:amd64/base_latest/meta.conf
# without installing anything: a repo dir holding only the snippet and a
# scratch package database, so the host's own pkg state is never touched
d=$(mktemp -d); db=$(mktemp -d)
cp /usr/local/etc/pkg/repos/internal-base.conf $d/   # cloudbsd-ci pkg/repos/internal-base.conf
sudo pkg -R $d -o PKG_DBDIR=$db update -f -r InternalPkgBase
sudo pkg -R $d -o PKG_DBDIR=$db rquery -r InternalPkgBase '%n-%v' FreeBSD-runtime FreeBSD-kernel-generic
sudo rm -rf $d $db
```

## Upgrading a host that already runs pkgbase

Fleet hosts (freedev005/006/008 at the time of writing) already run pkgbase
from pkg.FreeBSD.org `FreeBSD-base`. To move one to the CI-built base:

1. `bectl create pre-internalbase-$(date +%Y%m%d)` (and check it is listed).
2. Install cloudbsd-ci `pkg/repos/internal-base.conf` as
   `/usr/local/etc/pkg/repos/internal-base.conf`; set
   `FreeBSD-base: { enabled: no }` in `/usr/local/etc/pkg/repos/FreeBSD.conf`.
3. `pkg update -r InternalPkgBase && pkg upgrade -n -r InternalPkgBase` and
   read the plan. pkg's `CONSERVATIVE_UPGRADE` keeps packages with the repo
   they came from, so the first move names the repository explicitly.
4. `pkg upgrade -r InternalPkgBase`, merge `*.pkgnew` / `*.pkgsave` under
   `/etc`, reboot, check `freebsd-version -ku`, `uname -a`.
5. Roll back with `bectl activate <pre-...> && reboot` if anything is wrong.

**OSVERSION (Track #283 -- Mark's open decision, not decided here).** Base
from `main` declares the tree's `__FreeBSD_version` (1600026 at the first
build). pkg refuses packages newer than the running system
("Newer FreeBSD version for package ...") unless `IGNORE_OSVERSION=yes`,
which is exactly what a base upgrade across a version bump needs -- and exactly
what #283 is deciding for the product jails (hawkeye jail 1600019/1600024; the
poudriere jail is 1600025). Do not upgrade the hawkeye product jail or any
other product jail from this repository until #283 is decided.

## Moving a non-pkgbase host to pkgbase

Risky: pkg takes ownership of every base file, `/etc` files are replaced by
package versions (your edits land in `*.pkgsave`), and a mismatch between the
running kernel and the new userland can leave a host that does not boot.
Nothing converts fleet hosts automatically; do one host at a time, with Mark's
go for anything in production.

1. Only from a matching release line: the host's `freebsd-version -u` should
   be the same branch (16-CURRENT) and not newer than the repository.
2. Boot environment first: `bectl create pre-pkgbase-$(date +%Y%m%d)`.
   ZFS-on-root hosts only; a UFS host needs a full backup instead.
3. Back up `/etc`, `/boot/loader.conf`, `/usr/local/etc` (a tarball off-host).
4. Install `internal.conf`-style trust (the `internal-repo.pub` key and pkg_env
   client cert already exist on fleet hosts) and `internal-base.conf`.
5. Use the FreeBSD conversion tool rather than hand-installing packages:
   `pkgbasify` (https://github.com/FreeBSDFoundation/pkgbasify), pointed at the
   `InternalPkgBase` repository; it installs the matching `FreeBSD-*` set,
   preserves `/etc/master.passwd`, `/etc/group`, `/etc/ssh/*`, and runs
   `pwd_mkdb`/`cap_mkdb`. Read its plan before confirming.
6. Before rebooting: `pkg check -s -a` (checksums), `diff` the `*.pkgsave`
   files under `/etc` and restore local edits, confirm `/boot/kernel/kernel`
   is from `FreeBSD-kernel-generic`.
7. Reboot into the converted BE; on failure `bectl activate pre-pkgbase-...`.
8. Jails: convert the host first; jails are converted separately
   (`pkg -j <jail>` / `pkg -r <jailroot>`), never implicitly with the host.
