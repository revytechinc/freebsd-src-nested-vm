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
nested-virt panic, we configure:

1. **Auto-reboot on panic** — kernel panics reboot instead of dropping
   into DDB.
2. **No vmm auto-load at boot** — the operator must explicitly
   `kldload vmm` after verifying the kernel boots cleanly. A broken vmm
   cannot lock the box at boot.

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

## Boot-time safety flow

The intended operator sequence for a freshly-patched test host:

1. **Boot with patched kernel**. Does the kernel boot? (vmm is not yet
   loaded.)
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