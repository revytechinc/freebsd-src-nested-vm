# Nested-Virt Security Audit (Intel VMX + AMD SVM) — Full-Scope

## TL;DR

> **Quick Summary**: Per-path security audit of the FreeBSD nested-virtualization implementation on `nested-virt/wave5-fix-t25-stub-functions`. Validates that stub paths in vmx_nested_* and svm_nested_* have been implemented, then audits each path against the Intel SDM / AMD APM, fixes findings, writes per-path tests, and ships custom tooling (Semgrep rules + fuzz harness + EFI/non-EFI ATF variants). Cross-arch coverage: Intel VMX on Intel host, AMD SVM on EPYC host, with EFI and non-EFI boot variants. Every implementation step is gated by Grok review.
>
> **Deliverables**:
> - All `return (-1)` / `return (1)` stubs in `vmx_nested_*` and `svm_nested_*` replaced with real implementations
> - Real VMCS12 EPT12 walk (replacing identity-map TODO), shadow bitmaps allocated
> - STRIDE audit findings per file under `.sisyphus/findings/FINDING-NNN-{slug}.md`
> - Custom Semgrep rules for VMCS12/VMCB validation patterns under `tools/semgrep-rules/`
> - libFuzzer harness for VMCS12/VMCB field encodings under `tests/sys/vmm/nested/fuzz/`
> - ATF tests for the 40+ L1-misbehavior scenarios under `tests/sys/vmm/nested/negative/`
> - EFI vs non-EFI boot harness under `tests/sys/vmm/nested/integration/`
> - Multi-host CI: 7 hosts total — fredev001 (Intel Xeon, OFF), fredev002 (old Intel), fredev003 (Tiger Lake i9-11950H), fredev004 (Intel Xeon, OFF), fredev005 (EPYC), fredev006 (EPYC), VM at 172.16.176.131 (Ryzen 9)
>
> **Estimated Effort**: XL — phased over multiple waves; interleaved per-path implement→audit→test
> **Parallel Execution**: YES — per-path waves; max ~5-7 paths in parallel
> **Critical Path**: stub-impl Intel → stub-impl AMD → EPT12 walk → shadow bitmaps → semgrep rules → fuzzer → multi-host CI

---

## Context

### Original Request

> "check honcho mcp for the current status of this project, and lets start planning the security audit"
> "also cross reference with grok on all plans"
> "amd as well... all work related to nested virt i want every aspect tested, and all arch with many configurations efi and non efi, and does operant or any other mcp cover what we need or do we need to make special tooling?"

### Interview Summary

**Key Decisions**:
- **Audit type:** Comprehensive multi-phase (threat model + code review + architecture review + config matrix + fuzz + compliance + pen-test)
- **Scope:** All work related to nested virt — kernel (Intel VMX + AMD SVM) + userspace (libvmmapi, bhyve) + tests + tooling
- **Multi-arch:** Intel VMX + AMD SVM, EFI + non-EFI, every configuration matrix
- **Stubs:** Write full implementations first, then audit (per user direction; an agent is currently locating stubs)
- **Per-path sequencing:** implement → audit → test (interleaved)
- **Hardware:** 7 hosts total — fredev001 (Intel Xeon, currently OFF), fredev002 (old Intel), fredev003 (Tiger Lake i9-11950H), fredev004 (Intel Xeon, currently OFF), fredev005 (EPYC), fredev006 (EPYC), VM at 172.16.176.131 (Ryzen 9); 5 active at any time; full multi-host CI required
- **Findings storage:** `.sisyphus/findings/FINDING-NNN-{slug}.md` per-finding files
- **Tooling:** Custom tooling required (semgrep rules + fuzzer + EFI harness)
- **Grok cross-reference:** mandatory on every plan and finding (user explicit request)

**Research Findings** (from explore + librarian agents):
- Intel: 12 files in `sys/amd64/vmm/intel/vmx_nested*.{c,h}` (1569 lines), `vmx.c` (4616), `vmx_msr.c` (920)
- AMD: 9 files in `sys/amd64/vmm/amd/svm_nested*.{c,h}` (1372 lines), `svm.c` (79667), `svm_msr.c` (27457), `npt.c` (2372)
- Tests: `tests/sys/vmm/nested/` with 17 subdirs (negative/scripts/integration/parity/fuzz/snapshot/abisnap/resource/perf/soak/features/io/hw/{preflight,exit_plumbing,stress}/recovery)
- **Tooling available locally**: `semgrep`, `trivy`, `gitleaks` (CLI); `codeinspectus`, `sast-mcp-server`, `operant`, `agent-bom` (MCPs)
- **Grok review** (high confidence, NARROW): scope was unbounded; treat stubs as out-of-scope-until-implemented; user chose "implement then audit" so this constraint is satisfied
- **40+ CVE patterns** from KVM/Xen/AMD nested-virt history (CVE-2018-12904, CVE-2021-29657 EPYC escape, CVE-2024-46830, CVE-2024-53135, CVE-2026-53359 Januscape, XSA-308, etc.)
- **Prior plan** `.sisyphus/plans/nested-virt-register-virtualization.md` established wave pattern (wave0a → wave9 + Final review); new plan reuses that cadence

### Metis Review

**Identified Gaps** (addressed in plan):
- **Tooling coverage**: operant MCP is web-only (NOT applicable to kernel); sast-mcp-server applies but lacks FreeBSD/vmm rules; codeinspectus is the closest fit but still generic. Custom Semgrep rules REQUIRED for VMCS12/VMCB patterns.
- **Hardware-in-loop**: not in any MCP; must be built with ATF + lab-host fixtures (fredev005 + AMD EPYC + Intel host).
- **EFI/non-EFI coverage**: no existing harness; OVMF/SeaBIOS+qemu required for reproducible CI; real-hardware EFI testing needs host firmware setup.
- **Stub coverage audit**: need to verify ALL `return (-1)` and `return (1)` stubs in nested paths have been replaced before claiming audit coverage.
- **AMD coverage asymmetry**: AMD nested path has fewer in-kernel tests (only `svm_nested_test.c` exists) — needs additional in-kernel tests mirroring Intel's 5-test set.
- **Cross-reference Grok**: every plan + every finding file gets a Grok review (per user explicit request).

---

## Work Objectives

### Core Objective

Replace stub-heavy nested-VMX/SVM with real implementations, audit each path against Intel SDM Vol 3 / AMD APM Vol 2 with STRIDE, ship per-path tests + custom tooling, and produce findings under `.sisyphus/findings/` with CVSS scoring — validated across Intel VMX + AMD SVM in EFI and non-EFI configurations.

### Concrete Deliverables

1. **Stub implementations** (per-path):
   - Intel: `vmx_nested_vmclear`, `vmx_nested_vmlaunch`, `vmx_nested_vmresume`, `vmx_nested_vmcall`, `vmx_nested_invept`, `vmx_nested_invvpid`, `vmx_nested_shadow_apply`, `vmx_nested_shadow_check`, `vmx_nested_ept12_translate`, plus `vmcs_field_dirty`/`vmcs_field_ro` allocation
   - AMD: `svm_nested_vmrun`, `svm_nested_vmsave`, `svm_nested_vmload`, `svm_nested_clgi`, `svm_nested_stgi`, `svm_nested_skinit`, `svm_nested_lookup`
   - VMXON double-VMXON check
