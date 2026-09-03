# Nested-virt test artifacts (T51)

This document is the build runbook for the artifacts used by
`tests/sys/vmm/nested/`. All binaries live under
`/usr/tests/sys/vmm/nested/fixtures/` on the FreeBSD test host
(`mlapointe@172.16.176.131`); they are NOT committed to git.

## Artifact index

| # | Name | Source | Pinned tag | Storage path |
|---|------|--------|------------|--------------|
| 1 | `NESTED-DEBUG` kernel | `sys/amd64/conf/NESTED-DEBUG` (this branch) | `main` HEAD | `/boot/kernel.NESTED-DEBUG/` |
| 2 | mfsBSD L2 test image | https://github.com/mmatuska/mfsbsd | `mfsbsd-2.3` | `/usr/tests/sys/vmm/nested/fixtures/l2_test.img` |
| 3 | OVMF UEFI firmware | https://github.com/tianocore/edk2 | `edk2-stable202408` | `/usr/tests/sys/vmm/nested/fixtures/OVMF_CODE.fd` and `OVMF_VARS.fd` |
| 4 | Alpine Linux guest | https://alpinelinux.org/downloads/ | `3.20` (virt flavor) | `/usr/tests/sys/vmm/nested/fixtures/l2_linux.img` |
| 5 | (DEFERRED v2) Test-harness L1 image | -- | -- | -- |

## Artifact 1: `NESTED-DEBUG` kernel config

`sys/amd64/conf/NESTED-DEBUG` is the L0 host kernel config used
during nested-virt development and validation. It enables:

```
options INVARIANTS
options INVARIANT_SUPPORT
options WITNESS
options WITNESS_SKIPSPIN
options DEBUG_VMM
options KTR
options KTR_COMPILE
options KTR_MASK
options DDB
options CTF
makeoptions DEBUG=-g
```

Build on the FreeBSD 16.0-CURRENT test host:

```sh
cd /usr/src
sudo make -C sys/amd64/compile/NESTED-DEBUG buildkernel
sudo make -C sys/amd64/compile/NESTED-DEBUG installkernel
```

Switch kernel in `/boot/loader.conf`:

```
kernel="kernel.NESTED-DEBUG"
```

Reboot and verify:

```sh
uname -v                                # expect "NESTED-DEBUG"
sudo sysctl kern.conftxt | grep INVARIANTS
```

Storage: `/boot/kernel.NESTED-DEBUG/` (~50 MB).

## Artifact 2: mfsBSD L2 test image

Build host: FreeBSD 16.0-CURRENT (or any FreeBSD >= 13.x).

```sh
git clone --branch mfsbsd-2.3 https://github.com/mmatuska/mfsbsd /usr/local/mfsbsd
cd /usr/local/mfsbsd
sudo make BASE=14.0-RELEASE
```

Customisations to add to the image (per the plan):

* Install from pkg: `sysbench`, `fio`, `iperf3`
* Base utilities: `dtrace`, `ktrace`, `kdump`
* Add an autorun script at `/etc/rc.d/test_smoke` that runs
  sysbench / fio / dtrace sanity and prints
  `ALL TESTS PASSED` or `TESTS FAILED: ...` to the serial console

Storage: `/usr/tests/sys/vmm/nested/fixtures/l2_test.img`
(~50 MB compressed, ~200 MB uncompressed).

Used by: T45 (I/O workload), T48 (soak), T52a/T52b (exit plumbing
+ stress), and as the default image for the non-EFI smoke test in
`scripts/run_l2_smoke.sh`.

Verify: `file /usr/tests/sys/vmm/nested/fixtures/l2_test.img`

## Artifact 3: OVMF UEFI firmware

Build host: any amd64 host with edk2 toolchain (BaseTools, GCC5
cross compiler).

```sh
git clone --branch edk2-stable202408 https://github.com/tianocore/edk2
cd edk2
make -C BaseTools/
source edksetup.sh
build -p OvmfPkg/OvmfPkgX64.dsc -t GCC5 -a X64 -b RELEASE
```

Output: `Build/OvmfX64/RELEASE_GCC5/FV/OVMF_CODE.fd` and
`OVMF_VARS.fd` (~1 MB each).

Storage: `/usr/tests/sys/vmm/nested/fixtures/OVMF_CODE.fd` and
`OVMF_VARS.fd`.

Used by: T50 (UEFI boot test) and T47 (L3 OVMF boot). The default
T51 smoke path uses BIOS/legacy boot (no OVMF) so this artifact is
NOT required for the T51 smoke test.

Verify: `file /usr/tests/sys/vmm/nested/fixtures/OVMF_CODE.fd`

## Artifact 4: Alpine Linux guest

Download the virt flavor ISO from
https://alpinelinux.org/downloads/ (pinned to 3.20).

```sh
fetch https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-virt-3.20.0-x86_64.iso
cp alpine-virt-3.20.0-x86_64.iso /usr/tests/sys/vmm/nested/fixtures/l2_linux.img
```

Storage: `/usr/tests/sys/vmm/nested/fixtures/l2_linux.img`
(~30 MB compressed, ~200 MB uncompressed).

Used by: T38 (KVM parity: run L1=KVM with L2=Linux, compare to
FreeBSD L2 output), T50 (CPU feature virt Linux side).

Verify: `qemu-img info /usr/tests/sys/vmm/nested/fixtures/l2_linux.img`

## Artifact 5 (DEFERRED to v2): test-harness L1 image

A self-contained L1 image that includes patched bhyve. For v1 we
use the L0 host as the L1 (already the case per design). The
self-contained harness is deferred to v2 to keep CI runtimes short.

## What this commit ships

This commit ships:

* `tests/sys/vmm/nested/scripts/run_l2_smoke.sh` -- non-EFI smoke
  driver that boots mfsBSD, captures text via serial console,
  parses for PASS/FAIL markers.
* `tests/sys/vmm/nested/scripts/build_artifacts.sh` -- build
  helper that enumerates the three artifact build commands.
* `tests/sys/vmm/nested/README.artifacts.md` -- this runbook.
* `sys/amd64/conf/NESTED-DEBUG` -- debug kernel config (versioned
  in git per the plan).

This commit does NOT ship the binaries themselves; they are built
on-demand by the test host per the build commands above.

## What is NOT shipped

* The mfsBSD image (`l2_test.img`).
* The OVMF firmware (`OVMF_CODE.fd`, `OVMF_VARS.fd`).
* The Alpine Linux image (`l2_linux.img`).
* The compiled NESTED-DEBUG kernel (`kernel.NESTED-DEBUG`).

These are built on the FreeBSD test host using the pinned source
tags above. Never commit binaries to the FreeBSD source tree.

## Troubleshooting

* **mfsBSD doesn't print PASS/FAIL markers** -- check that the
  autorun script is at `/etc/rc.d/test_smoke` and chmod 755.
  Verify it is enabled by checking `/etc/rc.conf` for
  `test_smoke_enable="YES"`.
* **OVMF build fails with "BaseTools not found"** -- run
  `make -C BaseTools/` before sourcing `edksetup.sh`.
* **NESTED-DEBUG kernel won't boot** -- ensure the GENERIC kernel
  is still installed as `/boot/kernel` so you can fall back from
  the loader prompt.
* **L2 panics immediately** -- confirm `hw.vmm.nested.enable=1` is
  in `/etc/sysctl.conf` and `vmm.ko` is loaded.