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
| Builders | builder pool: lock ONE resource labelled `poudriere-amd64-builders` (`poudriere-amd64-<node>`: freedev005, freedev006), then run on that node |
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
3. **Build**, unprivileged, niced, with memory-capped parallelism:
   `make -j<N> buildworld buildkernel` then
   `make -j<min(N,8)> packages PKG_CTHREADS=2 PKG_VERSION=<MAJOR>.snap<UTC timestamp> REPODIR=/var/db/pkgbase-export`.
   N is `MAKE_JOBS`, or with 0 (default) min(cores/2, RAM GiB/4): 31 on a
   64-core/128G builder. `LLVM_TARGETS=host-only` (default) adds
   `WITHOUT_LLVM_TARGET_ALL=yes`; `all` builds every LLVM target like
   pkg.FreeBSD.org
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

The build takes a builder from the pool (cloudbsd-ci `jenkins/casc/jenkins.yaml`,
Track #396): it locks whichever `poudriere-amd64-<node>` resource is free, then
runs on that node. It therefore never shares a builder with a poudriere bulk and
never waits on a busy builder while another is idle.

**Memory.** freedev005 also hosts the Jenkins controller jail. On 2026-09-29 the
first run (`-j64` world, then `make packages` at `-j64` with the default
`PKG_CTHREADS=0`, one zstd thread per core in every `pkg create`) ran freedev005
out of swap, and the OOM killer took the controller. That is why the job never
uses every core, and why packaging runs few jobs with two compression threads
each. Do not raise `MAKE_JOBS` towards the core count.

## Publishing

### `PUBLISH_VIA=pkgrepo-node` (default)

The `Publish: pkgrepo node` stage runs on the `pkgrepo` Jenkins agent, which
lives INSIDE the pkgrepo jail on freedev008 (cloudbsd-ci #46, Track #396
option B; no agent on the host, no broad root). The build stage stashes the
package list and `publish-pkgrepo.sh` (the jail has no git). The script checks
the list against the build's record, then runs the agent's one doas rule for
base:

```sh
doas -n /usr/local/sbin/publish-internal-repo.sh -H <builder> -a FreeBSD:16:amd64 -B < ci-artifacts/pkgbase-packages.txt
```

As root, `publish-internal-repo.sh -B` (cloudbsd-ci #49) pulls exactly those
files from the builder's fixed export directory
`/var/db/pkgbase-export/FreeBSD:16:amd64/latest` (root's `pkghandoff-<builder>`
SSH alias, landing on the builder's unprivileged `pkghandoff` account) into a
root-only staging directory. It refuses anything that is not a base package
(origin `base/*`, name `FreeBSD-*`) and refuses downgrades. It publishes into
`base_latest` only and checks the regenerated catalogue. `publish-pkgrepo.sh`
then re-reads the catalogue as the agent and requires every package at this
version, including runtime, kernel-generic, utilities and rc. The signing key
never leaves the jail and is not readable by the agent.

One-off setup (done 2026-09-30):

- on each builder, as root: `install -d -o jenkins -g jenkins -m 0755 /var/db/pkgbase-export`
  (the build's `REPODIR`; the workspace itself is not readable by `pkghandoff`);
- in the pkgrepo jail's `/usr/local/etc/doas.conf`, one rule per builder:
  `permit nopass jenkins as root cmd /usr/local/sbin/publish-internal-repo.sh args -H <builder> -a FreeBSD:16:amd64 -B`.

### `PUBLISH_VIA=manual-handoff` (EMERGENCY ONLY)

Hand-publishing is deprecated. Use this only while the `pkgrepo` agent is down.
The job prints the commands and waits at an input gate (`HANDOFF_WAIT_HOURS`,
no executor held). On **freedev008**, as an operator with sudo on both hosts:

```sh
V=<version from the build description>          # e.g. 16.snap20260929130756
B=<builder from the build description>          # freedev005 or freedev006
SRC=/var/db/pkgbase-export/FreeBSD:16:amd64/$V
STAGE=/var/db/pkgbase-handoff/$V
sudo install -d -o root -g wheel -m 0755 "$STAGE"
ssh $B.cloudbsd.org "sudo tar -C '$SRC' -cf - ." | sudo tar -C "$STAGE" -xf -
sudo /usr/local/sbin/publish-internal-repo.sh -s "$STAGE" \
    -d /usr/local/bastille/jails/pkgrepo/root/usr/local/www/pkgrepo/FreeBSD:16:amd64/base_latest
```

Wait for `PUBLISH_OK`, check the count against `ci-artifacts/pkgbase-packages.txt`,
then answer the input gate.

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
