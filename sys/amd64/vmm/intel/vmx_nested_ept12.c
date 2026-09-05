/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 *
 * T23: EPT12 nested translation.  L1's EPT12 root pointer is
 * installed by VMWRITE to the EPT_POINTER_FULL field; L0 uses
 * EPT12 as the inner page table for L2 (L2 GPA -> EPT12 -> L1 GPA
 * -> EPT (L0) -> HPA).
 *
 * The EPT12 page-table format is the architectural EPT format.
 * The L0-side walk goes through up to four 4KB tables of 8-byte
 * entries: PML4 -> PDPT -> PD -> PT, indexed by GPA bits 47:39 /
 * 38:30 / 29:21 / 20:12.  Each non-leaf PTE carries the physical
 * address of the next-level table; a leaf PTE carries the
 * translated HPA.
 *
 * Original BSD code.
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <vm/vm.h>
#include <vm/pmap.h>

#include <machine/cpufunc.h>
#include <machine/vmm.h>

#include <dev/vmm/vmm_ktr.h>
#include <dev/vmm/vmm_vm.h>

#include "vmm_host.h"
#include "vmx_cpufunc.h"
#include "vmcs.h"
#include "vmx.h"
#include "vmx_nested.h"

extern int vmm_nested_enable;

/*
 * Architectural EPT entry format.  Bit layout of each
 * 8-byte EPT PTE / PDPTE / PDE:
 *   bit 0    - Read access
 *   bit 1    - Write access
 *   bit 2    - Execute access
 *   bit 5    - Accessed flag (PDPTE / PDE)
 *   bit 6    - Ignore PAT (for leaf entries with 2MB / 1GB pages)
 *   bit 7    - Page size (0 = 4KB, 1 = 2MB / 1GB at PDPTE / PDE)
 *   bits 11:8 - Available to software
 *   bits M:12 - Physical address of next-level table or final HPA
 * where M depends on the level (51:12 for PML4E / PDPTE, etc).
 *
 * The PML4E / PDPTE / PDE physical-address widths are 51:12 with
 * bits 11:0 holding flags; the leaf PT physical-address bits are
 * 51:12 with bits 11:0 holding flags and 20:12 holding the
 * page-offset.  We therefore AND the entry with 0x000ffffffffff000
 * to extract the pointer/HPA.
 */
#define	EPT_PTE_MASK		0x000ffffffffff000UL
#define	EPT_PTE_R		(1U << 0)
#define	EPT_PTE_W		(1U << 1)
#define	EPT_PTE_X		(1U << 2)
#define	EPT_PTE_LARGE		(1U << 7)

/*
 * Large-page / 4KB leaf PTE physical-address masks.  The
 * low-order address bits are reserved and
 * must be zero in a leaf PTE; the L2 page offset is OR-ed in by
 * the walker after masking the PTE address.
 *
 *   1GB PDPTE: bits 51:30 hold the physical address; bits 29:12
 *              are reserved.
 *   2MB PDE:   bits 51:21 hold the physical address; bits 20:12
 *              are reserved.
 *   4KB PTE:   bits 51:12 hold the physical address; bits 11:0
 *              are flag bits (R/W/X etc.).
 */
#define	EPT_PTE_LARGE_ADDR_1GB	0x000fffffc0000000UL
#define	EPT_PTE_LARGE_ADDR_2MB	0x000fffffffe00000UL
#define	EPT_PTE_4KB_ADDR	0x000ffffffffff000UL

/*
 * EPT PML4 / PDPT / PD / PT indices, derived from the L2 GPA.
 * The architecture has 4 levels each indexing 512 entries
 * (9 bits per level), totalling 36 bits of address space.
 */
#define	EPT_IDX_PML4(gpa)	(((gpa) >> 39) & 0x1ff)
#define	EPT_IDX_PDPT(gpa)	(((gpa) >> 30) & 0x1ff)
#define	EPT_IDX_PD(gpa)		(((gpa) >> 21) & 0x1ff)
#define	EPT_IDX_PT(gpa)		(((gpa) >> 12) & 0x1ff)

/*
 * Maximum depth of an EPT walk: 4 levels.
 */
#define	EPT_WALK_MAX_LEVELS	4

int
vmx_nested_ept12_install(struct vmx_vcpu *vcpu, uint64_t ept12_pte)
{
	struct vmx_nested_state *ns;
	unsigned levels;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);

	/*
	 * L1 chooses this value, and the walker below implements exactly one
	 * shape of walk. The page-walk-length field holds the level count less
	 * one -- the same encoding eptp() uses to build our own EPTP -- so a
	 * root asking for any other depth would be walked as if it were
	 * EPT_WALK_MAX_LEVELS deep, silently translating through the wrong
	 * table level rather than telling L1 anything.
	 *
	 * Fail the nested VM entry rather than storing 0 and letting the
	 * translation fail later: an EPT violation reflected to an L1 whose own
	 * tables map the address is one L1 resumes from, forever. A VM-entry
	 * failure is something L1 can see and report.
	 */
	levels = ((ept12_pte >> 3) & 0x7) + 1;
	if (ept12_pte != 0 && levels != EPT_WALK_MAX_LEVELS) {
		VMX_CTR2(vcpu, "nested EPT12: refusing EPTP %#lx with a "
		    "%u-level walk", (unsigned long)ept12_pte, levels);
		return (-1);
	}
	ns->ept12_pte = ept12_pte;
	return (0);
}

