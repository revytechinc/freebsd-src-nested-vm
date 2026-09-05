# Local reviewer findings — nested-virt sources

Produced by the local PR-Agent pass (see the `local-code-review` skill), one
file at a time, each presented as a whole-file diff so the code is judged as it
stands rather than by its last edit.

**Every item here is a claim, not a verdict.** Confirm or disprove each one
against the source before acting on it: several are explicitly hedged by the
reviewer as depending on code it could not see. Mark each as CONFIRMED, 
DISPROVED or FIXED as it is worked.


## sys/amd64/vmm/intel/vmx_nested_entry.c

- **Use After Free** — `vmx_nested_ept02_cleanup()` frees `ns->msr_bitmap02` but never sets it (or `msr_bitmap02_pa`) back to NULL, while it does NULL out `ept02` and `vmcs02`. If the vCPU's nested state is ever rebuilt after a cleanup, `vmx_nested_build_vmcs02()` sees the stale non-NULL pointer, skips reallocation, and both memcpy/memsets into freed memory and programs `VMCS_MSR_BITMAP` with a physical address of a freed (possibly reused) page — meaning L2's MSR interception is then governed by unrelated memory. The stray un-indented `if` on the same lines also suggests this hunk was edited hastily and deserves a second look.

- **Stale TLB** — `vmx_nested_ept02_flush()` performs only a local single-context INVEPT on the current CPU. The justification (per-vCPU shadow, re-entered on THIS CPU) does not hold across vCPU thread migration: if the vCPU previously ran L2 on CPU A, migrates, flushes on CPU B, and later migrates back to CPU A, CPU A's TLB can still hold guest-physical translations tagged with `ept02_eptp` that were never invalidated, so L2 can read/write pages through mappings that `pmap_remove()` already tore down (e.g. after an L1 INVEPT that repurposed the L2 GPA). What remains uncertain is whether some other path performs a broader invalidation on migration; if not, this is a correctness hole with data-corruption impact, which is why it is flagged despite the uncertainty.

- **Contract Mismatch** — The header comment for `vmx_nested_l2_exit()` documents only two return values (1 = resume L2, 0 = reflected to L1), but the `EXIT_REASON_EPT_FAULT` case returns 2 to signal "leave vmx_run to defer". Any caller written against the documented contract (e.g. treating nonzero as "resume L2") would resume L2 without handling the deferred EPT work, re-triggering the same fault forever. The comment should enumerate the 2 case so future callers and reviewers handle it explicitly.


## sys/amd64/vmm/intel/vmx_nested_insn.c

- **Possible Issue** — Every VMXINSN handler that injects a fault (e.g. `vmx_nested_exit_vmxon` calling `vm_inject_ud`/`vm_inject_gp`) still returns 0, and `vmx_nested_op` then unconditionally advances `vme->rip` by the instruction length. Architecturally a faulting VMX instruction must be reported at (and restarted from) the faulting RIP, not past it. `vm_inject_fault` does call `vm_restart_instruction`, but on a FROZEN vcpu that sets `nextrip` from the current VMCS `GUEST_RIP` *before* this function overwrites `vme->rip`; if the modified `vm_run` recomputes `nextrip` from `vme->rip` after `vmm_ops.nested` returns, the queued #UD/#GP is delivered with L1's RIP already advanced past the instruction. What remains uncertain is the exact ordering in the (out-of-diff) `vm_run` changes — worth verifying that the restart wins over the advanced `vme->rip`.

- **Contract Violation** — `vmx_nested_decode_mem_operand` returns -1 for a register operand (`INSN_INFO_MEMREG` set) without injecting any fault, but the function's documented contract — which callers rely on — is that -1 means a fault was already delivered to L1. As a result, an L1 executing a register-form encoding of VMXON/VMPTRLD/etc. (which should raise #UD) instead completes silently: no exception, no RFLAGS status bits set, and RIP advanced past the instruction. An L1 hypervisor probing behavior, or simply buggy, observes an instruction that neither succeeds, fails, nor faults.