2. **Audit findings** in `.sisyphus/findings/FINDING-NNN-{slug}.md` (one file per CVE/issue)
3. **Custom tooling**:
   - `tools/semgrep-rules/vmcs12-validations.yaml` (Intel VMCS12 validation patterns)
   - `tools/semgrep-rules/vmcb-validations.yaml` (AMD VMCB validation patterns)
   - `tests/sys/vmm/nested/fuzz/fuzz_vmcs12.c` (libFuzzer harness for VMCS12 field encodings)
   - `tests/sys/vmm/nested/fuzz/fuzz_vmcb.c` (libFuzzer harness for VMCB field encodings)
   - `tools/qemu-ovmf-harness/` (EFI/non-EFI reproducer for CI)
4. **Tests** for 40+ L1-misbehavior scenarios under `tests/sys/vmm/nested/negative/`
5. **Multi-host CI**: 7 hosts total — fredev001 (Intel Xeon, currently OFF), fredev002 (old Intel), fredev003 (Tiger Lake i9-11950H), fredev004 (Intel Xeon, currently OFF), fredev005 (EPYC), fredev006 (EPYC), VM at 172.16.176.131 (Ryzen 9). 5 active at any time (fredev001/fredev004 power-on when available).

### Definition of Done

- [ ] All `return (-1)` / `return (1)` stubs in nested paths replaced (verified by grep: no stub returns left in nested-virt files)
- [ ] Real EPT12 walk (replaces identity-map TODO)
- [ ] `vmcs_field_dirty` / `vmcs_field_ro` bitmaps allocated and used
- [ ] STRIDE audit covers every public entry point (vmx_nested_*, svm_nested_*)
- [ ] Every finding has a CVSS score + file:line + remediation + verification
- [ ] Custom Semgrep rules pass on the codebase (no false positives on correct code)
- [ ] Fuzzer harness builds and runs; corpus covers all VMCS12/VMCB field encodings
- [ ] 40+ ATF negative tests pass on Intel VMX host
- [ ] 40+ ATF negative tests pass on AMD SVM host
- [ ] EFI + non-EFI boot variants tested on at least one host
- [ ] Grok review on every finding file (PASS verdict or revision applied)

### Must Have

- Real implementations of every nested-VMX/SVM stub before audit phase
- Per-finding files with structured metadata (CVSS, file:line, remediation, evidence)
- Per-path sequencing: implement → audit → test, then move to next path
- Cross-reference Grok on every plan + every finding
- Multi-host test execution across 5 hosts (fredev002/fredev003/fredev005/fredev006/172.16.176.131)

### Must NOT Have (Guardrails)

- **No skipping the implementation phase** — auditing stubs is meaningless (per user direction)
- **No findings without file:line + CVSS** — vague findings rejected by Grok review
- **No tests without negative scenarios** — only positive paths is insufficient for security audit
- **No custom tooling without CI integration** — script that runs only locally is not a deliverable
- **No real-host testing on dev/CI hosts** — per CloudBSD safety contract: untested kernel modules load only inside isolated bhyve VM
- **No edits to upstream FreeBSD without `$FreeBSD$` upstream review** — this is a fork; preserve attribution
- **No vague scope inflation** — "test every configuration" is rejected; specific config matrix required
- **No findings buried in code comments** — every finding must be a standalone file

---

## Verification Strategy (MANDATORY)

> **ZERO HUMAN INTERVENTION** — all verification is agent-executed via Bash/Semgrep/ATF/QEMU.

### Test Decision

- **Infrastructure exists:** YES — `tests/sys/vmm/nested/` has 17 subdirs of ATF harness
- **Automated tests:** YES — per-path TDD; for each path: implementation → unit test → ATF test → negative test → fuzz corpus → cross-arch run
- **Framework:** ATF (FreeBSD test framework) + libFuzzer + custom Semgrep
- **Per-path RED-GREEN-REFACTOR**:
  - RED: write negative test that fails on stub
  - GREEN: implement real path
  - REFACTOR: address any audit findings on that path

### QA Policy

Each task includes agent-executed QA scenarios. Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.

- **Kernel C code**: `git grep`, `cppcheck`/`semgrep` on diff, build via `make buildkernel`, kernel module load inside isolated bhyve VM
- **Test code**: ATF run via `kyua test`; fuzzer run via `llvm-libfuzzer`; Semgrep via `semgrep --config=tools/semgrep-rules/`
- **Build verification**: `make buildkernel` succeeds, kernel loads on fredev005, module loads in isolated bhyve VM
- **Cross-arch verification**: same test suite runs on Intel VMX host and AMD EPYC host; results compared

---

## Execution Strategy

### Parallel Execution Waves

> Per-path sequencing. Each path is a unit (implement → audit → test → findings). Paths within a wave share no files.

```
Wave 1 (Foundation + Intel stubs to real impl — 5 paths parallel):
├── Path 1A: Intel VMCS12 EPT12 walk (replaces identity-map TODO)
├── Path 1B: Intel vmcs_field_dirty/_ro bitmap allocation + shadow_apply/_check
├── Path 1C: Intel vmx_nested_invept + vmx_nested_invvpid (currently stubs)
├── Path 1D: Intel vmx_nested_vmclear (currently stub)
├── Path 1E: Intel vmx_nested_vmlaunch + vmx_nested_vmresume (currently stubs)
└── Path 1F: Intel vmx_nested_vmcall (currently stub)

Wave 2 (AMD stubs to real impl — 6 paths parallel):
├── Path 2A: AMD svm_nested_vmrun (currently stub `return (1)`)
├── Path 2B: AMD svm_nested_vmsave
├── Path 2C: AMD svm_nested_vmload
├── Path 2D: AMD svm_nested_clgi + svm_nested_stgi
├── Path 2E: AMD svm_nested_skinit
└── Path 2F: AMD svm_nested_lookup (currently `ns = NULL`)

Wave 3 (Cross-cutting hardening — 4 paths parallel):
├── Path 3A: VMXON double-VMXON race fix + lock audit
├── Path 3B: AMD HSAVE_PA lifetime + msrpm_base_pa validation
├── Path 3C: Intel CR/EFER emulation completeness check
└── Path 3D: AMD CR/EFER/SVME emulation completeness check

Wave 4 (Audit + tooling — 5 paths parallel):
├── Path 4A: STRIDE audit of vmx_nested_vmptrld.c (T18 wave-final-integrated)
├── Path 4B: STRIDE audit of vmx_nested_vmread.c (VMCS12 encoding→offset table)
├── Path 4C: STRIDE audit of vmx_msr.c nested MSR bitmap
├── Path 4D: STRIDE audit of svm.c nested dispatch + HSAVE
└── Path 4E: STRIDE audit of npt.c nested NPT walk + invalidation

Wave 5 (Custom tooling — 4 paths parallel):
├── Path 5A: Semgrep rules for VMCS12 validation (tools/semgrep-rules/vmcs12-validations.yaml)
├── Path 5B: Semgrep rules for VMCB validation (tools/semgrep-rules/vmcb-validations.yaml)
├── Path 5C: libFuzzer harness for VMCS12 field encodings (fuzz_vmcs12.c)
└── Path 5D: libFuzzer harness for VMCB field encodings (fuzz_vmcb.c)

Wave 6 (Negative tests — 3 paths parallel):
├── Path 6A: 40 L1-misbehavior ATF tests for Intel VMX (tests/sys/vmm/nested/negative/)
├── Path 6B: 40 L1-misbehavior ATF tests for AMD SVM (tests/sys/vmm/nested/negative/)
└── Path 6C: AMD in-kernel self-tests mirroring Intel's 5-test set (svm_nested_test.c)

Wave 7 (EFI/non-EFI harness + cross-arch CI — 3 paths parallel):
├── Path 7A: qemu + OVMF (EFI) + SeaBIOS (non-EFI) harness for CI
├── Path 7B: Multi-host CI orchestration (fredev001 + fredev002 + fredev003 + fredev004 + fredev005 + fredev006 + 172.16.176.131 — fredev001/fredev004 power-on when available)
└── Path 7C: Per-CPU-family config matrix (Tiger Lake, Ivy Bridge, EPYC variants)

Wave 8 (Integration + KVM-parity + ABI — 3 paths parallel):
├── Path 8A: L1+L2 launch integration test extension (AMD SVM host)
├── Path 8B: KVM parity conformance test extension (VMCS12/VMCB field mapping)
└── Path 8C: ABI snapshot regen + golden-file comparison

Wave FINAL (4 parallel reviews + user okay):
├── F1: Plan compliance audit (oracle)
├── F2: Code quality review + lint (unspecified-high)
├── F3: Real manual QA on Intel + AMD hosts (unspecified-high + playwright NOT used)
├── F4: Scope fidelity check + Grok cross-reference (deep)
→ Present results → Get explicit user okay

Critical Path: 1A → 1B → 1E → 2A → 2B → 4A → 4B → 5A → 6A → 7A → 7B → 8A → F1-F4 → user okay
```