/*
 * Walk L1's 4-level EPT12 to translate the L2 GPA into a L1 GPA.
 * Each level holds the full 4KB table page via vm_gpa_hold so
 * the held mapping covers all 512 entries; the indexed entry
 * is then copied out of the held page.  Holding only a single
 * 8-byte PTE and indexing past it would walk off the end of the
 * held region into stack memory (CWE-125).
 *
 * The 'access' argument carries the requested L2 access type
 * (VM_PROT_READ / VM_PROT_WRITE / VM_PROT_EXECUTE).  Every
 * walked PTE must permit that access.
 *
 * Returns VM_SUCCESS and writes *out_l1_gpa on success.  On
 * failure returns -1 and leaves *out_l1_gpa untouched.  The
 * failure cases are:
 *   - L1 EPTP not installed (ept12_pte == 0)
 *   - any level's PTE has the architecture-disallowed format
 *   - the requested access is not permitted at any walked PTE
 *   - vm_gpa_hold fails (L1 page is unmapped / has been freed)
 *
 * The architecture-defined "large page" entries (2MB PDE,
 * 1GB PDPTE) are not currently exercised by any wave-4
 * handler, so this walker treats them as a translation hit
 * with the GPA low bits preserved.
 */
int
vmx_nested_ept12_translate(struct vmx_vcpu *vcpu, uint64_t l2_gpa,
    int access, uint64_t *out_l1_gpa)
{
	struct vmx_nested_state *ns;
	uint64_t ept_root;
	uint64_t gpa;
	uint64_t hpa;
	uint64_t pte;
	uint64_t table_pa;
	uint64_t access_bit;
	void *mapping;
	void *cookie;
	int level;

	ns = vmx_nested_state(vcpu);
	if (ns == NULL)
		return (-1);
	if (out_l1_gpa == NULL)
		return (-1);

	/*
	 * Validate the requested access type.  Exactly one of
	 * VM_PROT_READ/WRITE/EXECUTE must be set — we don't
	 * support combined access in the walker because EPT
	 * bit-checking is per-access-type.
	 */
	switch (access) {
	case VM_PROT_READ:
		access_bit = EPT_PTE_R;
		break;
	case VM_PROT_WRITE:
		access_bit = EPT_PTE_W;
		break;
	case VM_PROT_EXECUTE:
		access_bit = EPT_PTE_X;
		break;
	default:
		return (-1);
	}

	ept_root = ns->ept12_pte;
	if ((ept_root & EPT_PTE_MASK) == 0)
		return (-1);

	/*
	 * The L1 EPTP holds the physical address of the PML4 table
	 * in bits 51:12.  We interpret it as a L1 GPA so the L0
	 * vmm_gpa_hold() helper can resolve it to a host mapping
	 * (the L1 EPT tables live in L1's physical memory).
	 */
	table_pa = ept_root & EPT_PTE_MASK;
	gpa = table_pa;

	for (level = 0; level < EPT_WALK_MAX_LEVELS; level++) {
		uint64_t idx;
		uint64_t table_base;

		/*
		 * Hold the full 4KB table page at the page-aligned
		 * GPA.  vm_gpa_hold() pins a single 4KB page and
		 * requires len <= PAGE_SIZE - pageoff, so we must
		 * hold at the page boundary and read out the
		 * indexed entry (idx * 8 bytes into the page).
		 * Holding only sizeof(uint64_t) and then indexing
		 * past it would be an OOB stack read.
		 */
		table_base = gpa & ~PAGE_MASK;
		mapping = vm_gpa_hold(vcpu->vcpu, table_base, PAGE_SIZE,
		    VM_PROT_READ, &cookie);
		if (mapping == NULL) {
			VMX_CTR2(vcpu,
			    "nested EPT12 walk: vm_gpa_hold failed at level=%d gpa=%#lx",
			    level, (unsigned long)gpa);
			return (-1);
		}

		switch (level) {
		case 0:
			idx = EPT_IDX_PML4(l2_gpa);
			break;
		case 1:
			idx = EPT_IDX_PDPT(l2_gpa);
			break;
		case 2:
			idx = EPT_IDX_PD(l2_gpa);
			break;
		default:
			idx = EPT_IDX_PT(l2_gpa);
			break;
		}

		memcpy(&pte, (uint8_t *)mapping + (idx * sizeof(uint64_t)),
		    sizeof(pte));
		vm_gpa_release(cookie);

		if ((pte & (EPT_PTE_R | EPT_PTE_W | EPT_PTE_X)) == 0) {
			VMX_CTR3(vcpu, "nested EPT12 walk: empty PTE at "
			    "level=%d idx=%lu pte=%#lx",
			    level, (unsigned long)idx, (unsigned long)pte);
			return (-1);
		}

		/*
		 * Enforce the requested access type at every walked
		 * level.  Each non-leaf
		 * table descriptor must also carry the access bit
		 * for a translation that will eventually be allowed
		 * — the architecture requires permission bits to combine
		 * with AND across all levels.
		 */
		if ((pte & access_bit) == 0) {
			VMX_CTR3(vcpu, "nested EPT12 walk: access denied at "
			    "level=%d idx=%lu pte=%#lx",
			    level, (unsigned long)idx, (unsigned long)pte);
			return (-1);
		}

		/*
		 * Reserved-bit validation.
		 * Bits the architecture marks as reserved must be
		 * zero; a non-zero reserved bit triggers an EPT
		 * misconfiguration (#VMEXIT INVEPT/INVVPID aside,
		 * the walker must not propagate such a PTE).
		 *
		 *   PML4E: bits 11:0 are flags; no reserved bits.
		 *   PDPTE non-leaf: bit 6, bits 11:8.
		 *   PDPTE 1GB leaf: bits 29:12 reserved (already
		 *                   masked by the large-page addr
		 *                   mask, but we double-check here).
		 *   PDE non-leaf: bit 6, bits 11:8.
		 *   PDE 2MB leaf: bits 20:12 reserved.
		 *   PTE 4KB leaf: bits 11:0 are flags; bits 52:MAXPHYADDR.
		 *
		 * We only validate the leaf-level reserved bits
		 * explicitly here; non-leaf validation is folded
		 * into the next-level table hold (a non-existent
		 * table GPA fails vm_gpa_hold).
		 */
		if ((level == 1 || level == 2) &&
		    (pte & EPT_PTE_LARGE) != 0) {
			uint64_t reserved_mask;

			if (level == 1)
				reserved_mask = 0x3ffff000UL;
			else
				reserved_mask = 0x1ff000UL;
			if ((pte & reserved_mask) != 0) {
				VMX_CTR3(vcpu, "nested EPT12 walk: "
				    "misconfigured large PTE level=%d "
				    "idx=%lu pte=%#lx",
				    level, (unsigned long)idx,
				    (unsigned long)pte);
				return (-1);
			}
		}

		/*
		 * Leaf detection: a non-zero "large" bit at the
		 * current level means a 2MB PDE (level 2) or 1GB
		 * PDPTE (level 1).  The PML4E never carries the
		 * large bit.
		 *
		 * For large-page entries the low address bits are
		 * reserved and must be zero:
		 * 1GB PDPTE: bits 29:12 reserved; 2MB PDE: bits
		 * 20:12 reserved.  AND them out before OR-ing the
		 * page offset so L1 cannot steer the translation
		 * into L1 physical memory it does not own by
		 * setting reserved bits.
		 */
		if ((level == 1 || level == 2) &&
		    (pte & EPT_PTE_LARGE) != 0) {
			uint64_t page_off;
			uint64_t pte_addr;

			if (level == 1) {
				page_off = l2_gpa & 0x3fffffffUL;
				pte_addr = pte & EPT_PTE_LARGE_ADDR_1GB;
			} else {
				page_off = l2_gpa & 0x1fffffUL;
				pte_addr = pte & EPT_PTE_LARGE_ADDR_2MB;
			}
			hpa = pte_addr | page_off;
			*out_l1_gpa = hpa;
			VMX_CTR3(vcpu, "nested EPT12 large: level=%d "
			    "hpa=%#lx pte=%#lx",
			    level, (unsigned long)hpa, (unsigned long)pte);
			return (VM_SUCCESS);
		}

		/*
		 * Non-leaf: the entry points to the next-level
		 * table at bits 51:12.
		 */
		if (level == EPT_WALK_MAX_LEVELS - 1) {
			/*
			 * Reached the leaf level without hitting
			 * a large-page indicator — the PTE
			 * describes a 4KB leaf.  The PTE physical
			 * address bits are 51:12; AND out bits 11:0
			 * (R/W/X, etc.) so we OR in only the L2
			 * page offset.
			 */
			uint64_t page_off;

			page_off = l2_gpa & 0xfffUL;
			hpa = (pte & EPT_PTE_4KB_ADDR) | page_off;
			*out_l1_gpa = hpa;
			VMX_CTR3(vcpu, "nested EPT12 leaf: level=%d "
			    "hpa=%#lx pte=%#lx",
			    level, (unsigned long)hpa, (unsigned long)pte);
			return (VM_SUCCESS);
		}

		gpa = pte & EPT_PTE_MASK;
	}

	/* Unreachable. */
	return (-1);
}
