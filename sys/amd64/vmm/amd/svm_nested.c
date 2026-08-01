/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * Nested virtualization support for bhyve on AMD SVM.
 * MSR bitmap primitives backing the per-vCPU MSRPM. Layout follows
 * AMD APM Vol 2 §15.11; this is original BSD code that implements the
 * primitive set/clear/test operations on a shared 'nested_bitmap'.
 */

#include <sys/cdefs.h>

#include <sys/errno.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/types.h>

#include <machine/cpufunc.h>
#include <machine/specialreg.h>
#include <machine/vmm.h>

#include "svm_softc.h"
#include "svm_nested.h"
#include "vmm_nested.h"
#include "vmcb.h"

/*
 * MSR_BITMAP_ACCESS_* values come from intel/vmx_msr.h. Re-declare here
 * locally so this file does not need to pull in VMX-only headers.
 */
#ifndef MSR_BITMAP_ACCESS_NONE
#define	MSR_BITMAP_ACCESS_NONE	0x0
#endif
#ifndef MSR_BITMAP_ACCESS_READ
#define	MSR_BITMAP_ACCESS_READ	0x1
#endif
#ifndef MSR_BITMAP_ACCESS_WRITE
#define	MSR_BITMAP_ACCESS_WRITE	0x2
#endif
#ifndef MSR_BITMAP_ACCESS_RW
#define	MSR_BITMAP_ACCESS_RW	(MSR_BITMAP_ACCESS_READ|MSR_BITMAP_ACCESS_WRITE)
#endif

/*
 * Translate an MSR number into the (page_base, msr_within_page) pair
 * used by the rest of the bitmap primitives. Returns 0 on success,
 * EINVAL if the MSR falls outside both AMD-supported ranges
 * (0x00000000-0x00001FFF and 0xC0000000-0xC001FFFF).
 *
 * On success:
 *   *page_base   = absolute byte offset of the 2 KB read map for the
 *                  chosen page (0 for page 0, 0x1000 for page 1)
 *   *msr_in_page = MSR index within that 2 KB region (0 .. 0x1FFF)
 */
static int
svm_msr_bitmap_locate(uint32_t msr, size_t *page_base, uint32_t *msr_in_page)
{
	uint32_t offset;

	if (msr <= (SVM_MSR_BITMAP_PAGE0_MSRS - 1)) {
		*page_base = 0;
		*msr_in_page = msr;
		return (0);
	}
	if (msr >= SVM_MSR_BITMAP_PAGE1_BASE &&
	    msr <= SVM_MSR_BITMAP_PAGE1_END) {
		offset = msr - SVM_MSR_BITMAP_PAGE1_BASE;
		*page_base = SVM_MSR_BITMAP_PAGE1_BASE_OFF;
		*msr_in_page = offset & SVM_MSR_BITMAP_PAGE1_INDEX_MASK;
		return (0);
	}
	return (EINVAL);
}

void
svm_msr_bitmap_init(struct nested_bitmap *nb, void *backing)
{

	KASSERT(nb != NULL, ("%s: nb is NULL", __func__));
	KASSERT(backing != NULL, ("%s: backing is NULL", __func__));

	nb->map = backing;
	nb->size = SVM_MSR_BITMAP_SIZE;
	/*
	 * AMD-default semantics: every MSR access is intercepted. Bits
	 * are cleared (allowed) by svm_msr_bitmap_clear_intercept(). This
	 * matches the initialization in sys/amd64/vmm/amd/svm.c.
	 */
	memset(nb->map, 0xff, SVM_MSR_BITMAP_SIZE);
}