### Dependency Matrix (abbreviated)

- **1A**: - - 4A, 6A, 5C, 7A
- **1B**: - - 4B, 5C
- **1C**: - - 4C, 6A
- **2A**: - - 4D, 6B, 5D
- **2B**: 2A - 4D
- **4A**: 1A, 1B - F1-F4
- **5A**: 4A-4E - F1, F2
- **6A**: 1A-1F, 5A - F3
- **7A**: 6A, 6B - F3
- **7B**: 7A - F3

---

## TODOs

> Implementation + Test + Finding = ONE Path. Per-path: RED → GREEN → REFACTOR → FINDING(S).
> EVERY path MUST have: Recommended Agent Profile + Parallelization info + QA Scenarios.
> **A path without QA Scenarios is INCOMPLETE. No exceptions.**

- [ ] P1. Intel VMCS12 EPT12 walk — replace identity-map TODO

  **What to do**:
  - Implement `vmx_nested_ept12_translate` (sys/amd64/vmm/intel/vmx_nested_ept12.c:44-52) per Intel SDM Vol 3 §28.2: recursive EPT walk respecting 4-level/5-level paging, A/D bits, reserved MBZ bits, EPTP validation
  - Add EPT12 root PTE validation in `vmx_nested_ept12_install` (line 33-42): check `EPTP[2:0]` memory type, `EPTP[5:3]` page-walk length, `EPTP[6]` accessed/dirty flags, `EPTP[11:7]` reserved MBZ
  - INVEPT-on-modify: call `invept()` after every EPT12 modification (currently missing — vmcs_field_dirty/_ro bitmaps never allocated)
  - RED test: ATF `tests/sys/vmm/nested/negative/ept12_translate_invalid_pte.sh` — pass invalid EPT12 root, expect VMFailValid with specific error code
  - GREEN: pass the test
  - Audit finding: any field-level validation gap produces a FINDING

  **Must NOT do**:
  - Do NOT trust L1-supplied EPTP without checking it against L0's EPT capability MSR
  - Do NOT skip INVEPT after EPT12 modification — leaks stale translations
  - Do NOT allow EPT12 walk recursion beyond 4 levels (or 5 for LA57)

  **Recommended Agent Profile**:
  - **Category:** `deep`
    - Reason: requires deep understanding of Intel EPT specification + nested translation semantics
  - **Skills:** `[]`
    - Empty because this is kernel C with no specialized skill required

  **Parallelization**:
  - **Can Run In Parallel:** YES
  - **Parallel Group:** Wave 1 (with P1B–P1F)
  - **Blocks:** P4A, P5C, P6A, P7A
  - **Blocked By:** None (can start immediately)

  **References** (CRITICAL):
  - Intel SDM Vol 3, Chapter 28 (EPT)
  - `sys/amd64/vmm/intel/vmx_nested_ept12.c:33-52` (current stub)
  - `sys/amd64/vmm/intel/vmx_nested.h:215-225` (TODO marker docstring)
  - `sys/amd64/vmm/intel/vmx.c:1158-1175` (existing EPTP setup for comparison)

  **Acceptance Criteria**:
  - `git grep -n 'TODO(mvp)' sys/amd64/vmm/intel/vmx_nested_ept12.c` returns nothing
  - `make buildkernel` succeeds with no new warnings
  - ATF test `tests/sys/vmm/nested/negative/ept12_translate_invalid_pte.sh` passes (returns 0)
  - Kernel module `vmm.ko` loads inside isolated bhyve VM on fredev005
  - At least one FINDING file produced if any audit issue found: `.sisyphus/findings/FINDING-NNN-ept12-*.md`

  **QA Scenarios (MANDATORY)**:
  ```
  Scenario: EPT12 walk with valid 4-level EPTP translates correctly
    Tool: Bash + ATF
    Preconditions: buildkernel clean; isolated bhyve VM with hw.vmm.nested.enable=1
    Steps:
      1. Inside isolated VM, run bhyve with nested enabled and a 2-level VM (L1 launches L2)
      2. L2 reads a GPA inside L1's EPT12 walk
      3. Assert translation succeeds and L2 sees the correct HPA
    Expected Result: VM-exit with no error; L2 sees expected memory
    Failure Indicators: VMFailValid; L2 panic; kernel panic in L0
    Evidence: .sisyphus/evidence/P1-ept12-walk-success.txt

  Scenario: EPT12 walk with invalid EPTP (reserved bits set) must VMFailValid
    Tool: Bash + ATF
    Preconditions: same as above
    Steps:
      1. L1 issues VMPTRLD with EPT12 root containing reserved bits in EPTP
      2. L1 attempts VMLAUNCH
      3. Assert VM-exit with VM_INSTRUCTION_ERROR indicating EPTP invalid
    Expected Result: VMFailValid, error code = 8 (EPTP invalid)
    Failure Indicators: VMFailInvalid (worse); kernel panic (worst)
    Evidence: .sisyphus/evidence/P1-ept12-walk-fail-invalid.txt
  ```

  **Commit**: YES
  - Message: `vmm(intel): real EPT12 walk + EPTP validation`
  - Files: `sys/amd64/vmm/intel/vmx_nested_ept12.c`, `sys/amd64/vmm/intel/vmx_nested.h`, `tests/sys/vmm/nested/negative/ept12_translate_invalid_pte.sh`
  - Pre-commit: `make buildkernel && kyuua test -k /usr/tests tests/sys/vmm/nested/`

