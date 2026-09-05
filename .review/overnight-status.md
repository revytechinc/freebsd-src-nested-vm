# Overnight status — nested virtualization

Written for picking up cold. Everything below is what was measured, not what
was assumed; where something is unverified it says so.

## What is safe to touch

- **freedev006 is the demo host.** Its kernel was NOT changed overnight. The
  recursive snapshot `zroot@mdexter` is intact with holds on all 67 datasets.
  A wholesale rollback would also undo the `bhyve-firmware` package install and
  Mike's `doas` rules, which you want to keep — roll back per dataset if ever
  needed.
- Test hosts used overnight: freedev005 (builds), freedev009 (Intel testing).
- Nothing was published to the pkg repo or the canonical branch.

## The banners (you asked to review these)

    ssh freedev006 '/usr/local/libexec/cloudbsd-demo/demo-banner'
    fetch -o - https://nested.cloudbsd.cat/nested-demo.sh | head -60
    printf 'exit\n' | doas script -q /tmp/x su -l mdexter    # what Mike sees

Wired into: the four privileged launchers, Mike's login (above his welcome
card), `~/nested-demo/` on all six hosts, and the public `nested-demo.sh`
(inlined, since that one is fetched and run standalone).

Validated: FreeBSD `sh -n` on every wired script; a real `su -l mdexter` login
through a pty shows the banner once with 12 colour escapes and the welcome card
intact; piped output contains zero escape sequences; every line 64 columns.

## Does the demo still work?

**Not re-run since the banner went in.** The banner only prints and cannot
affect the boot path, but that is reasoning, not evidence. Run demo 1 before
relying on it:

    ssh freedev006 'doas -u mdexter sh /home/mdexter/demo-1-auto.sh'

## Where the engineering stands

**AMD: passing.** A full stock nested stack — L2 to a multi-user login, and
both layers writing a gigabyte, snapshotting and scrubbing clean. Reproduced
twice.

**Intel: root shell confirmed on the shipped build.** On freedev009
(i7-8705G, no VMCS shadowing, no APICv) a stock 14.3-RELEASE guest reaches an
interactive root shell two layers up. Kernel
`nested-current-1600022-cef732cd047c`, `vmm.ko` sha256 `bcbd4324…`. So the
site's central claim is true and demonstrable.

**Intel + the new OccamBSD harness: L2 stays silent.** This is a harness
problem, not a hypervisor regression — the same host passes by the older path.
Variables eliminated one at a time:

| variable | result |
|---|---|
| L2 boot method (UEFI+NVMe, UEFI+virtio, bhyveload+virtio) | not it — all three silent |
| L1 boot method (UEFI bootrom vs bhyveload) | not it — both reach an L1 root shell, L2 still silent |
| L1 vCPU count (2 vs 1) | **in flight when this was written** |

Remaining untested difference if vCPU count is not it: the guest image itself
(16.0-CURRENT built by OccamBSD vs stock 14.3-RELEASE).

## The X280 panic

Not reproduced, and deliberately not blocked on. A kernel carrying every fix
below is built on freedev005 for him to test. **Honest caveat: none of the
fixes obviously explains his symptom** — his was the guest-RIP assertion, and
the nesting-gate fix is a NULL dereference while the faulting-instruction fix
leaves that assertion self-consistent. Worth testing, not worth predicting.

## Fixes landed on nested-virt/wave5-t18-t23b-impl (not shipped)

All build clean. **None has been through the test matrix**, so by our own rule
every earlier pass is void until it is re-run against one final build.

1. `vie_calculate_gla()` accepted only 1/2/4/8-byte operands, so an L1 could
   panic L0 with a plain INVEPT (16-byte descriptor).
2. A faulting nested VM* instruction had its RIP advanced past itself, so L1
   received the exception pointing past the instruction that caused it.
3. `vmx_nested_state()` re-read the host-wide sysctl on every call and returned
   NULL when it was 0 — flipping nesting off under a running guest dereferenced
   NULL in the kernel. The gate is captured per VM at creation now.
4. `vmx_nested_ept02_cleanup()` freed the MSR bitmap without clearing the
   pointer (latent, not reachable today).
5. Nesting defaulted **off** on this branch; it defaults on where it ships, so
   merging would have silently disabled the feature.
6. `vmm_nested(9)` was written but never listed in the man Makefile — it never
   installed anywhere.
7. VMCB02 was composed from the live, L1-writable VMCB12 rather than the
   snapshot the block's own comment promises; the snapshot reads are
   `atomic_load` now, including the two the original host-DoS fix took.
8. An L1 EPTP with an unimplemented walk depth was accepted verbatim and walked
   as if it were 4-level — silent mistranslation. Now fails the nested VM entry.
9. `pmap_enter()` was passed the granted permissions where the faulting access
   type belongs, dirtying L1 pages on pure reads.

## Site

Current and audited. Stamp is generated at build time now, so it cannot go
stale again. Published `nested-demo.sh` checksum was **wrong** (`6264dd72` vs
actual) and is fixed; the other twelve release checksums were verified correct.

## Next, in order

1. Finish the Intel harness isolation (vCPU count, then the guest image).
2. Triage the remaining review findings — 47 recorded in
   `.review/nested-findings.md`, 4 acted on, triage log at the bottom.
3. Run the full matrix against one final build so the fixes can ship.
4. Performance baselines, stock vs ours — still not started.