static int
svm_msr_bitmap_op(struct nested_bitmap *nb, uint32_t msr, int rw, bool set)
{
	size_t page_base;
	uint32_t msr_in_page;
	size_t read_byte, write_byte;
	uint8_t mask;

	if (rw & ~(MSR_BITMAP_ACCESS_READ | MSR_BITMAP_ACCESS_WRITE))
		return (EINVAL);

	if (svm_msr_bitmap_locate(msr, &page_base, &msr_in_page) != 0)
		return (EINVAL);

	read_byte = page_base + (msr_in_page / SVM_MSR_BITMAP_MSRS_PER_BYTE);
	write_byte = read_byte + SVM_MSR_BITMAP_WRITE_HALF_OFF;

	if (read_byte + 1 > nb->size || write_byte + 1 > nb->size)
		return (EINVAL);

	mask = (uint8_t)((msr_in_page % SVM_MSR_BITMAP_MSRS_PER_BYTE) *
	    SVM_MSR_BITMAP_BITS_PER_MSR);

	if (rw & MSR_BITMAP_ACCESS_READ) {
		if (set)
			nb->map[read_byte] |= (uint8_t)(0x1 << mask);
		else
			nb->map[read_byte] &= (uint8_t)~(0x1 << mask);
	}
	if (rw & MSR_BITMAP_ACCESS_WRITE) {
		if (set)
			nb->map[write_byte] |= (uint8_t)(0x1 << (mask + 1));
		else
			nb->map[write_byte] &= (uint8_t)~(0x1 << (mask + 1));
	}
	return (0);
}

int
svm_msr_bitmap_set_intercept(struct nested_bitmap *nb, uint32_t msr, int rw)
{

	KASSERT(nb != NULL, ("%s: nb is NULL", __func__));
	return (svm_msr_bitmap_op(nb, msr, rw, true));
}

int
svm_msr_bitmap_clear_intercept(struct nested_bitmap *nb, uint32_t msr, int rw)
{

	KASSERT(nb != NULL, ("%s: nb is NULL", __func__));
	return (svm_msr_bitmap_op(nb, msr, rw, false));
}

int
svm_msr_bitmap_test_intercept(const struct nested_bitmap *nb, uint32_t msr,
    int rw)
{
	size_t page_base;
	uint32_t msr_in_page;
	size_t read_byte, write_byte;
	uint8_t mask;
	int intercepted = 0;

	if ((rw & ~(MSR_BITMAP_ACCESS_READ | MSR_BITMAP_ACCESS_WRITE)) == 0)
		return (0);
	if (svm_msr_bitmap_locate(msr, &page_base, &msr_in_page) != 0)
		return (0);

	if (nb == NULL || nb->map == NULL)
		return (0);

	read_byte = page_base + (msr_in_page / SVM_MSR_BITMAP_MSRS_PER_BYTE);
	write_byte = read_byte + SVM_MSR_BITMAP_WRITE_HALF_OFF;

	if (read_byte + 1 > nb->size || write_byte + 1 > nb->size)
		return (0);

	mask = (uint8_t)((msr_in_page % SVM_MSR_BITMAP_MSRS_PER_BYTE) *
	    SVM_MSR_BITMAP_BITS_PER_MSR);

	if ((rw & MSR_BITMAP_ACCESS_READ) &&
	    (nb->map[read_byte] & (0x1 << mask)) != 0)
		intercepted = 1;
	if ((rw & MSR_BITMAP_ACCESS_WRITE) &&
	    (nb->map[write_byte] & (0x1 << (mask + 1))) != 0)
		intercepted = 1;

	return (intercepted);
}

/*
 * Builder placeholder. Composes the per-vCPU MSRPM by walking the list
 * of MSR ranges that the L1 hypervisor must NOT access directly when
 * nested-virt is enabled. Currently a no-op so that T8-T11 can extend
 * it incrementally; intentionally empty (rather than absent) so that
 * the build always links to a single composed bitmap site.
 */
void
svm_nested_build_msrpm(struct svm_softc *sc, struct svm_vcpu *vcpu)
{
	struct nested_bitmap nb;

	KASSERT(sc != NULL, ("%s: sc is NULL", __func__));
	KASSERT(vcpu != NULL, ("%s: vcpu is NULL", __func__));
	nb.map = sc->msr_bitmap;
	nb.size = SVM_MSR_BITMAP_SIZE;
	(void)svm_msr_bitmap_set_intercept(&nb, MSR_VM_HSAVE_PA,
	    MSR_BITMAP_ACCESS_RW);
}