- [ ] P1B. Intel VMCS12 shadow bitmaps — allocate `vmcs_field_dirty` and `vmcs_field_ro`

  **What to do**:
  - Allocate `vcpu->nested_state->vmcs_field_dirty` (4KB) and `vmcs_field_ro` (4KB) in `vmx_vcpu_init` (vmx.c:1273-1277); free in teardown (vmx.c:3553-3556)
  - Mark fields as dirty in `vmx_nested_vmwrite` (vmx_nested_vmread.c:248-293) per `VMCS12_F_READONLY` class
  - Wire `vmx_nested_shadow_apply` and `_check` to actually use the bitmaps (currently `return (0)`/`return (-1)`)
  - RED test: `tests/sys/vmm/nested/negative/shadow_vmcs12_field_dirty.sh` — write to a dirty field, expect shadow apply to scrub
  - Audit finding: any read of shadow bitmaps without proper locking produces a FINDING

  **Must NOT do**:
  - Do NOT allocate shadow bitmaps outside `nested_enabled` check (memory waste)
  - Do NOT skip dirty-bit clearing on VMCS12 load (stale bits cause false dirty)

  **Recommended Agent Profile**:
  - **Category:** `quick`
  - **Skills:** `[]`

  **Parallelization**: Wave 1 (with P1A, P1C–P1F). Blocks P4B, P5C.

  **References**:
  - `sys/amd64/vmm/intel/vmx_nested.h:78` (struct declaration)
  - `sys/amd64/vmm/intel/vmx.c:1273-1277, 3553-3556` (alloc/free)
  - `sys/amd64/vmm/intel/vmx_nested_shadow.c:27-38` (current stubs)
  - `sys/amd64/vmm/intel/vmx_nested_vmread.c:248-293` (vmwrite handler)

  **Acceptance Criteria**:
  - `git grep -nE 'vmcs_field_dirty' sys/amd64/vmm/intel/vmx.c` shows malloc + free
  - `make buildkernel` clean
  - ATF test passes
  - At least one FINDING file if audit issue found

  **QA Scenarios**:
  ```
  Scenario: Shadow VMCS dirty-bit set on VMWRITE → apply scrubs
    Tool: Bash + ATF
    Steps: 1. L1 issues VMWRITE to control field. 2. L1 issues VMLAUNCH. 3. Assert shadow apply scrubbed L0's VMCS.
    Expected Result: L2 runs without seeing L1's writes.
    Failure Indicators: L2 sees L1's writes (shadow bypass).

  Scenario: Shadow VMCS readonly field rejects VMWRITE
    Tool: Bash + ATF
    Steps: 1. L1 issues VMWRITE to VPID (readonly). 2. Assert VMFailValid with error code.
    Expected Result: VMFailValid, error = VMCS_RO_FIELD.
    Failure Indicators: Silent success (missing check).
  ```

  **Commit**: `vmm(intel): allocate + wire VMCS12 shadow bitmaps`

- [ ] P1C. Intel `vmx_nested_invept` + `vmx_nested_invvpid` — replace stubs

  **What to do**:
  - Implement `vmx_nested_invept_handle` (vmx_nested_invept.c:32-45) per Intel SDM §29.4: validate `type ∈ {SINGLE_CONTEXT, ALL_CONTEXTS, SINGLE_CONTEXT_NONGLOBAL}`; reject invalid descriptors; scope ALL_CONTEXTS to current VM
  - Implement `vmx_nested_invvpid_handle` (vmx_nested_invept.c:47-62) per Intel SDM §29.5: validate `type ∈ {INDIVIDUAL_ADDR, SINGLE_CONTEXT, ALL_CONTEXTS, SINGLE_CONTEXT_NONGLOBAL}`; validate VPID
  - Wire `vmx_nested_exit_invept` and `vmx_nested_exit_invvpid` (currently `return (-1)`) to dispatch to the handlers
  - RED test: `tests/sys/vmm/nested/negative/invept_invalid_descriptor.sh`
  - Audit finding: any descriptor type accepted without validation → FINDING

  **Must NOT do**:
  - Do NOT accept reserved descriptor types
  - Do NOT let ALL_CONTEXTS flush L0's TLB (only L1's view)

  **Recommended Agent Profile**: `quick`

  **Parallelization**: Wave 1. Blocks P4C, P6A.

  **References**:
  - `sys/amd64/vmm/intel/vmx_nested_invept.c:32-76`
  - Intel SDM Vol 3 §29.4 (INVEPT), §29.5 (INVVPID)

  **Acceptance Criteria**: `git grep 'return (-1)' sys/amd64/vmm/intel/vmx_nested_invept.c` returns nothing. ATF passes.

  **QA Scenarios**: 2 scenarios (invalid descriptor type; reserved descriptor type).

  **Commit**: `vmm(intel): real INVEPT/INVVPID with descriptor validation`

- [ ] P1D. Intel `vmx_nested_vmclear` — replace stub

  **What to do**:
  - Implement `vmx_nested_vmclear_handle` and `vmx_nested_exit_vmclear` (vmx_nested_vmclear.c:25-36) per Intel SDM §25.11.2: validate GPA alignment, read revision ID, set VMCS12 state to "clear", clear launch state
  - Wire to dispatcher at vmx.c:3042-3106
  - RED test: `tests/sys/vmm/nested/negative/vmclear_invalid_gpa.sh`
  - Audit finding: any state not properly transitioned → FINDING

  **Must NOT do**:
  - Do NOT modify VMCS12 state if GPA is not in L1-owned memory
  - Do NOT leak L0's VMCS state via vmclear (CVE-2018-12904 pattern)

  **Recommended Agent Profile**: `quick`

  **Parallelization**: Wave 1. Blocks P4A, P6A.

  **References**: `sys/amd64/vmm/intel/vmx_nested_vmclear.c:25-36`; Intel SDM §25.11.2.

  **Acceptance Criteria**: stub replaced; ATF passes.

  **Commit**: `vmm(intel): real VMCLEAR with state transition + CPL check`

- [ ] P1E. Intel `vmx_nested_vmlaunch` + `vmx_nested_vmresume` — replace stubs (HIGHEST PRIORITY)

  **What to do**:
  - Implement `vmx_nested_vmlaunch_handle` and `vmx_nested_exit_vmlaunch` (vmx_nested_vmlaunch.c:25-36) per Intel SDM §26.3.1.5: run ALL consistency checks (CR0/CR4 fixed bits, EFER.LMA/LME, VPID, EPTP, host-state fields, pin/cpu/exit/entry controls masked against L0 MSRs, unrestricted guest interactions)
  - Implement `vmx_nested_vmresume_handle` and `vmx_nested_exit_vmresume` (vmx_nested_vmresume.c:25-36) per Intel SDM §26.3.1.5: same checks as VMLAUNCH plus SMM/INT pending checks
  - Fix VMCS_INSTRUCTION_ERROR path: verify `vmcs_write(VMCS_INSTRUCTION_ERROR, ...)` is called while L0 VMCS is current (vmx_nested_vmptrld.c:117, 123)
  - RED test: 40 scenarios from Intel SDM §26.3.1.5 (see Appendix B for full list)
  - This is the HEADLINE path — most CVEs live here

  **Must NOT do**:
  - Do NOT skip ANY consistency check in §26.3.1.5
  - Do NOT trust VMCS12 fields without masking against L0 capability MSRs
  - Do NOT let host-state fields be L1-controlled
  - Do NOT panic L0 on consistency-check failure — VMFailValid to L1

  **Recommended Agent Profile**:
  - **Category:** `deep`
  - **Reason:** highest-impact path; touches every VMCS12 field; deep Intel SDM knowledge required

  **Parallelization**: Wave 1. Blocks P4A (critical), P6A, F1-F4.

  **References**:
  - `sys/amd64/vmm/intel/vmx_nested_vmlaunch.c:25-36`, `vmx_nested_vmresume.c:25-36`
  - `sys/amd64/vmm/intel/vmx.c:3042-3106` (dispatcher)
  - `sys/amd64/vmm/intel/vmx_nested_vmptrld.c:117, 123` (VMCS_INSTRUCTION_ERROR write)
  - Intel SDM Vol 3 §26.3.1.5 (full checklist)
  - Prior plan `.sisyphus/plans/nested-virt-register-virtualization.md` (T25 design)

  **Acceptance Criteria**:
  - `git grep 'return (-1)' sys/amd64/vmm/intel/vmx_nested_vmlaunch.c sys/amd64/vmm/intel/vmx_nested_vmresume.c` returns nothing
  - All 40 negative scenarios from Appendix B have ATF tests passing
  - At least 5 FINDING files expected (highest-finding path)

  **QA Scenarios**: 40 — full Appendix B negative scenarios.

  **Commit**: `vmm(intel): real VMLAUNCH/VMRESUME with full VMCS12 consistency checks`

