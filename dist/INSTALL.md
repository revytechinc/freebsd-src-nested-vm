# Wave-7 v2.0 install guide (multi-arch)

## What's in this bundle

After extracting `wave7-preflight-multiarch.tar.zst`:

```
kernel.amd64       FreeBSD GENERIC kernel with wave-3+5+6+7 patches
vmm.ko.amd64       bhyve module with wave-3+5+6+7 nested-virt support
preflight.sh       runtime CPU/host topology probe (BSD-2-Clause)
nested/            117 test/probe scripts from the source tree
INSTALL.md        this file
```

When extracted, the layout is:

```
./                                              (current directory after extract)
├── kernel.amd64
├── vmm.ko.amd64
├── preflight.sh
├── nested/
│   └── ... (test files)
└── INSTALL.md
```

## Compatibility

Verified on:

- AMD Zen 5 (Ryzen AI 9 HX 370) running under VMware L0 (nVMX filtered, nSVM confirmed)
- Intel Ivy Bridge (i7-3770S) bare metal (nVMX correctly BLOCKED due to missing VMCS shadowing)

## VM boot gate (mandatory before metal)

Do **not** install `kernel.amd64` or `vmm.ko.amd64` on bare metal until the
candidate has booted as a **bhyve guest**. Nested features are not required
for this gate — a serial console that shows `FreeBSD x.y-CURRENT` and
`Timecounter` (or `mountroot>` / `login:`) is enough. A panic after those
markers (for example missing `/sbin/init` on the throwaway UFS image) is
still a boot PASS.

The hypervisor host must already run a known-good `vmm.ko`. Never `kldload`
the candidate module on the hypervisor.

```sh
# On a FreeBSD hypervisor that already has working bhyve (not the target BE).
# Copy the candidate kernel into place, then:
sudo env NESTED_GATE_KERNEL=/path/to/kernel.amd64 \
    NESTED_GATE_VMM_KO=/path/to/vmm.ko.amd64 \
    NESTED_TEST_DRIVER=force-run \
    ./tests/sys/vmm/nested/scripts/run_vm_boot_gate.sh
# Expected: VM BOOT GATE: PASS
# Classifier-only (any OS): ./tests/sys/vmm/nested/scripts/run_vm_boot_gate.sh selftest
```

If the gate FAILs, stop. Do not `bectl create`, do not set `bootfs`, do not
reboot a lab host into the candidate.

## Install on a FreeBSD 16.0-CURRENT host

Only after **VM BOOT GATE: PASS**:

```sh
# 0. Extract the bundle somewhere safe (NOT under /boot)
tar --zstd -xf wave7-preflight-multiarch.tar.zst -C /tmp/wave7
cd /tmp/wave7

# 1. Create a new boot environment (bectl snapshot)
sudo bectl create wave7-preflight

# 2. Mount the new BE and install the wave-7 kernel + vmm.ko
sudo bectl mount wave7-preflight /tmp/be
sudo install -m 555 kernel.amd64 /tmp/be/boot/kernel/kernel
sudo install -m 555 vmm.ko.amd64   /tmp/be/boot/kernel/vmm.ko
sudo bectl umount wave7-preflight

# 3. Install preflight.sh into PATH (NOT into /boot - /boot is reserved for boot files)
sudo install -m 755 preflight.sh /usr/local/bin/preflight

# 4. Activate the new BE
sudo bectl activate -t wave7-preflight

# 5. Reboot
sudo shutdown -r +1 "wave-7 install"

# 6. After boot, verify
uname -v                                # should show the wave-7 build
sudo kldload /boot/kernel/vmm.ko       # autoload via /boot/loader.conf if preferred
sysctl hw.vmm.nested.enable hw.vmm.nested.vmx hw.vmm.nested.svm
# Expected on Haswell+ / Zen 2+: nested.{vmx,svm} = 2 (all gates clear)

# 7. Run preflight
PREFLIGHT_DMESG=/var/run/dmesg.boot preflight

# 8. Run the regression tests (extracted from the bundle)
cd /tmp/wave7/nested/hw/preflight
sudo bash run_preflight_tests.sh
# Expected: 12/17 PASS, 5 SKIP root-gated, 0 FAIL

# 9. Optional - install the regression suite to the host for future runs
sudo cp -r /tmp/wave7/nested /usr/tests/sys/vmm/
cd /usr/tests/sys/vmm/nested/hw/preflight
sudo bash run_preflight_tests.sh
```

## What's new in this kernel

- wave-3: SYSCTL_CREATE_NESTED `VMMCTL_CREATE_NESTED`, `VMMAPI_OPEN_CREATE_NESTED`, `hw.vmm.nested.enable`, `hw.vmm.nested.vmx`, `hw.vmm.nested.svm`
- wave-5: VMCS shadowing (per-VM after VMPTRLD), VMCLEAR/VMLAUNCH/VMRESUME/VMCALL, VMCS12 state machine
- wave-6: T18-T23b real nVMX launch path (VMPTRLD with GPA translation, EPT12 walker, VMREAD/VMWRITE, INVEPT/INVVPID)
- wave-7: tools/preflight.sh v2.0 with audit-driven architecture detection

## Rollback

The rollback BE name is host-specific (whatever was active before wave7-preflight).

```sh
# Find the prior BE
sudo bectl list | grep -v wave7-preflight

# Example: if the prior BE was named "default" or "cloudbsd-20260722"
sudo bectl activate default
sudo shutdown -r +1 "rollback"
```

## Performance baseline (post-patch sysbench cpu --cpu-max-prime=20000)

Captured 2026-08-12 on AMD Zen 5 HX 370:

### Single-thread (--threads=1)

| Run | events/s | total events |
| --- | --- | --- |
| 1 | 7,775,043.68 | 77,760,651 |
| 2 | 8,001,843.95 | 80,028,808 |
| 3 | 7,746,902.21 | 77,478,376 |

mean: 7,841,263 events/s (≈ 7.84M)

### Multi-thread (--threads=8)

| Run | events/s | total events |
| --- | --- | --- |
| 1 | 39,363,688.45 | 393,732,673 |
| 2 | 40,166,560.46 | 401,747,621 |
| 3 | 39,670,691.10 | 396,789,779 |

mean: 39,733,646 events/s (≈ 39.73M)

### Methodology

- Host: AMD Ryzen AI 9 HX 370 w/ Radeon 890M (12 logical cores)
- Kernel: 16.0-CURRENT main wave-3+5+6+7 (post-patch)
- vmm.ko: loaded with `hw.vmm.nested.svm = 1`
- L0 hypervisor: VMware Workstation (filters VMX)
- Tool: sysbench 1.0.20
- Command: `sysbench cpu --cpu-max-prime=20000 --threads=N run`

This is the analog of the pre-patch baseline (`tests/sys/vmm/nested/perf/baseline.txt`,
captured on freedev003 Tiger Lake). Cross-host comparison requires scaling because
Zen 5 and Tiger Lake have different per-core throughput.