- **NULL Dereference** — In the `VM_NESTED_OP_L2_EPT` path, `ns` from `vmx_nested_state()` is dereferenced (`!ns->in_l2`) without a NULL check, unlike every other entry point in this file (`vmx_nested_insn_check`, `vmx_nested_exit_vmxon`, `vmx_nested_vmfail_valid` all guard it). If a deferred L2-EPT exit can ever be processed after nested state is torn down or was never allocated (e.g. a stale exit raced with VMXOFF handling or nested being disabled), this is a kernel panic triggerable from guest-driven timing. Low likelihood if the exit's existence implies nested state, but the inconsistency with the surrounding defensive checks makes it worth closing.


## sys/amd64/vmm/amd/svm_nested_stubs.c

- **Guest-triggerable host DoS:** — the two issues above (intercept re-read race and unchecked IOPM/MSRPM holds) each allow a malicious or unlucky multi-vCPU L1 guest to steer the L0 exit handler toward consulting NULL bitmap pointers inside a critical section, crashing the host. Both are reachable from unprivileged-relative-to-L0 guest code, so they should be treated as security fixes, not just robustness.

- **Incomplete TOCTOU fix** — The comment above the snapshot block says "Use only these locals hereafter" because `vmcb12` stays mapped writable, yet the VMCB02 composition re-reads `vmcb12->ctrl.intercept[i]` when OR-ing intercepts (and again for the `VMCB_INTCPT_VINTR` counter). A second L1 vCPU can set `VMCB_INTCPT_IO` or `VMCB_INTCPT_MSR` after the `intcpt1` snapshot (when no IOPM/MSRPM pages were held) but before this re-read, so L2 runs with the IO/MSR intercept active while `ns->l1_iopm`/`ns->l1_msrpm` are NULL. The exit handler, which per the comments consults these maps inside a critical section, would then dereference NULL — a guest-triggerable host crash. The OR should use snapshotted intercept values.

- **Unchecked holds** — The `vm_gpa_hold()` calls for L1's IOPM (3 pages) and MSRPM (2 pages) are not checked for failure. Alignment is validated, but an L1 that points `iopm_base_pa`/`msrpm_base_pa` at an aligned GPA outside its memory map (or whose last page falls past the end of a segment) gets NULL back, and VMRUN proceeds anyway. The exit handler that later consults these maps runs in a critical section where it "cannot take them then", so a NULL entry there cannot be recovered lazily and risks a NULL dereference on the first intercepted L2 IO/MSR access. On hold failure the VMRUN should fail with #VMEXIT(INVALID) like the other validation paths. Uncertainty: the exit-handler code is not in this diff, so whether it NULL-checks the map pointers cannot be confirmed here.

- **Leftover instrumentation** — The blocks incrementing `svm_l2_inj_total`, `svm_l2_inj_vec`, `svm_l2_vmruns`, `svm_l2_vintr_want` and `svm_l2_notintr` declare the globals via `extern` inside the function body and run unconditionally on the hot VMRUN path, not gated by `svm_nested_debug`. This reads as bring-up scaffolding: unsynchronized read-modify-write of shared counters from multiple vCPUs loses updates, and the in-function extern declarations bypass any header prototype checking. Either gate and properly declare them or remove them before this ships.


## sys/amd64/vmm/intel/vmx_nested_test.c

- **Panic Risk** — Tests 1, 4 and 5 gate only on the vendor string (`cpu_vendor == "GenuineIntel"`), not on the CPU actually advertising VMX (`CPUID.1:ECX.VMX`). On an Intel CPU without VMX — most realistically, this module loaded inside a plain bhyve/other guest that does not expose nested VMX — `rdmsr(MSR_VMX_BASIC)` and `rdmsr(MSR_VMX_CR0_FIXED0/1)` hit unimplemented MSRs and `load_cr4(before | CR4_VMXE)` sets an unsupported CR4 bit; both raise #GP in kernel mode and panic the machine at kldload time. Given this module exists precisely to probe nested-virt setups, loading it in a guest is a likely scenario. Each Intel-gated test needs an additional `(cpu_feature2 & CPUID2_VMX)` (and ideally IA32_FEATURE_CONTROL lock/enable) check before touching VMX MSRs or CR4.VMXE.