- [ ] P1F. Intel `vmx_nested_vmcall` — replace stub

  **What to do**:
  - Implement `vmx_nested_vmcall_handle` and `vmx_nested_exit_vmcall` (vmx_nested_vmcall.c:25-36) per Intel SDM §26.2 (VM-exit reason 18)
  - Reflect VMCALL args to L0 log; do NOT execute unknown hypercalls
  - RED test: `tests/sys/vmm/nested/negative/vmcall_unknown_hypercall.sh`
  - Audit finding: any silent failure (vs VM-exit to L1) → FINDING

  **Must NOT do**: Do NOT silently exit nested mode on unknown hypercall (CVE-pattern)

  **Recommended Agent Profile**: `quick`

  **Parallelization**: Wave 1. Blocks P4A, P6A.

  **Commit**: `vmm(intel): real VMCALL with hypercall dispatch + log`

---

## Wave 2 — AMD SVM stubs to real implementations

- [ ] P2A. AMD `svm_nested_vmrun` — replace stub `return (1)` (HIGHEST PRIORITY for AMD)

  **What to do**:
  - Implement `svm_nested_vmrun` (svm_nested_stubs.c:34-39) per AMD APM Vol 2 §15.5 (VMRUN): validate VMCB GPA, ASID, nested-paging mode, intercept vectors, MSRPM/IOPM base addresses, event injection
  - Apply the CVE-2021-29657 EPYC escape checklist: validate `msrpm_base_pa` before use; track hsave area lifetime; prevent `nested.ctl` TOCTOU
  - Wire to dispatcher at svm.c (the wave5-fix-t25-dispatcher-wiring branch already added the call)
  - RED test: `tests/sys/vmm/nested/negative/svm_vmrun_invalid_asid.sh`, `svm_vmrun_msrpm_uaf.sh`
  - Audit finding: any TOCTOU on VMCB control fields → FINDING

  **Must NOT do**:
  - Do NOT call VMRUN with unvalidated VMCB GPA
  - Do NOT reuse hsave area across VMs
  - Do NOT let L1 write to `msrpm_base_pa` after validation

  **Recommended Agent Profile**: `deep` (CVE-2021-29657 mitigation requires deep AMD spec knowledge)

  **Parallelization**: Wave 2 (with P2B–P2F). Blocks P4D, P6B, P5D.

  **References**:
  - `sys/amd64/vmm/amd/svm_nested_stubs.c:34-39`
  - AMD APM Vol 2 §15.5 (VMRUN instruction)
  - Project Zero "An EPYC escape" (CVE-2021-29657)
  - `sys/amd64/vmm/amd/svm.c` (dispatcher call site)

  **Acceptance Criteria**: stub replaced; ATF tests pass; no CVE-2021-29657 pattern present.

  **QA Scenarios**: 8 scenarios covering ASID collision, MSRPM UAF, hsave lifetime, VMCB GPA validation.

  **Commit**: `vmm(amd): real svm_nested_vmrun with EPYC-escape-mitigation patterns`

- [ ] P2B. AMD `svm_nested_vmsave` — replace stub

  **What to do**: Implement per AMD APM §15.6 (VMSAVE): save state to VMCB; validate VMCB GPA before write.

  **Parallelization**: Wave 2; depends on P2A (shares VMCB validation logic). Blocks P4D.

  **Commit**: `vmm(amd): real svm_nested_vmsave`

- [ ] P2C. AMD `svm_nested_vmload` — replace stub

  **What to do**: Implement per AMD APM §15.4 (VMLOAD): load state from VMCB; validate VMCB GPA before read; prevent state injection from L1-controlled VMCB.

  **Parallelization**: Wave 2; depends on P2A.

  **Commit**: `vmm(amd): real svm_nested_vmload with VMCB read validation`

- [ ] P2D. AMD `svm_nested_clgi` + `svm_nested_stgi` — replace stubs

  **What to do**: Implement CLGI/STGI per AMD APM §15.7/§15.8 (Clear/Set Global Interrupt Flag). These must NOT actually clear global interrupts — they only reflect the L1 intent to L0. Pattern: shadow the GIF state in nested_state; actual GIF manipulation only on real VMRUN/VMSAVE.

  **Must NOT do**: Do NOT actually clear L0's GIF.

  **Parallelization**: Wave 2.

  **Commit**: `vmm(amd): real svm_nested_clgi/stgi with GIF shadow`

- [ ] P2E. AMD `svm_nested_skinit` — replace stub

  **What to do**: SKINIT is a Secure Initialization instruction (AMD APM §15.9). For nested: validate that L1's requested secure-loader block GPA is within L1-owned memory; do NOT execute the secure loader. Return VM-exit to L1 with failure indicator.

  **Parallelization**: Wave 2.

  **Commit**: `vmm(amd): real svm_nested_skinit with GPA validation`

- [ ] P2F. AMD `svm_nested_lookup` — replace `ns = NULL` stub

  **What to do**: Implement `svm_nested_lookup` (svm_nested_exit.c:94 — currently `ns = NULL`): given a vmcb12, return the `struct svm_nested` pointer. Currently returns NULL which causes every nested exit to fall through. Fix: hash table or per-vCPU pointer lookup.

  **Parallelization**: Wave 2. Blocks P4D, P6B.

  **Commit**: `vmm(amd): real svm_nested_lookup`

---

## Wave 3 — Cross-cutting hardening

- [ ] P3A. VMXON double-VMXON race + vCPU lock audit

  **What to do**: Fix double-VMXON at L1 (vmx.c:2990-3021 — currently un-checked); audit all vcpu_lock/vcpu_unlock pairs in nested paths for missing/extra unlocks; document findings.

  **Parallelization**: Wave 3. Blocks P4A.

  **Commit**: `vmm(intel): fix double-VMXON race + vCPU lock audit`

- [ ] P3B. AMD HSAVE_PA lifetime + msrpm_base_pa validation

  **What to do**: Audit HSAVE area allocation (svm.c); ensure no UAF path; validate `MSRPM_BASE_PA` on every VMRUN/VMLOAD/VMSAVE.

  **Parallelization**: Wave 3. Blocks P4D, P6B.

  **Commit**: `vmm(amd): HSAVE_PA lifetime + msrpm_base_pa validation`

- [ ] P3C. Intel CR/EFER emulation completeness

  **What to do**: Audit CR0/CR4/EFER emulators (vmx.c:2022-2097) for completeness per Intel SDM §27.1 (CR0/CR4/EFER); verify SVME/VMXE always-on bits; verify canonicalization of CR3.

  **Parallelization**: Wave 3. Blocks P4A.

  **Commit**: `vmm(intel): CR/EFER emulation completeness audit`

- [ ] P3D. AMD CR/EFER/SVME emulation completeness

  **What to do**: Audit AMD CR/EFER/SVME (svm.c) per AMD APM §15.5/§15.6; verify SVME always-on; verify canonicalization.

  **Parallelization**: Wave 3. Blocks P4D.

  **Commit**: `vmm(amd): CR/EFER/SVME emulation completeness audit`

---

## Wave 4 — STRIDE audit + per-path findings

- [ ] P4A. STRIDE audit of vmx_nested_vmptrld.c + vmx_nested_vmlaunch.c + vmx_nested_vmresume.c

  **What to do**: Apply full STRIDE checklist (Appendix C) to all three files. For each finding, create `.sisyphus/findings/FINDING-NNN-{slug}.md` with file:line, CVSS v3.1 score, remediation, verification. Run Grok review on each finding file.

  **Parallelization**: Wave 4. Blocks F1, F2.

  **Acceptance Criteria**: ≥ 5 finding files; each has Grok review companion file.

  **Commit**: per-finding commits with `audit(nested-virt): FINDING-NNN {slug}` format.

