# Legacy AMD bring-up — straight into the matrix

The one real coverage gap. freedev005 and freedev006 are both EPYC 7551 (Zen 1),
so they test the same silicon twice. A pre-Zen AMD part is the only way to test
the **AMD floor** rather than assume it, the way Ivy Bridge does for Intel.

## 1. Does the part even qualify — check before anything else

The floor is **NPT plus NRIP save**. Family 10h introduced NPT in 2007, but
early Barcelona silicon shipped without NRIP save and plain bhyve already
refuses those. K8 (Family 0Fh) has SVM but no nested paging at all.

```sh
sysctl hw.model
dmesg | grep -E 'Family=|Model=|Features'
cpucontrol -i 0x8000000a /dev/cpuctl0     # NPT / NRIP-save bits
```

If it does not qualify, that is still a **useful result** — it is a real data
point for the "will it run on your CPU?" section, which currently marks early
Family 10h and Family 11h as unverified. Record it either way.

## 2. Bring it up like any other test host

Order matters; see the `bectl-safe-deploy` skill.

1. Confirm it is current with the shipped build, or deploy through a boot
   environment activated **one-shot**.
2. `MAKEOBJDIRPREFIX` goes in the **environment**, never as a make command-line
   variable — otherwise `installkernel` silently installs the wrong kernel.
   **Verify by sha256**, not by exit status. This bit us on freedev005.
3. Arm the candidate BE with `ROOT=<mnt>`: `disable-panic-debugger.sh`,
   `enable-fail-watchdog.sh`, `disable-vmm-autoload.sh`. Arm the running system
   too, so *this* reboot is protected.
4. `pkg install bhyve-firmware` — the file `BHYVE_UEFI.fd` must be
   package-owned. A hand-placed copy is how a demo host ended up with a file
   nothing owned.
5. `kldload vmm`, then confirm `hw.vmm.nested.enable=1` and
   `hw.vmm.nested.svm=1`. A `0` means the preflight gate refused the CPU —
   which is the answer from step 1, arriving late.

## 3. Images, then the run

```sh
git clone https://github.com/michaeldexter/occambsd.git ~/occambsd
doas sh build_layer_images.sh -n 2 -g 15 -O ~/nested-layers
doas env IMAGEDIR=~/nested-layers CPUS=2 sh run_layer_stack.sh
```

One ZFS pool name per layer — identical image copies collide on pool names and
GPT labels, and the failures impersonate hypervisor bugs.

**Check the harness version matches the other hosts before comparing results.**
A stale `run_layer_stack.sh` on one host made an AMD result non-comparable with
the Intel ones and nobody noticed until a second session diffed them.

## 4. Two things specific to this machine

- **It is old and can be flaky mid-test.** Handle that gracefully — a wedge
  here is likelier to be the hardware than the hypervisor. This instability is
  an internal note and **must not be published**.
- **The site has a placeholder card for it** (`CloudBSD SVM·Legacy`, marked
  "coming"). Once it runs, replace the placeholder with the real CPU, family,
  core count and RAM, and state what it uniquely exercises. Until then leave the
  card as it is — do not claim coverage that has not happened.