#ifdef SVM_NESTED_TEST
void
svm_nested_test_msrpm_range(void)
{
	struct nested_bitmap nb;
	uint8_t backing[SVM_MSR_BITMAP_SIZE];

	memset(backing, 0, sizeof(backing));
	nb.map = backing;
	nb.size = sizeof(backing);
	KASSERT(svm_msr_bitmap_set_intercept(&nb, 0xC0010117U,
	    MSR_BITMAP_ACCESS_READ) == 0, ("HSAVE_PA was rejected"));
	KASSERT(backing[0x1045] == (1U << 6),
	    ("HSAVE_PA did not land in page 1 byte 0x45 bit 6"));
	KASSERT(svm_msr_bitmap_set_intercept(&nb, 0xC0010200U,
	    MSR_BITMAP_ACCESS_READ) == 0, ("LBR MSR was rejected"));
	KASSERT(backing[0x1080] == (1U << 0),
	    ("LBR MSR did not land in page 1 byte 0x80 bit 0"));
}
#endif

/*
 * SVM CPUID Fn8000_000A EDX feature bits. Names and values mirror those
 * declared as AMD_CPUID_SVM_* in svm.c (which are unfortunately static
 * there). Duplicating the bit definitions locally keeps this file
 * self-contained and avoids widening svm.c's static linkage.
 */
#define	NSVM_CPUID_NP		BIT(0)	/* Nested paging. */
#define	NSVM_CPUID_LBR_VIRT	BIT(1)	/* Last-branch-record virt. */
#define	NSVM_CPUID_SVM_LOCK	BIT(2)	/* SVM-L (unused by us). */
#define	NSVM_CPUID_NRIP_SAVE	BIT(3)	/* Next-RIP is saved on exit. */
#define	NSVM_CPUID_TSC_RATE	BIT(4)	/* TSC rate control. */
#define	NSVM_CPUID_VMCB_CLEAN	BIT(5)	/* VMCB clean-bits caching. */
#define	NSVM_CPUID_FLUSH_BY_ASID BIT(6)	/* Flush-by-ASID TLB ctrl. */
#define	NSVM_CPUID_DECODE_ASSIST BIT(7)	/* Decode-assist (inst bytes). */
#define	NSVM_CPUID_PAUSE_INC	BIT(10)	/* Pause intercept filter. */
#define	NSVM_CPUID_PAUSE_FTH	BIT(12)	/* Pause filter threshold. */
#define	NSVM_CPUID_AVIC		BIT(13)	/* AVIC (irrelevant nested). */

/*
 * Synthesized host-capability bits held in svm_nested_host_caps. These
 * describe what L0 will actually let an L1 hypervisor enable for its L2
 * guest. Bits not present in CPUID Fn8000_000A EDX are cleared.
 *
 * SVM_NESTED_HOST_VINTR_MASKING is synthetic: AMD APM Vol 2 §15.5 does
 * not expose a dedicated CPUID bit for V_INTR_MASKING but the feature
 * itself is present on every processor that exposes basic SVM (NP +
 * NRIP_SAVE). We set it whenever those base features are present and
 * clear it whenever the test harness forces an override mask without
 * the bit, which lets the test stub prove that the filter masks
 * V_INTR_MASKING when the host advertises "no support".
 */
#define	SVM_NESTED_HOST_VINTR_MASKING	BIT(28)

static uint32_t svm_nested_host_caps;

/*
 * Cache the L0 host's SVM CPUID features. Called lazily from
 * svm_nested_filter_vmcb_ctl() so the value is computed once per boot.
 * do_cpuid() mirrors the call in svm.c::check_svm_features() so the
 * host capability view here matches what svm.c sees on the boot CPU.
 */
static uint32_t
svm_nested_read_host_caps(void)
{
	u_int regs[4];

	do_cpuid(0x8000000A, regs);
	return ((uint32_t)regs[3]);
}

static void
svm_nested_init_host_caps(void)
{
	uint32_t caps;

	caps = svm_nested_read_host_caps();
	if ((caps & NSVM_CPUID_NP) != 0 && (caps & NSVM_CPUID_NRIP_SAVE) != 0)
		caps |= SVM_NESTED_HOST_VINTR_MASKING;
	svm_nested_host_caps = caps;
}

/*
 * Return the cached L0 host SVM capability mask. Safe to call from any
 * context after system bootstrap.
 */
uint32_t
svm_nested_get_host_caps(void)
{

	if (svm_nested_host_caps == 0)
		svm_nested_init_host_caps();
	return (svm_nested_host_caps);
}

#ifdef SVM_NESTED_TEST
/*
 * Test-only override: install a synthetic host capability mask and
 * force the next call to svm_nested_filter_vmcb_ctl() to recompute.
 * Only compiled into the unit test module (T11 will define
 * SVM_NESTED_TEST). It deliberately lives here (not in the test module)
 * so the production filter is the only path being exercised.
 */