- [ ] P4B. STRIDE audit of vmx_nested_vmread.c (VMCS12 encoding→offset table)

  **What to do**: Audit VMCS12 field encodings (vmx_nested_vmread.c:55-176) for: missing fields, incorrect offsets, missing readonly flag, missing width validation.

  **Parallelization**: Wave 4.

  **Commit**: per-finding commits.

- [ ] P4C. STRIDE audit of vmx_msr.c nested MSR bitmap

  **What to do**: Audit MSR bitmap setup (vmx_msr.c:591-626) for: missing MSRs, wrong R/W bits, missing IA32_FEATURE_CONTROL validation, RDMSR/WRMSR nested path correctness.

  **Parallelization**: Wave 4.

  **Commit**: per-finding commits.

- [ ] P4D. STRIDE audit of svm.c nested dispatch + svm_nested_exit.c + svm_nested_intr.c

  **What to do**: Audit the nested SVM dispatch + exit reflection + interrupt injection paths.

  **Parallelization**: Wave 4.

  **Commit**: per-finding commits.

- [ ] P4E. STRIDE audit of npt.c nested NPT walk + invalidation

  **What to do**: Audit npt.c for: recursion depth, INVLPGA correctness, ASID tracking, page-walk reserved-bit checks.

  **Parallelization**: Wave 4.

  **Commit**: per-finding commits.

---

## Wave 5 — Custom tooling

- [ ] P5A. Semgrep rules for VMCS12 validation patterns

  **What to do**: Create `tools/semgrep-rules/vmcs12-validations.yaml` with rules for: missing CR0/CR4 fixed-bit checks, missing EPTP validation, missing INVEPT after EPT modification, missing canonicalization of RIP/RSP, missing CPL=0 check on VMX instruction handlers, missing vcpu_lock on error paths. Each rule must have a low false-positive rate on correct code.

  **Parallelization**: Wave 5. Blocks F2.

  **Commit**: `tools(semgrep): add VMCS12 validation rules`

- [ ] P5B. Semgrep rules for VMCB validation patterns

  **What to do**: Mirror P5A for AMD VMCB.

  **Parallelization**: Wave 5.

  **Commit**: `tools(semgrep): add VMCB validation rules`

- [ ] P5C. libFuzzer harness for VMCS12 field encodings

  **What to do**: Create `tests/sys/vmm/nested/fuzz/fuzz_vmcs12.c` — libFuzzer harness that generates random VMCS12 field encodings and feeds them through `vmx_nested_vmread`/`vmx_nested_vmwrite`. Goal: cover all 76 entries in `vmcs12_fields[]` (vmx_nested_vmread.c:55-176) with random values. Verify no crash, no assertion failure.

  **Parallelization**: Wave 5.

  **Commit**: `tests(fuzz): libFuzzer harness for VMCS12 field encodings`

- [ ] P5D. libFuzzer harness for VMCB field encodings

  **What to do**: Mirror P5C for VMCB.

  **Parallelization**: Wave 5.

  **Commit**: `tests(fuzz): libFuzzer harness for VMCB field encodings`

---

## Wave 6 — Negative tests

- [ ] P6A. 40 L1-misbehavior ATF tests for Intel VMX

  **What to do**: Implement all 40 scenarios from Appendix B as ATF tests under `tests/sys/vmm/nested/negative/`. Each test: setup isolated bhyve VM with nested enabled; inject a malformed L1 input; assert VMFailValid with correct error code (or graceful rejection).

  **Parallelization**: Wave 6 (depends on P1A–P1F, P5A). Blocks P7A, P7B.

  **Commit**: per-test commits or batched.

- [ ] P6B. 40 L1-misbehavior ATF tests for AMD SVM

  **What to do**: Mirror P6A for AMD SVM with the 40 SVM-specific negative scenarios (see Appendix D).

  **Parallelization**: Wave 6.

  **Commit**: per-test commits or batched.

- [ ] P6C. AMD in-kernel self-tests mirroring Intel's 5-test set

  **What to do**: Add 5 in-kernel self-tests in `svm_nested_test.c` mirroring Intel's T17 (`vmx_nested_test.c`): MSR_VM_HSAVE_PA read, ASID alloc, hsave alloc, CR4.SVME bit, MSRPM bitmap setup.

  **Parallelization**: Wave 6.

  **Commit**: `vmm(amd): 5 in-kernel SVM nested self-tests`

---

## Wave 7 — EFI/non-EFI harness + cross-arch CI

- [ ] P7A. qemu + OVMF (EFI) + SeaBIOS (non-EFI) harness for CI

  **What to do**: Create `tools/qemu-ovmf-harness/` with reproducible EFI and non-EFI boot configurations. CI integration via Cirrus CI `.cirrus.yml`.

  **Parallelization**: Wave 7. Blocks P7B, P7C.

  **Commit**: `tools(qemu): add OVMF/SeaBIOS reproducer harness`

- [ ] P7B. Multi-host CI orchestration (fredev001 Xeon OFF + fredev002 old Intel + fredev003 Tiger Lake i9 + fredev004 Xeon OFF + fredev005 EPYC + fredev006 EPYC + 172.16.176.131 Ryzen 9; 5 active at any time, skip-list for unavailable hosts)

  **What to do**: Wire `.cirrus-ci/` to run the test matrix on three host types. Lab-host-only kernel-module-load safety contract: module loads happen only inside isolated bhyve VMs on fredev005.

  **Parallelization**: Wave 7.

  **Commit**: `.cirrus-ci: multi-host test matrix`

- [ ] P7C. Per-CPU-family config matrix

  **What to do**: Document and test per-CPU-family variations: Tiger Lake (fredev003 i9-11950H), Ivy Bridge, AMD EPYC variants. Add per-CPU skip lists for tests that don't apply.

  **Parallelization**: Wave 7.

  **Commit**: `tests: per-CPU-family config matrix`

---

## Wave 8 — Integration + KVM-parity + ABI

- [ ] P8A. L1+L2 launch integration test extension (AMD SVM host)

  **What to do**: Extend `tests/sys/vmm/nested/integration/bhyve_in_bhyve.sh` to run on AMD EPYC host (currently AMD-SVM referenced but Intel-host-only execution).

  **Parallelization**: Wave 8.

  **Commit**: `tests(integration): AMD SVM L1+L2 launch extension`

- [ ] P8B. KVM parity conformance test extension

  **What to do**: Extend `tests/sys/vmm/nested/parity/kvm_parity_check.sh` to validate VMCS12/VMCB field mapping parity with KVM goldens.

  **Parallelization**: Wave 8.

  **Commit**: `tests(parity): VMCS12/VMCB field parity extension`

- [ ] P8C. ABI snapshot regen + golden-file comparison

  **What to do**: Regen `tests/sys/vmm/nested/abisnap/golden_abisnap.txt` and add diff comparison to CI.

  **Parallelization**: Wave 8.

  **Commit**: `tests(abisnap): golden-file regen + CI diff`

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents run in PARALLEL. ALL must APPROVE. Plus mandatory Grok cross-reference on every finding file.
> Do NOT auto-proceed after verification. Wait for user's explicit approval.

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists. For each "Must NOT Have": search codebase for forbidden patterns. Check evidence files exist in `.sisyphus/evidence/`. Verify all stub returns replaced (no `return (-1)` / `return (1)` in nested paths except as documented error returns). Compare deliverables against plan.

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run Semgrep + cppcheck on the diff. Review all changed files for: missing CPL=0 checks, missing vcpu_lock/unlock pairs, missing canonicalization of RIP/RSP, missing INVEPT/INVLPGA after EPT/NPT modification, missing ASID/VPID validation. Check AI slop: excessive comments, over-abstraction, generic names.