- **CPU Migration** — The CR4.VMXE toggle performs `rcr4()` / `load_cr4()` / `rcr4()` / `load_cr4()` with no `critical_enter()` or CPU pinning, but CR4 is per-CPU state and the MOD_LOAD thread is preemptible. If the thread migrates mid-sequence, the value read on one CPU is written to another: on a host where VMXE was clear (vmm.ko not loaded), this can leave CR4.VMXE permanently set on the first CPU and never toggle it on the second (a silent false PASS/FAIL), and in general it writes a stale CR4 image onto a different CPU. Wrap the read-modify-restore sequence in `critical_enter()`/`critical_exit()` (or `sched_pin()`) so the whole toggle happens on one CPU.

- **Misleading Assertion** — The compile-time check that `nvmcs12` and `vmcs` sit at different offsets is a tautology: two distinct members of the same struct can never share an offset, so the CTASSERT (and its runtime twin in test 3) can never fire and does not guard against the described regression of `nvmcs12` being removed or aliased — if the member were deleted outright, the `__offsetof` simply fails to compile, which the first CTASSERT operand already covers. The runtime re-check in test 3 likewise always passes. This inflates the PASS count without testing anything; asserting what actually matters (e.g. that `nvmcs12` exists and `sizeof(struct vmcs) == PAGE_SIZE`, which is already covered) would be honest, and the offset comparison should be dropped.


## sys/amd64/vmm/intel/vmx_nested_ept12.c

- **EPTP Not Validated** — The walker consumes `ns->ept12_pte` as a raw EPTP and only checks that the address bits are non-zero. The EPTP's low control bits (memory type, page-walk-length field, accessed/dirty enable) are masked off and never validated, and the walk is hardwired to 4 levels. If the VMWRITE/install path does not reject unsupported EPTP encodings (notably a 5-level walk-length value), this walker will silently misinterpret L1's top-level table as a PML4 and produce wrong translations rather than reflecting a failure to L1. Uncertain: the install-side validation is not visible in this diff; if `vmx_nested_ept12_install` callers already reject non-4-level EPTPs, this reduces to a defensive-check gap.

- **Misconfig Fidelity** — The per-level permission check only requires the single requested access bit, and the "empty PTE" check accepts any of R/W/X. An entry with write permitted but read clear is an architecturally misconfigured EPT entry that real hardware faults on, yet a `VM_PROT_WRITE` walk here treats it as a successful translation. Similarly, a PML4E with the size bit (bit 7) set is misconfigured but is followed as a normal non-leaf pointer. The result stays confined to L1's own physical address space, so this is a guest-visible behavioral divergence (L2 proceeds where real hardware would deliver an EPT-misconfiguration exit to L1), not an L0 isolation break.

- **Combined Access Rejected** — The `access` switch returns -1 for anything other than exactly one of `VM_PROT_READ`/`VM_PROT_WRITE`/`VM_PROT_EXECUTE`. VM_PROT values are a bitmask, and fault paths commonly form combined protections (e.g. read-modify-write emulation requesting read and write together). Any caller passing a combined mask gets a hard translation failure with no distinguishing error, which would surface as a spurious nested EPT fault. If all current callers pass a single bit this is latent, but the restriction is enforced silently at the deepest layer rather than asserted or documented at the call boundary.


## sys/amd64/vmm/amd/svm_nested_exit.c