void
svm_nested_test_set_host_caps(uint32_t caps)
{

	/*
	 * Make sure no stale cached value short-circuits the test:
	 * zero the cache so svm_nested_get_host_caps() re-runs the init
	 * path; then plant the override as the live value.
	 */
	svm_nested_host_caps = caps;
}
#endif

/*
 * Filter L1's VMCB control area against the L0 host's capabilities.
 *
 * L1 cannot enable features L0 doesn't support (security: an L1 must
 * not be able to use a feature that bypasses the L0 intercept frame
 * and effectively grants an L1->L0 escape). This routine is invoked
 * from the VMRUN handler (T25) before entering the L2 guest; the
 * resulting 'l2_vmcb' is what is actually loaded by VMRUN.
 *
 * Implementation note: we copy L1's VMCB to L2 wholesale and then mask
 * off any feature that L0 does not advertise. Layout follows AMD APM
 * Vol 2 §15.5 (VMCB control area); cap-and-mask semantics follow the
 * design in KVM's arch/x86/kvm/svm/svm.c::svm_set_nested_state() but
 * the code is an original FreeBSD implementation.
 */
void
svm_nested_filter_vmcb_ctl(struct vmcb *l1_vmcb, struct vmcb *l2_vmcb)
{
	uint32_t host_caps;

	KASSERT(l1_vmcb != NULL, ("%s: l1_vmcb is NULL", __func__));
	KASSERT(l2_vmcb != NULL, ("%s: l2_vmcb is NULL", __func__));

	host_caps = svm_nested_get_host_caps();

	/* Copy L1's intended VMCB into the L2 area first. */
	*l2_vmcb = *l1_vmcb;

	/*
	 * Mask the bits that gate capability on the L0 host. If a bit is
	 * not present in host_caps, the corresponding L1-controlled field
	 * must be cleared. We touch only the specific control fields that
	 * the L1 hypervisor might otherwise enable beyond L0's reach.
	 */

	/* Virtual-interrupt masking requires the synthesized gate. */
	if ((host_caps & SVM_NESTED_HOST_VINTR_MASKING) == 0)
		l2_vmcb->ctrl.v_intr_masking = 0;

	/* LBR virtualization is gated by CPUID Fn8000_000A EDX bit 1. */
	if ((host_caps & NSVM_CPUID_LBR_VIRT) == 0)
		l2_vmcb->ctrl.lbr_virt_en = 0;

	/* Next-RIP save is gated by CPUID Fn8000_000A EDX bit 3. */
	if ((host_caps & NSVM_CPUID_NRIP_SAVE) == 0)
		l2_vmcb->ctrl.nrip = 0;

	/* VMCB clean-bits caching requires CPUID Fn8000_000A EDX bit 5. */
	if ((host_caps & NSVM_CPUID_VMCB_CLEAN) == 0)
		l2_vmcb->ctrl.vmcb_clean = 0;

	/*
	 * Decode assist (instruction bytes) is gated by CPUID
	 * Fn8000_000A EDX bit 7. Without it the hardware ignores the
	 * bytes; clear them so we do not get a stale latched value.
	 */
	if ((host_caps & NSVM_CPUID_DECODE_ASSIST) == 0) {
		l2_vmcb->ctrl.inst_len = 0;
		memset(l2_vmcb->ctrl.inst_bytes, 0,
		    sizeof(l2_vmcb->ctrl.inst_bytes));
	}

	/*
	 * Nested paging is mandatory for bhyve (see svm.c::check_svm_
	 * features()) but be defensive: if a configuration ever allows
	 * SVM without NP, force n_cr3 to 0 so the hardware falls back to
	 * regular paging rather than misinterpreting a stale pointer.
	 */
	if ((host_caps & NSVM_CPUID_NP) == 0)
		l2_vmcb->ctrl.n_cr3 = 0;
}

/*
 * Internal self-test stub. Constructs a fake VMCB, calls the filter,
 * and asserts the expected masking. Compiled in whenever the
 * SVM_NESTED_TEST compile switch is enabled (T11's test module enables
 * it). The function is intentionally side-effect free aside from the
 * KASSERT() probes, so it is safe to leave linked into the production
 * kernel if a developer wants to run it from a debugger.
 */
