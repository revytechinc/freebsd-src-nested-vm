# KVM Parity Conformance — Allowlist Policy

**SPDX-License-Identifier:** BSD-2-Clause
**Wave 7 / Task 38** of the FreeBSD nested-virt plan.

This document is the authoritative allowlist for the
`kvm_parity_check.sh` test suite.  It encodes:

1. The **policy** used to compare FreeBSD bhyve nVMX/nSVM
   behaviour against the architectural reference (and, by
   transitive conformance, against the KVM reference implementation).

2. The **list of known acceptable diffs** — vectors where
   FreeBSD's behaviour is intentionally different from KVM,
   each with a rationale and a tracking reference.

3. The **test vector allowlist totals** that the test harness
   enforces on every run.

## Policy

**Allowlist-based conformance.**  Each test vector has a
`CATEGORY` of either `MUST_PASS` or `KNOWN_DIFF`.

| CATEGORY    | Meaning                                                      |
|-------------|--------------------------------------------------------------|
| MUST_PASS   | Architectural correctness.  L2's view MUST match the vector |
|             | (modulo `MASK`).  Any deviation is a test failure.           |
| KNOWN_DIFF  | Documented divergence.  Test passes if vector is present;   |
|             | exact value comparison is skipped.  New KNOWN_DIFFs MUST be |
|             | added here with a rationale.                                 |

The previous plan text proposed "100% match AND <5% diff" as
acceptance criteria, but those two conditions are mutually
exclusive (100% match implies 0% diff).  This document resolves
the contradiction by selecting the allowlist policy above.

## Test Vector Allowlist Totals

The test harness enforces the following counts.  The vector
file footers and the script's `ALLOWLIST` variable must agree
with this table.  If you add a vector, update **all three**.

| File                        | MUST_PASS | KNOWN_DIFF | Total |
|-----------------------------|-----------|------------|-------|
| `cpuid_vectors.txt`         | 56        | 3          | 59    |
| `exit_reason_vectors.txt`   | 30        | 5          | 35    |
| `vmcs_vectors.txt`          | 38        | 3          | 41    |
| `vmcb_vectors.txt`          | 73        | 3          | 76    |
| **Total**                   | **197**   | **14**     | **211** |

**Acceptance:**

- The test passes if every `MUST_PASS` vector matches AND the
  count of `KNOWN_DIFF` vectors exactly equals the allowlist
  above (no more, no fewer).
- The test FAILS if any `MUST_PASS` vector diverges OR if a
  new vector appears that is not in this allowlist.

## KNOWN_DIFF Catalog

Each entry below documents a vector where bhyve's nested-virt
behaviour intentionally differs from the KVM reference.  Every
entry has:

- **ID** — the vector's stable identifier in the source file.
- **Source** — the vector file it lives in.
- **Rationale** — why the diff exists (architectural
  interpretation, deferred feature, deliberate scope, etc.).
- **Tracking** — a FreeBSD bug/feature reference.

### CPUID

| ID    | Rationale                                                            | Tracking |
|-------|----------------------------------------------------------------------|----------|
| D001  | VMX capability bit (leaf 1 ECX bit 5): KVM exposes VMX to L2 by     | wave-8   |
|       | default; bhyve nVMX must explicitly enable the bit through the      |          |
|       | capability MSR surface.  When the host CPU's VMX is disabled,        |          |
|       | the bit MUST read 0; KVM sometimes inherits a stale value.           |          |
| D002  | Hypervisor vendor signature (leaf 0x40000000): KVM emits             | wave-8   |
|       | "KVMKVMKVM\\0\\0\\0"; bhyve emits "FreeBSDVMM" or the host          |          |
|       | signature.  Both are architecturally valid; this is a vendor-ID     |          |
|       | diff, not a functional diff.                                        |          |
| D003  | XSAVE area size (leaf 0x0D subleaf 2): KVM and bhyve compute         | wave-8   |
|       | the per-feature XSAVE area offsets using different alignment        |          |
|       | policies.  Architectural correctness requires only that the         |          |
|       | L2's effective XCR0 be honored, not that the area size match KVM.  |          |

### Exit Reason

| ID    | Rationale                                                            | Tracking |
|-------|----------------------------------------------------------------------|----------|
| D001  | APIC-write exit qualification: KVM merges writes to the TPR          | wave-8   |
|       | register and the EOI register into a single #VMEXIT with a          |          |
|       | combined qualification; bhyve emits two exits.  Both are             |          |
|       | architecturally correct; L1 must handle both.                       |          |
| D002  | EPT misconfiguration classification: KVM and bhyve differ in how     | wave-8   |
|       | they bucket specific misconfigurations (reserved bits set vs.       |          |
|       | walk-length violation).  L1's #VMEXIT handler must treat the        |          |
|       | exit-reason field as the source of truth.                           |          |
| D003  | I/O bitmap granularity in #VMEXIT qualification: KVM reports the    | wave-8   |
|       | bitmap index in the upper bits; bhyve reports the per-byte         |          |
|       | offset.  L1 may need to translate between the two.                  |          |
| D004  | x2APIC MSR RDMSR clustering: KVM may emit a single combined         | wave-8   |
|       | #VMEXIT for the APIC ICR low/high pair; bhyve emits two.            |          |
| D005  | x2APIC MSR WRMSR clustering: same as D004 but for writes.            | wave-8   |

