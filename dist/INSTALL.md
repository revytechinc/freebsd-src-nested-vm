# Wave-7 v2.0 install guide (multi-arch)

## What's in this bundle
- `kernel.amd64` — FreeBSD GENERIC kernel with wave-3+5+6+7 patches
- `vmm.ko.amd64` — bhyve module with wave-3+5+6+7 nested-virt support
- `preflight.sh` — runtime CPU/host topology probe (BSD-2-Clause)
- `tests/sys/vmm/nested/hw/preflight/` — 17 regression tests (12 PASS, 5 SKIP root-gated)

## Compatibility
- Verified on:
  - AMD Zen 5 (Ryzen AI 9 HX 370) running under VMware L0 (nVMX filtered)
  - Intel Ivy Bridge (i7-3770S) bare metal (VMCS-shadowing absent = BLOCKED)

## Install on a FreeBSD 16.0-CURRENT host

```sh
# 1. Drop into a new boot environment via bectl
sudo bectl create wave7-preflight
sudo bectl mount wave7-preflight /tmp/be
sudo cp kernel.amd64 /tmp/be/boot/kernel/kernel
sudo mkdir -p /tmp/be/boot/modules
sudo cp vmm.ko.amd64 /tmp/be/boot/modules/vmm.ko
sudo bectl umount wave7-preflight
sudo bectl activate -t wave7-preflight

# 2. Reboot into the new kernel
sudo shutdown -r +1 "wave-7 install"

# 3. After boot, verify
uname -v                                # should show the wave-7 build
sudo kldload /boot/modules/vmm.ko        # or autoload via /boot/loader.conf
sysctl hw.vmm.nested.enable hw.vmm.nested.vmx hw.vmm.nested.svm
# Expected on Haswell+ / Zen 2+: nested.{vmx,svm} = 2 (all gates clear)

# 4. Run preflight
PREFLIGHT_DMESG=/var/run/dmesg.boot sh /boot/scripts/preflight.sh
# Or copy preflight.sh into /usr/local/bin/

# 5. Run regression tests
cd /usr/tests/sys/vmm/nested/hw/preflight
sudo bash run_preflight_tests.sh
# Expected: 12/17 PASS, 5 SKIP root-gated, 0 FAIL
```

## What's new in this kernel
- wave-3: SYSCTL_CREATE_NESTED `VMMCTL_CREATE_NESTED`, `VMMAPI_OPEN_CREATE_NESTED`, `hw.vmm.nested.enable`, `hw.vmm.nested.vmx`, `hw.vmm.nested.svm`
- wave-5: VMCS shadowing (per-VM after VMPTRLD), VMCLEAR/VMLAUNCH/VMRESUME/VMCALL, VMCS12 state machine
- wave-6: T18-T23b real nVMX launch path (VMPTRLD with GPA translation, EPT12 walker, VMREAD/VMWRITE, INVEPT/INVVPID)
- wave-7: tools/preflight.sh v2.0 with audit-driven architecture detection

## Rollback
```sh
sudo bectl activate cloudbsd-20260722
sudo shutdown -r +1 "rollback"
```

## Performance baseline (post-patch sysbench cpu --cpu-max-prime=20000)
Captured 2026-08-12 on AMD Zen 5 HX 370:
- Single-thread: 7.78M-8.00M events/s (mean 7.84M)
- Multi-thread (8 cores): 39.4M-40.2M events/s (mean 39.8M)