- [ ] F3. **Real Multi-Host QA** — `unspecified-high`
  Execute EVERY QA scenario from EVERY path on:
  - Intel VMX host (Tiger Lake / Ivy Bridge / whichever available)
  - AMD EPYC host
  - fredev005 lab host (kernel module load only, per safety contract)
  Verify each scenario's evidence file exists. Test cross-path integration (full L1→L2 boot). Test edge cases: empty VMCS12, max ASID exhaustion, rapid VMPTRLD, EPT/NPT walk with bad PTE. Save to `.sisyphus/evidence/final-qa/`.

- [ ] F4. **Scope Fidelity + Grok Cross-Reference** — `deep`
  For each path: read "What to do", read actual diff (git log/diff). Verify 1:1 — everything in spec was built, nothing beyond spec. Check "Must NOT do" compliance. Verify EVERY finding file has a Grok review (look for `.sisyphus/findings/*-grok-review.json` companion files). Flag any unaccounted changes.

---

## Commit Strategy

- **One commit per path** after RED-GREEN-REFACTOR + audit
- Message format: `vmm({intel|amd}): {action} for {path}` (e.g. `vmm(intel): real EPT12 walk + EPTP validation`)
- Include evidence path in commit body for cross-reference
- Per-path atomic commits — never batch

---

## Success Criteria

### Verification Commands

```bash
# Stub replacement verification
git -C /home/mlapointe/secure/git/freebsd-src-nested-vm grep -nE 'return \((-1|1)\)' sys/amd64/vmm/intel/vmx_nested*.c sys/amd64/vmm/amd/svm_nested*.c
# Expected: no results from nested-virt files (only legacy non-nested returns)

# Build verification
make -C /home/mlapointe/secure/git/freebsd-src-nested-vm buildkernel
# Expected: clean build, no new warnings

# Test verification (inside isolated bhyve VM)
kyua test -k /usr/tests tests/sys/vmm/nested/
# Expected: all tests pass

# Semgrep custom rules verification
semgrep --config=tools/semgrep-rules/ sys/amd64/vmm/intel/vmx_nested*.c sys/amd64/vmm/amd/svm_nested*.c
# Expected: zero findings on audited code (findings fixed during per-path REFACTOR)

# Fuzzer verification
cd /home/mlapointe/secure/git/freebsd-src-nested-vm/tests/sys/vmm/nested/fuzz && ./fuzz_vmcs12 corpus/ -max_total_time=300
# Expected: no crashes, coverage > 80% of VMCS12 field encodings

# Multi-host verification (5 active hosts; fredev001/fredev004 skipped when OFF)
ACTIVE_HOSTS="fredev002 fredev003 fredev005 fredev006 mlapointe@172.16.176.131"
for h in $ACTIVE_HOSTS; do
  ssh $h "kyua test -k /usr/tests tests/sys/vmm/nested/"
done
# Conditional: if fredev001 or fredev004 are powered ON, also run
for h in fredev001 fredev004; do
  if ping -c 1 -W 2 $h >/dev/null 2>&1; then
    ssh $h "kyua test -k /usr/tests tests/sys/vmm/nested/"
  fi
done
# Expected: all active hosts pass; OFF hosts skipped

# Findings directory verification
ls -la /home/mlapointe/secure/git/freebsd-src-nested-vm/.sisyphus/findings/ | wc -l
# Expected: >= 1 finding per path = at least 28 finding files

# Grok review companion files verification
find /home/mlapointe/secure/git/freebsd-src-nested-vm/.sisyphus/findings/ -name '*-grok-review.json' | wc -l
# Expected: matches findings count (one per finding)
```

### Final Checklist

- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] All tests pass on Intel + AMD + fredev005
- [ ] Every finding file has CVSS + file:line + remediation + Grok review
- [ ] Custom tooling wired into CI
- [ ] User explicit approval received

---

## Appendix A: Stub Inventory (initial scan)

To be verified and extended by agent during implementation phase. Stub count is intentionally tallied here so the impl phase can be sized:

**Intel (`sys/amd64/vmm/intel/`)**:
- `vmx_nested_vmclear.c:25-30` — `return (-1)`
- `vmx_nested_vmlaunch.c:25-30` — `return (-1)`
- `vmx_nested_vmresume.c:25-30` — `return (-1)`
- `vmx_nested_vmcall.c:25-30` — `return (-1)`
- `vmx_nested_invept.c:64-69` — `return (-1)`
- `vmx_nested_invvpid.c:71-76` — `return (-1)`
- `vmx_nested_shadow.c:27-32` — `return (0)`
- `vmx_nested_shadow.c:34-38` — `return (-1)`
- `vmx_nested_ept12.c:49` — `TODO(mvp)` (identity-map fallback)
- `vmx_nested.h:78` — `vmcs_field_dirty`/`vmcs_field_ro` declared but never allocated
- `vmx.c:151-152` — `nested_vmcs12_region[MAXCPU]` TODO relocate to per-vCPU

**AMD (`sys/amd64/vmm/amd/`)**:
- `svm_nested_vmrun` — `return (1)`
- `svm_nested_vmsave` — `return (1)`
- `svm_nested_vmload` — `return (1)`
- `svm_nested_clgi` — `return (1)`
- `svm_nested_stgi` — `return (1)`
- `svm_nested_skinit` — `void` (no return)
- `svm_nested_exit.c:94` — `ns = NULL; /* stub: svm_nested_lookup not yet implemented */`

---

## Appendix B: Intel VMX Negative Scenarios (40+)

Each scenario produces an ATF test under `tests/sys/vmm/nested/negative/`:

1. Junk VMCS12 with `revision_id = 0xFFFFFFFF` → expect VMFailInvalid
2. Valid-looking VMCS12 with inconsistent host-state (host_rip non-canonical)
3. `pin_based_vm_exec_control` with `default1` bit (bit 2) cleared → VMFailValid
4. `secondary_vm_exec_control` bits set with `activate_secondary_controls=0` → VMFailValid
5. `vmcs_link_pointer` to invalid GPA → VMFailValid
6. `ept_pointer` pointing to L0 memory → VMFailValid
7. `msr_bitmap` pointing to L0 memory → VMFailValid
8. `virtual_apic_page_addr` non-4KB-aligned → VMFailValid
9. VMCS12 pinned to read-only page → VMFailValid
10. L1 forces L2 to VM-exit 1M times → L1 throttles or kills L2
11. L2 VMPTRLD that collides with L1's own VMCS → handled
12. L1 forks while L2 running → documented undefined OR safe cleanup
13. L1 migrates while L2 running → documented undefined
14. L1 INVEPT type 0 on EPTP not in L1's set → no-op
15. L1 INVEPT type 1 → scoped to L1
16. L1 INVVPID type 0 on VPID not in L1's set → no-op
17. L1 starts L2 with vmcs_link_pointer != ~0 then VMCS12 unloaded → VM-exit "VMPTRLD invalidation"
18. L2 VMCALL with unknown hypercall number → VM-exit to L1
19. L2 VMFUNC with out-of-range function index → VMFailValid
20. L2 INVPCID → verify EPT12 honors it
21. exception_bitmap with #MC but MONITOR/MWAIT not intercepted → VMFailValid
22. `vm_exit_msr_load_count` = 512 with address pointing to L0 memory → VMFailValid
23. URG=1 with CR0.PE=0 and CR0.PG=1 → VMFailValid
24. URG=0 with CR0.PE=0 → VMFailValid
25. URG=0 with CR0.PG=0 → VMFailValid
26. CR4.VMXE=0 → VMFailValid
27. CR4.PAE=0 and EFER.LME=1 → VMFailValid
28. CR4.LA57=1 but L0 doesn't support 5-level paging → VMFailValid
29. guest_ia32_efer.LMA=1 but guest_cr0.PG=0 → VMFailValid
30. guest_ia32_efer.LMA=0 but guest_cr0.PG=1 and CS.L=1 → VMFailValid
31. guest_interruptibility_info with reserved bit 4 = 1 → VMFailValid
32. guest_activity_state=2 (HLT) but vmcs_link_pointer != ~0 → VMFailValid
33. guest_pending_dbg_exceptions with reserved bits set → VMFailValid
34. ple_gap!=0 and ple_window=0 → VMFailValid
35. virtual_processor_id=0 and enable_VPID=1 → VMFailValid
36. L1 writes to shadow VMCS but L0 doesn't support shadow VMCS → VMFailValid
37. L1 killed (process exit) with L2 still mapped → clean teardown
38. guest_rsp non-canonical → VMFailValid
39. guest_rip non-canonical → VMFailValid
40. guest_rflags with reserved bits (1, 3, 5, 15, 22) set → VMFailValid