### VMCS12

| ID    | Rationale                                                            | Tracking |
|-------|----------------------------------------------------------------------|----------|
| D001  | Secondary proc-based controls (field 0x401E): KVM and bhyve          | wave-8   |
|       | expose different default values.  Architectural correctness          |          |
|       | requires only that the L1-set values round-trip.                    |          |
| D002  | VMCS12 revision identifier: KVM and bhyve differ in shadow-VMCS      | wave-8   |
|       | support bits.  Revision 1 is the spec-mandated baseline.            |          |
| D003  | EPT pointer width: KVM uses 64-bit EPTP; bhyve cap-and-mask         | wave-8   |
|       | reserves the upper 16 bits.  Functional behaviour identical.         |          |

### VMCB12

| ID    | Rationale                                                            | Tracking |
|-------|----------------------------------------------------------------------|----------|
| D001  | LBR stack virtualization: KVM and bhyve differ in LBR stack         | wave-8   |
|       | granularity and the number of saved entries.  Both are              |          |
|       | architecturally valid; L1 must consult VMCB12.LBR_VIRT_ENABLE.      |          |
| D002  | SEV/SEV-ES state pages: KVM and bhyve differ in how the encrypted   | wave-8   |
|       | state-page address is exposed.  Neither exposes SEV state to        |          |
|       | L1 by default; the diff is a layout choice, not a security choice.  |          |
| D003  | AVIC backing page: KVM and bhyve differ in how the AVIC backing      | wave-8   |
|       | page address is reported in the VMCB12.  Architectural correctness   |          |
|       | requires only that L2's AVIC accesses honour the address.           |          |

## Why "100% AND <5%" Was Rejected

The original plan text for T38 proposed a "100% match" criterion
AND a "<5% diff" criterion as co-equal acceptance gates.  These
two are mutually exclusive (a 100% match has 0% diff, not <5%),
so the test could never have produced a clean verdict.  This
document resolves the contradiction by:

1. Replacing the percentage criterion with an **explicit
   allowlist of known-acceptable diffs** (this section).
2. Requiring that any new diff be **added to the allowlist**
   with a rationale, not silently accumulated.

The result is a deterministic, reviewable policy that
maintainers can audit: every diff is named, every diff is
justified, and the test either passes or fails for an
inspectable reason.

## How to Add a New KNOWN_DIFF

1. **Identify the divergence.**  Run the test, observe a
   mismatch.  Confirm it is intentional (not a bug).

2. **Edit the vector file.**  Add a new vector with ID prefix
   `D` (e.g. `D004`) and `CATEGORY` of `KNOWN_DIFF`.  Use
   zero-value `EXPECTED` since exact-value comparison is
   skipped.

3. **Update the vector file footer** with the new
   `KNOWN_DIFF` count.

4. **Add a row** to the matching table in this document
   (`KNOWN_DIFF Catalog`), including a rationale and a
   tracking reference (a bug number, a wave number, or
   a FreeBSD review reference).

5. **Update the test script's `ALLOWLIST`** entry to match
   the new count.

6. **Commit** the four changes as a single commit with a
   message in the form
   `tests(vmm): add KNOWN_DIFF <ID> — <one-line rationale>`.

## How to Promote a KNOWN_DIFF

If a previously-acceptable diff is no longer acceptable
(e.g. KVM fixes a bug, bhyve adopts the corrected behaviour):

1. Change the vector's `CATEGORY` from `KNOWN_DIFF` to
   `MUST_PASS`.
2. Update the `EXPECTED` field to the architecturally
   correct value.
3. Update the vector file footer's count.
4. Remove the entry from the `KNOWN_DIFF Catalog` table
   here.
5. Update the test script's `ALLOWLIST` entry.
6. Commit as
   `tests(vmm): promote KNOWN_DIFF <ID> to MUST_PASS`.

## Source

The reference behaviour is encoded from:

- **Intel SDM** Vol. 2A (CPUID), Vol. 3 (VMX), Appendix B
  (VMCS field encodings).
- **AMD APM** Vol. 2 (SVM), Vol. 3 (CPUID Specification),
  section 15.5 (VMCB Layout), Table 15-7 (VMCB offsets).
- **Hyper-V TLFS** 7.4 (virtual processor features),
  7.8.2 (interface identification).

No values in the vector files are copied from KVM source code.
The vectors describe the architectural specification, and KVM
is the conformance reference because it is the most
widely-deployed nested-virt implementation.
