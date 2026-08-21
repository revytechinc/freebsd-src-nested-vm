# Nested Virtualization Deployment Safety

This document describes the **boot-time safety flow** for hosts running
bhyve nested-virt development kernels.

> **WARNING — production systems**: Do **not** apply these settings to
> production hosts. Auto-reboot on panic and disabling vmm auto-load are
> appropriate for development only; production should retain DDB so an
> operator can investigate panics, and should allow vmm auto-load so VMs
> survive reboot.

## Why these guardrails exist

Nested-virt register virtualization introduces new failure modes (kernel
panics on malformed VMCS12/VMCB12, host-state leaks on partial exits, etc.)
that an unsuspecting operator might not be able to recover from without
physical or IPMI access. To make a test host **recoverable** from a
nested-virt **panic or hang**, we configure:

1. **Power-cycle on panic** — `debug.debugger_on_panic=0` and
   `kern.powercycle_on_panic=1`. Do not sit in DDB. A reboot without a
   power-cycle is not enough on a wedged box.
2. **Watchdog on hang** — a hang that never panics (no ARP, SSH
   `No route to host`, box still "up" on the chassis) will not fire
   panic-reboot. `watchdogd` resets onto the known-good `bootfs`.
3. **One-shot BE** — `bectl activate -t` only. **Never**
   `zpool set bootfs` to the candidate. The loader consumes bootonce;
   the next reset returns to the previous `bootfs`.
4. **No vmm auto-load at boot** — the operator must explicitly
   `kldload vmm` after verifying the kernel boots cleanly. A broken vmm
   cannot lock the box at boot.

freedev008 (2026-08-21) did **not** fit this pattern: ARP incomplete from
every lab peer, so the kernel never paniced (hang/NIC dead). Panic-reboot
never ran. If `bootfs` was also pointed at the candidate, a later reset
would have come back into the same kernel. Fix: oneshot BE + powercycle +
watchdog; recover 008 with one chassis/IPMI power cycle, then pick the
known-good BE at the loader if `bootfs` was flipped.

## Scripts

Both scripts are idempotent: they test for the desired state and only
append when missing.

### `scripts/disable-panic-debugger.sh`

Idempotently appends these lines to `/etc/sysctl.conf`:

```
debug.debugger_on_panic=0
kern.panic_reboot_wait_time=5
```

The `kern.panic_reboot_wait_time` value of 5 seconds gives the kernel
enough time to flush panic messages to the console before rebooting.
The exact sysctl name is verified in `sys/kern/kern_shutdown.c:108`.

### `scripts/disable-vmm-autoload.sh`

Idempotently appends this line to `/boot/loader.conf`:

```
vmm_load="NO"
```

Without this, the loader auto-loads `vmm.ko` if any consumer references
it during boot.

## VM boot gate (before any metal install)

`scripts/run_vm_boot_gate.sh` boots the candidate GENERIC kernel as a
**bhyve guest** on a hypervisor that already has a known-good `vmm.ko`.
PASS is kernel ident + `Timecounter` / `mountroot>` / `login:` on the
guest serial console. Nested sysctls may be missing or 0.

Never `kldload` the candidate `vmm.ko` on the hypervisor. Never install
the candidate into a boot environment until this gate prints
`VM BOOT GATE: PASS`.

```sh
sudo env NESTED_GATE_KERNEL=/path/to/GENERIC/kernel \
    NESTED_TEST_DRIVER=force-run \
    ./tests/sys/vmm/nested/scripts/run_vm_boot_gate.sh
```

## Boot-time safety flow

The intended operator sequence for a freshly-patched test host:

0. **VM boot gate** (`scripts/run_vm_boot_gate.sh`). Does the candidate
   kernel boot as a guest? Nested features are not required.
1. **Boot with patched kernel** on metal (only after step 0 PASSes).
   Does the kernel boot? (vmm is not yet loaded.)
2. **Verify boot OK** via console or IPMI.
3. `sudo kldload vmm`. Does vmm load OK? (still no nested yet.)
4. `sudo sysctl hw.vmm.nested.enable=1`. Enables nested-virt code paths.
5. `sudo kldload svm_nested_test` (or `vmx_nested_test` on Intel). Runs
   the nested test module.

If any step fails, the system remains bootable and vmm-free. The
operator can debug from a known-good state without IPMI access.

## Live-load verification

```sh
ssh mlapointe@<host>
sudo kldstat -n vmm         # should be empty when not loaded
sudo sysctl debug.debugger_on_panic     # should print 0
sudo sysctl kern.panic_reboot_wait_time # should print 5 (or higher)
grep vmm_load /boot/loader.conf         # should print vmm_load="NO"
```

## KBI safety net

Two layers of opt-in keep nested-virt **off by default**:

1. **`hw.vmm.nested.enable` defaults to 0**. The runtime tunable is the
   global gate; with `vmm_nested_enable == 0`, no nested-virt code path
   runs regardless of which VM is created.
2. **`vm->nested_enabled` defaults to false** on every new VM. Even if
   the sysctl is on, an L1 must be created with `VMMCTL_CREATE_NESTED`
   (kernel) or `VMMAPI_OPEN_CREATE_NESTED` (libvmmapi) to enable per-VM
   nesting.

Both gates compose. Operators who only want normal bhyve VMs are
unaffected by the nested code paths entirely.

## ATF verification

`deployment_safety.sh` (in this directory) is an ATF test that asserts:

* `debug.debugger_on_panic == 0`
* `/boot/loader.conf` contains `vmm_load="NO"`
* Both scripts and the man page exist and are executable

Run on a test host via:

```sh
cd /usr/tests/sys/vmm/nested && kyua test deployment_safety
```

## References

* Plan: `.sisyphus/plans/nested-virt-register-virtualization.md` task T0b
* Man page: `share/man/man9/vmm_nested.9`
* Spec: `tunables(9)`, `loader.conf(5)`, `sysctl(8)`