Plus 10+ additional scenarios from `tests/sys/vmm/nested/negative/escape_negative.sh` and `vmx_negative.sh`.

---

## Appendix C: STRIDE Checklist (full)

For each file in nested-virt scope, walk the STRIDE categories:

**S — Spoofing**: L1 spoofs L2's perceived host-state; L1 spoofs CPUID/features; L2 spoofs L1 via VMCS12; L2 spoofs host CR/EFER.

**T — Tampering**: VMCS12 fields not validated by L0; EPT12 pointer tampering; I/O bitmap addresses; MSR bitmap; VMCS link pointer; exception bitmap; CR0/CR4 fixed bits; VPID; APIC-virt addresses; APICv/posted-interrupt fields.

**R — Repudiation**: L1 silently modifies VMCS12 between VMPTRLD and VMLAUNCH; L1 issues VMXON with forged revision_id; VMCS12 corruption unnoticed; L1 silently leaves nested mode; L1 chains unlimited VMXOFF/VMXON.

**I — Information Disclosure**: L1 sees L0's host RIP/RSP via VMCS12; L1 sees L0's MSR save/load addresses; L1 reads guest-physical addresses it shouldn't; L1 enumerates L0 features via VMCS12; L1 reads VMCS12 fields from another L1's VMCS; host state leaks via padding/extension; side-channel via VM-exit timing; memory drift via stale EPT.

**D — Denial of Service**: L1 crashes L0 via VMCS consistency-check failure; L1 exhausts L0 memory via rapid VMCS12 alloc/free; L1 DoS via deeply nested EPT; L1 DoS via infinite VM-exit loop; L1 DoS via malformed VMCS12; L2 DoS L1 via VMCALL/VMRESUME looping; forced host-cpu lockup via treat-pin-as-nmi; L1 corrupts L0 via APIC-access page poisoning.

**E — Elevation of Privilege**: L1→L0 via VMCS12 misvalidation; L1→L0 via shadow VMCS; L1→L0 via EPT mis-walk; L2→L1 via VMCS12 manipulation; L2→L0 via double-handler chain; L1→L0 via IA32_SPEC_CTRL/IA32_PRED_CMD MSR exposure; L1→L0 via arch MSR write (IA32_LSTAR); L1→L0 via posted-interrupt descriptor; L1→L0 via EPTP pointing to L0 memory; L2→L0 via VMFUNC.

---

## Appendix D: AMD SVM Negative Scenarios (40+)

Mirror of Appendix B for AMD SVM. Key AMD-specific scenarios:

1. Junk VMCB with `vmcb revision != 1` → VMFailInvalid
2. VMCB with invalid ASID (0 reserved, > 32767 invalid)
3. VMCB with invalid nested-paging mode
4. `MSRPM_BASE_PA` pointing to freed memory (CVE-2021-29657 pattern)
5. `IOPM_BASE_PA` pointing to L0 memory
6. HSAVE area collision between VMs (use-after-free)
7. TSC_OFFSET causing TSC wrap → VMFailValid
8. LBR_VIRTUALIZATION_ENABLE without L0 support → VMFailValid
9. VIRT_SAVE_SPEC_CTRL on CPU without the feature → VMFailValid
10. NPT root with reserved bits set → VMFailValid
11. NPT walk exceeding 4 levels (or 5 for LA57) → VMFailValid
12. NPT PTE with reserved MBZ bits → VMFailValid
13. V_INTR_MASKING without L0 support → VMFailValid
14. EVENTINJ with reserved class → VMFailValid
15. EVENTINJ with vector=0 and type=exception → VMFailValid
16. INTERCEPT with reserved bit set → VMFailValid
17. L2 VMRUN while L1's GIF shadow says interrupts should be enabled → VMFailValid
18. L2 SKINIT with secure-loader block outside L1 memory → VMFailValid
19. L2 CLGI/STGI trying to manipulate real L0 GIF → reject
20. L1 INVLPA on ASID not in L1's set → no-op
21. L1 INVLPA on all (type 1) → scoped to L1
22. L1 TLBSYNC → scoped to L1
23. L2 invokes VMSAVE with VMCB outside L1 memory → VMFailValid
24. L2 invokes VMLOAD with VMCB outside L1 memory → VMFailValid
25. VMRUN double-invocation (CVE-2021-29657 core pattern) → VMFailValid
26. SVME bit clear attempt → VMFailValid
27. EFER.SVME clear attempt → VMFailValid
28. CR0.PG=0 with EFER.LME=1 → VMFailValid
29. CR4.PAE=0 with EFER.LME=1 → VMFailValid
30. L2's CS.L=1 but EFER.LMA=0 → VMFailValid
31. Plus 10+ additional from `tests/sys/vmm/nested/negative/svm_negative.sh` and `msr_negative.sh`.

---

## Appendix E: Tools Inventory

Tools available for the audit:

- **semgrep** (`/home/mlapointe/.local/bin/semgrep`): custom rules in `tools/semgrep-rules/`
- **trivy** (`/home/mlapointe/.local/bin/trivy`): SCA, IaC, secrets, license
- **gitleaks** (`/home/mlapointe/.local/bin/gitleaks`): git history secret scan
- **codeinspectus MCP**: SAST + secrets + vuln + IaC + license + AI code (Opengrep + Gitleaks + Trivy + custom)
- **sast-mcp-server**: Semgrep, Bandit, Bearer, Trivy, Checkov, CodeQL
- **operant MCP**: web/HTTP recon (NOT applicable to kernel; flag as N/A in plan)
- **agent-bom MCP**: AI supply chain (NOT applicable to kernel; flag as N/A in plan)
- **Honcho**: memory/peers (context tracking only)
- **Grok validator MCP** (via grok-validator MCP): cross-reference on every plan + finding

Custom tooling the audit must build:
- Semgrep rules for VMCS12/VMCB validation (P5A, P5B)
- libFuzzer harnesses for VMCS12/VMCB (P5C, P5D)
- QEMU + OVMF/SeaBIOS harness (P7A)
- Multi-host Cirrus CI matrix (P7B)
- Per-CPU-family config matrix (P7C)