- **Possible Issue** — `svm_nested_l1_iopm_intercepts` tests only the IOPM bit for the starting port and ignores the access size encoded in EXITINFO1. Hardware checks one bit per byte of the access, so a 16- or 32-bit access spanning into an intercepted port (e.g. L1 marks port P+1 but L2 does a word OUT to P at the edge of an emulated device's range) causes a real #VMEXIT, yet this check concludes L1 did not ask for it and the exit is handled by L0 instead of being reflected — L1's device emulation silently misses part of the access.

- **Intercept Clobbering** — On reflection, the VINTR intercept bit in VMCB12 is rewritten to track `v_irq`. Hardware never modifies a guest's intercept vectors on #VMEXIT; this rewrite bakes in one specific L1 invariant (V_IRQ and VINTR always toggled together). An L1 hypervisor that keeps the VINTR intercept set independently of V_IRQ — or that had V_IRQ clear at exit time — has its intercept configuration silently cleared in its own VMCB, so its next VMRUN loses the interrupt-window exit it configured and a pending injection can stall indefinitely. The stated goal of supporting unmodified guest hypervisors makes this worth verifying against a non-bhyve L1; the impact depends on whether any supported L1 decouples the two bits.


## sys/amd64/vmm/intel/vmx_nested_layout.c

- **Init Race** — `vmcs12_layout_init()` mutates the shared `vmcs12_fields_table` (assigning `f->offset`) and sets `vmcs12_layout_ready` with no lock, atomic, or memory barrier, yet it is invoked from `vmcs12_lookup()`/`vmcs12_at()` which can be reached concurrently by multiple vCPU threads on first use. Two threads can run the loop simultaneously, and a third can read offsets while they are being (re)written. On amd64 this is likely benign only by accident — the recomputed values are identical, aligned stores are not torn, and TSO orders the flag store after the offset stores — but nothing enforces that against compiler reordering of the `vmcs12_layout_ready = true` store. Either compute the offsets at compile time / module load (e.g. from `vmx_modinit()` or a SYSINIT), or make the flag an atomic with release/acquire semantics.

- **Hot-path Lookup** — `vmcs12_lookup()` does a linear scan over ~130 entries for every emulated VMREAD/VMWRITE. On hardware without VMCS shadowing (the legacy no-shadowing case this project explicitly targets), every L1 VMREAD/VMWRITE traps and hits this path, and L1 hypervisors issue dozens of these per L2 world switch — so this scan multiplies into thousands of comparisons per nested entry/exit. Since the encoding set is fixed, a sorted table with binary search or a small direct-index/hash keyed on the encoding's index bits would remove the O(n) cost with little code. Worth measuring against the stock baseline before and after, given VMREAD/VMWRITE emulation dominates the non-shadowing nested path.


## sys/amd64/vmm/amd/svm_nested_npt.c

- **Missing A/D Emulation** — The shadow walk reads L1's nested page table but never writes back accessed/dirty bits, whereas hardware sets A/D in nested page table entries during the walk. Because NPT02 is filled with the full granted permissions, a subsequent L2 write to an already-shadowed page takes no further #NPF, so L1 can never observe a dirty bit for it. An L1 hypervisor that relies on NPT D-bits (e.g. dirty-page tracking for live migration) will see clean pages that L2 actually modified, causing silent data loss in the migrated guest. This mirrors the accessed/dirty-emulation gap previously fixed on the Intel EPT side.

- **Wrong pmap_enter Flags** — `pmap_enter()` is passed `prot` (the permissions granted by L1's table) as the `flags` argument, but that argument encodes the access type of the current fault plus `PMAP_ENTER_*` flags. When L1 grants write permission, every fault — including pure read or instruction-fetch faults — is treated as a write access, so `pmap_enter()` eagerly dirties the backing page. This over-dirties L1 guest memory on read-only access patterns; the fault's actual `access` value should be passed as the flags argument instead.

- **Misattributed Fault** — When `svm_nested_read_l1()` fails to read a table entry — meaning L1's own N_CR3 or an intermediate table points at memory L1 does not have — the failure is reflected to L1 as a not-present #NPF for the L2 GPA `g2`. Real hardware would fault on the table access itself (reporting the walk failure, not a clean not-present translation), so an L1 hypervisor with a buggy or maliciously crafted table sees a plausible-looking L2 fault it may retry forever, spinning the vCPU instead of surfacing the misconfiguration. Lower severity since it requires a broken L1 table, but the endless refault loop is a realistic outcome.


## sys/amd64/vmm/amd/svm_nested_test.c

- **Uninitialized Read** — In `test_layout`, the diagnostic printf paths print `byte` and `bit` after `svm_msr_bitmap_locate()` may have failed. If the function returns non-zero without writing its output parameters (the expected contract for an unmappable MSR, as the gap checks rely on), the printf reports indeterminate stack values to the console. This only fires when the test regresses, but the diagnostic it emits would then be garbage; initialize both locals or only print them on the mismatch (not the failed-locate) branch.

- **Sysctl Collision** — The module unconditionally creates the `hw.vmm.svm.nested` node itself via `SYSCTL_NODE`. If `vmm.ko` (which this module depends on and whose nested-SVM code it tests) already registers a node of the same name for its own nested knobs, loading this module produces a duplicate-OID conflict or console warnings. Uncertain: I cannot see from the diff whether vmm.ko defines this node; if it does, this module should `SYSCTL_DECL` the existing node instead of declaring its own.


## sys/amd64/vmm/amd/svm_nested_timer.c

- **SMP Monotonicity** — All fast-path timer state lives in the per-vcpu `svm_vcpu->nested` structure, but the devices being emulated are machine-global. For the ACPI PM timer, each vCPU records its own `acpi_tsc_base` on its first read, so on a multi-vCPU L2 guest each vCPU sees a counter starting at ~0 from a different instant; a timecounter read migrating between vCPUs observes time jumping backward/forward, which can wedge or badly skew guest timekeeping. Similarly, a PIT counter programmed on one vCPU is `known` only on that vCPU, so reads from another vCPU are reflected to L1 while latch commands and reads on the programming vCPU are swallowed, leaving L1's vatpit and the L0 shadow state inconsistently interleaved. The state needs to be per-VM (shared, with appropriate synchronization), not per-vcpu.

- **Read-Phase Bug** — The counter read path only honors the lo/hi byte sequence for latched reads. An unlatched read in access mode 3 always returns the low byte via `pit_current(c) & 0xff` with no phase toggle, whereas a real 8254 in lobyte/hibyte mode returns low then high alternately. Likewise a latched read in access mode 2 (hibyte only) returns `latch & 0xff` (the low byte) on the first read instead of the high byte. Because these reads are fully handled by L0 once `known` is set (never reflected to L1), any guest that reads the counter without latching, or uses hibyte-only access, silently gets wrong values — and since the design goal is unmodified guests, this can't be worked around in the guest.

- **Mode Assumption** — The control-word snoop records only the access field and ignores the counter mode bits, and `pit_current()` assumes a continuously reloading down-counter decrementing by 1 (mode 2 behavior). A guest programming mode 0 (one-shot, stops semantics differ) or mode 3 (square wave, which decrements by 2 per input clock, so the read-back count runs at twice the rate) will read counter values with the wrong rate or wrap behavior. Since L0 answers all reads once the count is written, such guests get systematically wrong timings rather than falling back to L1's vatpit. Restricting the fast path to modes it models correctly (e.g., mode 2) would be safer.


## sys/amd64/vmm/amd/svm_nested_intr.c

- **Duplicate Delivery** — `svm_nested_inject_pending_interrupt` both writes the vector into `ctrl->eventinj` (delivering it on the next VMRUN) and sets the same vector in the PIR for INTR-type events. The PIR bit is only ever cleared in `svm_nested_drain_pir`, which then re-injects the vector. Every external interrupt injected this way is therefore delivered at least twice: once via the immediate `eventinj` write and again when the PIR is drained. `svm_nested_inject_extint` makes it worse by calling `svm_nested_pir_set` a second time after the helper already set it (redundant, but confirms the bit stays latched). Either injection should clear the PIR bit on successful delivery, or immediate injection and PIR queuing should be mutually exclusive paths.

- **Event Loss** — Both `svm_nested_inject_pending_interrupt` and `svm_nested_inject_exception` unconditionally overwrite `ctrl->eventinj` without checking whether a previously queued event is still pending (`VMCB_EVENTINJ_VALID` already set). If an exception is queued and an interrupt injection (or a `svm_nested_drain_pir` call) happens before the next VMRUN, the exception is silently dropped. Lost exceptions (e.g. a queued #PF or #GP) will corrupt guest state in hard-to-debug ways. The injection paths should either check the VALID bit and defer (interrupts can go back to the PIR), or assert that no event is pending.

- **Missing Window Check** — The comment on `svm_nested_drain_pir` states it must be called "when the interrupt window is open", but the function itself neither verifies interrupt-window state nor handles the failure case: it clears the PIR bit before injection, so if the caller invokes it while the window is closed (or the guest never takes the event because a later injection overwrites `eventinj`, per the event-loss issue), the pending vector is permanently lost rather than remaining queued. Clearing the bit only after confirmed delivery, or on the subsequent VMEXIT, would make the drain safe against caller mistakes.


## sys/amd64/vmm/intel/vmx_nested_invept.c

- **Missing Check** — The INVVPID path rejects a descriptor with nonzero reserved fields (`_res1`/`_res2`), but the INVEPT path never checks `desc.reserved` even though `struct invept_desc_l1` defines it. Architecturally the upper 64 bits of the INVEPT descriptor are reserved and a nonzero value should make the instruction fail; here an L1 that sets them gets VMsucceed instead of VMfail, an observable emulation divergence for guests (or test suites) that probe reserved-bit behavior.

- **Possible Issue** — `vmx_canonical_address()` hardcodes a 48-bit canonicality test (shift by 16). If the L1 guest runs with 5-level paging (LA57), linear addresses that are canonical in 57 bits but not in 48 bits would be wrongly rejected, causing a VMfail for a legitimate `INVVPID_TYPE_ADDRESS` request. Only relevant on hosts/guests where LA57 is exposed; if LA57 is never advertised to L1 this cannot trigger, but the helper's name suggests general reuse.

- **Type Coverage** — `vmx_nested_invvpid_handle()` rejects the single-context-retaining-globals INVVPID type (type 3) with VMfail. Whether this is a bug depends on what the VPID capability bits exposed to L1 advertise, which is not visible in this diff: if that type is advertised as supported, a conforming L1 issuing it would get an unexpected VMfail. If the capability MSRs mask it out, this is fine — worth confirming the two stay consistent.


## sys/amd64/vmm/amd/svm_nested.c

- **Fail-open inconsistency** — `svm_msr_bitmap_test_intercept` fails closed (returns intercepted) for out-of-range MSRs and for a NULL/undersized map, but fails open (returns 0, "not intercepted") when `rw` is 0 or contains bits outside `MSR_BITMAP_ACCESS_RW`. If a caller on the L2 exit-routing path ever passes a malformed `rw` value (e.g. a stray bit set alongside a valid READ bit), an MSR access that L1 asked to intercept would be reported as not intercepted and the access could be reflected or emulated instead of forwarded to L1. Given the function's documented contract is "MSRs outside the mapped ranges are reported as intercepted, matching hardware", the invalid-argument case should also fail closed (or assert), so a caller bug degrades safely.


## sys/amd64/vmm/intel/vmx_nested_vmlaunch.c

- **State Corruption** — `ns->state` is set to `VMCS12_STATE_LAUNCHED` before `vmx_nested_build_vmcs02()` runs. If the build fails, the code falls through to the synthetic VM-entry-failure exit, but the VMCS12 is now permanently marked launched even though no entry occurred. This is inconsistent with the `vmx_nested_l2_enable`-disabled path, where the state stays CLEAR after the same failure exit. Concretely: L1 issues VMLAUNCH, the vmcs02 build fails, L1 sees the entry-failure exit, tears down and retries VMLAUNCH on the same (VMCLEARed-or-not) VMCS — the retry now gets VMfailValid(`VMX_INSERR_VMLAUNCH_NOT_CLEAR`) instead of another attempt. The state transition should happen only after `vmx_nested_build_vmcs02()` succeeds.

- **Wrong Blocking Check** — The VMfailValid check for interruptibility blocking includes STI blocking via `HWINTR_BLOCKING`, but architecturally only blocking by MOV SS/POP SS makes VMLAUNCH/VMRESUME fail with the "entry blocked by MOV SS" error; an STI shadow does not block VM entry. An L1 that executes STI immediately before VMLAUNCH (a legal sequence) will get a spurious VMfailValid. Separately, the check reads `VMCS_GUEST_INTERRUPTIBILITY` through `vmx_nested_vmcs_read` — if that helper reads the VMCS12 field (its name suggests so; not visible in this diff), the check is inspecting L2's to-be-loaded guest state rather than L1's current interruptibility, which would both wrongly fail legitimate entries that set STI/MOVSS blocking in L2 guest state and miss actual MOV SS blocking in L1. If the helper actually reads L1's active-VMCS state, only the STI part of this finding applies.


## sys/amd64/vmm/intel/vmx_nested_vmptrld.c

- **State Divergence** — On the VMCS-switch path, `vmx_nested_flush_vmcs12` is called and the old VMCS12 is discarded before the new one has been successfully read in. If `vmx_nested_read_guest` of the full `struct vmcs12` then fails, the code sets `vmcs12_active = false`, leaving L1 with no current VMCS. On real hardware a failed VMPTRLD leaves the previously current VMCS pointer intact, so an L1 hypervisor that handles the VMfail and retries (or continues using its old VMCS) will find its current-VMCS pointer silently gone and subsequent VMREAD/VMWRITE/VMLAUNCH will misbehave. The trigger is narrow (the 4-byte revision read succeeded but the full-structure read failed, e.g. a VMCS12 spanning into an unmapped page or a concurrent memory-map change), but the recovery behavior is architecturally wrong. Loading the new contents into a scratch buffer, or deferring the flush/deactivation until the read succeeds, would preserve the old current VMCS on failure.

- **Possible NULL Deref** — `vmx_nested_exit_vmptrst` calls `vmx_nested_state(vcpu)` and dereferences the result (`ns->vmcs12_active`, `ns->vmcs12_gpa`) without a NULL check, while the VMPTRLD path explicitly checks for NULL and returns `VM_FAIL_INVALID`. If `vmx_nested_insn_check(vcpu, true)` already guarantees the nested state exists whenever it returns 0, the check in `vmx_nested_load_vmcs12` is dead code and the two paths are merely inconsistent; if it does not, VMPTRST can dereference NULL in the kernel from a guest-triggerable path. Uncertainty: `vmx_nested_insn_check` is not visible in this diff, so whether NULL is actually reachable here cannot be confirmed — but a guest-reachable kernel NULL dereference is high impact, so the inconsistency is worth resolving explicitly either way.

- **Stale State Fields** — In the read-failure path of `vmx_nested_load_vmcs12`, only `vmcs12_active` and `vmcs12_gpa` are reset; `ns->state` and `ns->in_l2` retain values from the previously loaded VMCS12. If any consumer gates on `state` (e.g. `VMCS12_STATE_LAUNCHED`) without first checking `vmcs12_active`, it will act on state belonging to a VMCS that is no longer current. The success path deliberately resets all four fields together, so the failure path leaving two of them stale looks like an oversight rather than a design choice.


## sys/amd64/vmm/intel/vmx_nested_vmread.c

- **Encoding Truncation** — The field encoding is fetched as a full 64-bit register value but is silently

- **Inconsistent Guard** — `vmx_nested_exit_vmread` and `vmx_nested_exit_vmwrite` gate on


## sys/amd64/vmm/intel/vmx_nested.c

- **Incomplete File** — The file ends with a full block comment describing the VMCS12 shadow-bitmap

- **Sysctl Race** — `vmx_nested_state()` re-checks the global `vmm_nested_enable` sysctl on


## sys/amd64/vmm/intel/vmx_nested_vmclear.c

- **Spec Conformance** — `vmx_nested_vmclear_handle` returns `VM_FAIL_VALID` for a misaligned/out-of-range address, a VMXON-pointer match, or a failed guest write even when no current VMCS is loaded (`ns->vmcs12_active` is false). Architecturally, VMfailValid records the error number in the VM-instruction-error field of the *current* VMCS; with no current VMCS the instruction must produce VMfailInvalid instead. If `vmx_nested_vmfail_valid` does not itself fall back to VMfailInvalid when no vmcs12 is active, an L1 guest executing VMCLEAR with a bad operand before any VMPTRLD will observe the wrong flag combination (ZF instead of CF), which a conformance-sensitive L1 hypervisor can misinterpret. Uncertain because `vmx_nested_vmfail_valid`'s internal behavior is not visible in this diff — worth verifying it handles the no-current-VMCS case.


## sys/amd64/vmm/intel/vmx_nested_vmcall.c

- **State semantics** — The choice between VMfailValid and VMfailInvalid is keyed on `ns->vmcs12_active`. Architecturally that choice depends on whether a current VMCS pointer is loaded (i.e., VMPTRLD has established one), which is not necessarily the same predicate as a vmcs12 being "active" if that flag can diverge from the current-pointer state (e.g., after VMCLEAR of the current VMCS or a VMPTRLD that has not yet launched anything). If the two states can differ in this implementation, an L1 issuing VMCALL in that window would observe the wrong failure indication (VMfailInvalid where VMfailValid with error 1 is expected, or vice versa). This is uncertain from the diff alone since the definition of `vmcs12_active` is not visible; worth confirming it tracks exactly "current VMCS pointer is valid".


## sys/amd64/vmm/vmm_nested.c

- **Unused Parameters** — `nested_vcpu_state_factory` accepts `vm` and `vcpuid` but never uses or stores them in the allocated `struct nested_vcpu_state`. If the state is meant to be tied back to its owning VM/vcpu (e.g. for later teardown or lookup), that association is silently dropped; if the parameters are placeholders for upcoming work, consider recording them in the struct now or removing them so callers are not misled into thinking the linkage exists.


## Triage log

- **svm_nested_stubs.c · Guest-triggerable host DoS (unchecked IOPM/MSRPM holds)** —
  **DISPROVED.** Both consumers (`svm_nested_l1_iopm_intercepts`,
  `svm_nested_l1_msrpm_intercepts` in svm_nested_exit.c) NULL-check the map and
  return "intercepted", i.e. they fail closed. The holds are deliberately
  unchecked and the design is documented in the consumer's comment. No NULL
  dereference is reachable.

- **svm_nested_stubs.c · Incomplete TOCTOU fix** — **CONFIRMED, fixed.** VMCB02
  composition re-read the live `vmcb12->ctrl.intercept[]` 68 lines after the
  snapshot whose comment says "use only these locals hereafter". The predicted
  consequence (host crash) does not follow, because the consumers fail closed,
  but L2 could run with an intercept whose policy map was never held. Now
  composed from a 5-word snapshot, and the consistency check validates that
  snapshot rather than the live page.

- **RESIDUAL, not fixed:** `svm_nested_vmcb12_consistent()` still reads the
  *state* fields (efer, cr0, cr4) from the live mapping, and `vmcb->state =
  vmcb12->state` copies them live as well. A racing L1 vCPU can therefore have
  state validated that differs from state composed. This is a correctness
  concern rather than a host-safety one: the hardware re-validates VMCB02 at
  VMRUN and fails the entry, and the only fields that drive *host* memory
  access — the IOPM/MSRPM bases — are snapshotted. Worth closing by snapshotting
  the whole control/state area, but it is a larger change than this one.