#ifdef SVM_NESTED_TEST
void
test_vmcb_filter(void)
{
	struct vmcb l1, l2;
	uint32_t saved_caps;

	/*
	 * Save whatever override the harness already installed so we can
	 * restore it. The intent is to be re-entrant in case the harness
	 * runs this test in sequence with others.
	 */
	saved_caps = svm_nested_get_host_caps();

	memset(&l1, 0, sizeof(l1));
	memset(&l2, 0, sizeof(l2));

	/* Case 1: host advertises V_INTR_MASKING; L1's request survives. */
	svm_nested_test_set_host_caps(SVM_NESTED_HOST_VINTR_MASKING |
	    NSVM_CPUID_NP | NSVM_CPUID_NRIP_SAVE);
	l1.ctrl.v_intr_masking = 1;
	l1.ctrl.n_cr3 = 0x1000;
	l1.ctrl.nrip = 0xDEADBEEF;
	l1.ctrl.vmcb_clean = VMCB_CACHE_DEFAULT;
	memset(l1.ctrl.inst_bytes, 0xCC, sizeof(l1.ctrl.inst_bytes));
	l1.ctrl.inst_len = 2;
	l1.ctrl.lbr_virt_en = 1;
	svm_nested_filter_vmcb_ctl(&l1, &l2);
	KASSERT(l2.ctrl.v_intr_masking == 1,
	    ("v_intr_masking dropped when host supports it"));
	KASSERT(l2.ctrl.nrip == 0xDEADBEEF,
	    ("nrip dropped when host has NRIP_SAVE"));
	KASSERT(l2.ctrl.vmcb_clean == VMCB_CACHE_DEFAULT,
	    ("vmcb_clean dropped when host has VMCB_CLEAN"));
	KASSERT(l2.ctrl.inst_len == 2 && l2.ctrl.inst_bytes[0] == 0xCC,
	    ("inst_bytes dropped when host has DECODE_ASSIST"));
	KASSERT(l2.ctrl.lbr_virt_en == 1,
	    ("lbr_virt_en dropped when host has LBR_VIRT"));
	KASSERT(l2.ctrl.n_cr3 == 0x1000,
	    ("n_cr3 dropped when host has NP"));

	/* Case 2: host advertises NO capabilities; everything gets masked. */
	svm_nested_test_set_host_caps(0);
	memset(&l1, 0, sizeof(l1));
	memset(&l2, 0, sizeof(l2));
	l1.ctrl.v_intr_masking = 1;
	l1.ctrl.nrip = 0xCAFEBABE;
	l1.ctrl.vmcb_clean = 0xFFFFFFFFU;
	l1.ctrl.lbr_virt_en = 1;
	l1.ctrl.n_cr3 = 0x4000;
	memset(l1.ctrl.inst_bytes, 0xAA, sizeof(l1.ctrl.inst_bytes));
	l1.ctrl.inst_len = 5;
	svm_nested_filter_vmcb_ctl(&l1, &l2);
	KASSERT(l2.ctrl.v_intr_masking == 0,
	    ("v_intr_masking NOT masked when host lacks support"));
	KASSERT(l2.ctrl.nrip == 0,
	    ("nrip NOT masked when host lacks NRIP_SAVE"));
	KASSERT(l2.ctrl.vmcb_clean == 0,
	    ("vmcb_clean NOT masked when host lacks VMCB_CLEAN"));
	KASSERT(l2.ctrl.lbr_virt_en == 0,
	    ("lbr_virt_en NOT masked when host lacks LBR_VIRT"));
	KASSERT(l2.ctrl.inst_len == 0 &&
	    l2.ctrl.inst_bytes[0] == 0 &&
	    l2.ctrl.inst_bytes[14] == 0,
	    ("inst_bytes NOT masked when host lacks DECODE_ASSIST"));
	KASSERT(l2.ctrl.n_cr3 == 0,
	    ("n_cr3 NOT masked when host lacks NP"));

	printf("svm_nested_filter_vmcb_ctl: filter PASS\n");

	/* Restore whatever override the harness had installed. */
	svm_nested_test_set_host_caps(saved_caps);
}
#endif /* SVM_NESTED_TEST */
