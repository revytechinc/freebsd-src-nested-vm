/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2011 NetApp, Inc.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY NETAPP, INC ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL NETAPP, INC OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/proc.h>

#include <machine/clock.h>
#include <machine/cpufunc.h>
#include <machine/md_var.h>
#include <machine/pcb.h>
#include <machine/specialreg.h>
#include <machine/vmm.h>

#include "vmx.h"
#include "vmx_msr.h"
#include "x86.h"

#include <dev/vmm/vmm_vm.h>

/*
 * VMX capability MSR numbers not yet named in <machine/specialreg.h>.
 * These are referenced from the nested-VMX capability masking path
 * below (T12); once <machine/specialreg.h> is updated to add them,
 * these local defines become redundant and can be removed.
 */
#ifndef	MSR_VMX_MISC
#define	MSR_VMX_MISC		0x485
#endif
#ifndef	MSR_VMX_VMFUNC
#define	MSR_VMX_VMFUNC		0x491
#endif

static bool
vmx_ctl_allows_one_setting(uint64_t msr_val, int bitpos)
{

	return ((msr_val & (1UL << (bitpos + 32))) != 0);
}

static bool
vmx_ctl_allows_zero_setting(uint64_t msr_val, int bitpos)
{

	return ((msr_val & (1UL << bitpos)) == 0);
}

uint32_t
vmx_revision(void)
{

	return (rdmsr(MSR_VMX_BASIC) & 0xffffffff);
}

/*
 * Generate a bitmask to be used for the VMCS execution control fields.
 *
 * The caller specifies what bits should be set to one in 'ones_mask'
 * and what bits should be set to zero in 'zeros_mask'. The don't-care
 * bits are set to the default value. The default values are obtained
 * based on "Algorithm 3" in Section 27.5.1 "Algorithms for Determining
 * VMX Capabilities".
 *
 * Returns zero on success and non-zero on error.
 */
int
vmx_set_ctlreg(int ctl_reg, int true_ctl_reg, uint32_t ones_mask,
	       uint32_t zeros_mask, uint32_t *retval)
{
	int i;
	uint64_t val, trueval;
	bool true_ctls_avail, one_allowed, zero_allowed;

	/* We cannot ask the same bit to be set to both '1' and '0' */
	if ((ones_mask ^ zeros_mask) != (ones_mask | zeros_mask))
		return (EINVAL);

	true_ctls_avail = (rdmsr(MSR_VMX_BASIC) & (1UL << 55)) != 0;

	val = rdmsr(ctl_reg);
	if (true_ctls_avail)
		trueval = rdmsr(true_ctl_reg);		/* step c */
	else
		trueval = val;				/* step a */

	for (i = 0; i < 32; i++) {
		one_allowed = vmx_ctl_allows_one_setting(trueval, i);
		zero_allowed = vmx_ctl_allows_zero_setting(trueval, i);

		KASSERT(one_allowed || zero_allowed,
			("invalid zero/one setting for bit %d of ctl 0x%0x, "
			 "truectl 0x%0x\n", i, ctl_reg, true_ctl_reg));

		if (zero_allowed && !one_allowed) {		/* b(i),c(i) */
			if (ones_mask & (1 << i))
				return (EINVAL);
			*retval &= ~(1 << i);
		} else if (one_allowed && !zero_allowed) {	/* b(i),c(i) */
			if (zeros_mask & (1 << i))
				return (EINVAL);
			*retval |= 1 << i;
		} else {
			if (zeros_mask & (1 << i))	/* b(ii),c(ii) */
				*retval &= ~(1 << i);
			else if (ones_mask & (1 << i)) /* b(ii), c(ii) */
				*retval |= 1 << i;
			else if (!true_ctls_avail)
				*retval &= ~(1 << i);	/* b(iii) */
			else if (vmx_ctl_allows_zero_setting(val, i))/* c(iii)*/
				*retval &= ~(1 << i);
			else if (vmx_ctl_allows_one_setting(val, i)) /* c(iv) */
				*retval |= 1 << i;
			else {
				panic("vmx_set_ctlreg: unable to determine "
				      "correct value of ctl bit %d for msr "
				      "0x%0x and true msr 0x%0x", i, ctl_reg,
				      true_ctl_reg);
			}
		}
	}

	return (0);
}

void
msr_bitmap_initialize(char *bitmap)
{

	memset(bitmap, 0xff, PAGE_SIZE);
}

int
msr_bitmap_change_access(char *bitmap, u_int msr, int access)
{
	int byte, bit;

	if (msr <= 0x00001FFF)
		byte = msr / 8;
	else if (msr >= 0xC0000000 && msr <= 0xC0001FFF)
		byte = 1024 + (msr - 0xC0000000) / 8;
	else
		return (EINVAL);

	bit = msr & 0x7;

	if (access & MSR_BITMAP_ACCESS_READ)
		bitmap[byte] &= ~(1 << bit);
	else
		bitmap[byte] |= 1 << bit;

	byte += 2048;
	if (access & MSR_BITMAP_ACCESS_WRITE)
		bitmap[byte] &= ~(1 << bit);
	else
		bitmap[byte] |= 1 << bit;

	return (0);
}

static uint64_t misc_enable;
static uint64_t platform_info;
static uint64_t turbo_ratio_limit;
static uint64_t host_msrs[GUEST_MSR_NUM];

static bool
nehalem_cpu(void)
{
	u_int family, model;

	/*
	 * The family:model numbers belonging to the Nehalem microarchitecture
	 * are documented in Section 35.5, Intel SDM dated Feb 2014.
	 */
	family = CPUID_TO_FAMILY(cpu_id);
	model = CPUID_TO_MODEL(cpu_id);
	if (family == 0x6) {
		switch (model) {
		case 0x1A:
		case 0x1E:
		case 0x1F:
		case 0x2E:
			return (true);
		default:
			break;
		}
	}
	return (false);
}

static bool
westmere_cpu(void)
{
	u_int family, model;

	/*
	 * The family:model numbers belonging to the Westmere microarchitecture
	 * are documented in Section 35.6, Intel SDM dated Feb 2014.
	 */
	family = CPUID_TO_FAMILY(cpu_id);
	model = CPUID_TO_MODEL(cpu_id);
	if (family == 0x6) {
		switch (model) {
		case 0x25:
		case 0x2C:
			return (true);
		default:
			break;
		}
	}
	return (false);
}

static bool
pat_valid(uint64_t val)
{
	int i, pa;

	/*
	 * From Intel SDM: Table "Memory Types That Can Be Encoded With PAT"
	 *
	 * Extract PA0 through PA7 and validate that each one encodes a
	 * valid memory type.
	 */
	for (i = 0; i < 8; i++) {
		pa = (val >> (i * 8)) & 0xff;
		if (pa == 2 || pa == 3 || pa >= 8)
			return (false);
	}
	return (true);
}

void
vmx_msr_init(void)
{
	uint64_t bus_freq, ratio;
	int i;

	/*
	 * It is safe to cache the values of the following MSRs because
	 * they don't change based on curcpu, curproc or curthread.
	 */
	host_msrs[IDX_MSR_LSTAR] = rdmsr(MSR_LSTAR);
	host_msrs[IDX_MSR_CSTAR] = rdmsr(MSR_CSTAR);
	host_msrs[IDX_MSR_STAR] = rdmsr(MSR_STAR);
	host_msrs[IDX_MSR_SF_MASK] = rdmsr(MSR_SF_MASK);

	/*
	 * Initialize emulated MSRs
	 */
	misc_enable = rdmsr(MSR_IA32_MISC_ENABLE);
	/*
	 * Set mandatory bits
	 *  11:   branch trace disabled
	 *  12:   PEBS unavailable
	 * Clear unsupported features
	 *  16:   SpeedStep enable
	 *  18:   enable MONITOR FSM
	 */
	misc_enable |= (1 << 12) | (1 << 11);
	misc_enable &= ~((1 << 18) | (1 << 16));

	if (nehalem_cpu() || westmere_cpu())
		bus_freq = 133330000;		/* 133Mhz */
	else
		bus_freq = 100000000;		/* 100Mhz */

	/*
	 * XXXtime
	 * The ratio should really be based on the virtual TSC frequency as
	 * opposed to the host TSC.
	 */
	ratio = (tsc_freq / bus_freq) & 0xff;

	/*
	 * The register definition is based on the micro-architecture
	 * but the following bits are always the same:
	 * [15:8]  Maximum Non-Turbo Ratio
	 * [28]    Programmable Ratio Limit for Turbo Mode
	 * [29]    Programmable TDC-TDP Limit for Turbo Mode
	 * [47:40] Maximum Efficiency Ratio
	 *
	 * The other bits can be safely set to 0 on all
	 * micro-architectures up to Haswell.
	 */
	platform_info = (ratio << 8) | (ratio << 40);

	/*
	 * The number of valid bits in the MSR_TURBO_RATIO_LIMITx register is
	 * dependent on the maximum cores per package supported by the micro-
	 * architecture. For e.g., Westmere supports 6 cores per package and
	 * uses the low 48 bits. Sandybridge support 8 cores per package and
	 * uses up all 64 bits.
	 *
	 * However, the unused bits are reserved so we pretend that all bits
	 * in this MSR are valid.
	 */
	for (i = 0; i < 8; i++)
		turbo_ratio_limit = (turbo_ratio_limit << 8) | ratio;
}

/*
 * Nested-VMX capability MSR shadow masks (T12).
 *
 * For each capability MSR in the 0x480-0x48F range we cache a pair
 * (and_mask, or_mask) computed from the L0 host MSR values at
 * module-init time.  Reads from L1 are answered as:
 *
 *     result = (host_value & and_mask) | or_mask
 *
 * The masks are picked so that the value advertised to L1 is
 * a valid VMX capability for a hypothetical CPU whose behaviour
 * is at most as expressive as L0's.  Specifically:
 *
 *  - True-control MSRs (e.g. MSR_VMX_TRUE_*_CTLS at 0x48D-0x490)
 *    advertise their existence via bit 55 of MSR_VMX_BASIC; if L0
 *    does not have them, the and_mask clears the corresponding
 *    capability bit in the legacy control MSRs so L1 cannot
 *    silently observe the L0 microarchitecture details.
 *  - Bits that L0 reserves (zeros in the legacy MSR) must remain
 *    zero in the value L1 sees.
 *  - Bits that the architecturally-required minimums force on
 *    (e.g. CR0.PE in MSR_VMX_CR0_FIXED0) are preserved.
 *
 * Implementation note: we cache host values at init time and do
 * not refresh them at runtime; the assumption is that all of
 * these MSRs are CR0/CR4/VMCS/VPMCID-fixed per L0 and do not
 * change while bhyve is running.
 */
static uint64_t vmx_cap_and_mask[16];
static uint64_t vmx_cap_or_mask[16];
static bool vmx_cap_masks_initialized;

static inline uint64_t
vmx_cap_host_read(u_int msr)
{
	switch (msr) {
	case MSR_VMX_BASIC:		return (rdmsr(MSR_VMX_BASIC));
	case MSR_VMX_PINBASED_CTLS:	return (rdmsr(MSR_VMX_PINBASED_CTLS));
	case MSR_VMX_PROCBASED_CTLS:	return (rdmsr(MSR_VMX_PROCBASED_CTLS));
	case MSR_VMX_EXIT_CTLS:		return (rdmsr(MSR_VMX_EXIT_CTLS));
	case MSR_VMX_ENTRY_CTLS:	return (rdmsr(MSR_VMX_ENTRY_CTLS));
	case MSR_VMX_MISC:		return (rdmsr(MSR_VMX_MISC));
	case MSR_VMX_CR0_FIXED0:	return (rdmsr(MSR_VMX_CR0_FIXED0));
	case MSR_VMX_CR0_FIXED1:	return (rdmsr(MSR_VMX_CR0_FIXED1));
	case MSR_VMX_CR4_FIXED0:	return (rdmsr(MSR_VMX_CR4_FIXED0));
	case MSR_VMX_CR4_FIXED1:	return (rdmsr(MSR_VMX_CR4_FIXED1));
	case MSR_VMX_VMCS_ENUM:		return (rdmsr(MSR_VMX_VMCS_ENUM));
	case MSR_VMX_PROCBASED_CTLS2:	return (rdmsr(MSR_VMX_PROCBASED_CTLS2));
	case MSR_VMX_EPT_VPID_CAP:	return (rdmsr(MSR_VMX_EPT_VPID_CAP));
	case MSR_VMX_TRUE_PINBASED_CTLS:
		return (rdmsr(MSR_VMX_TRUE_PINBASED_CTLS));
	case MSR_VMX_TRUE_PROCBASED_CTLS:
		return (rdmsr(MSR_VMX_TRUE_PROCBASED_CTLS));
	case MSR_VMX_TRUE_EXIT_CTLS:	return (rdmsr(MSR_VMX_TRUE_EXIT_CTLS));
	case MSR_VMX_TRUE_ENTRY_CTLS:	return (rdmsr(MSR_VMX_TRUE_ENTRY_CTLS));
	default:
		return (0);
	}
}

static int
vmx_cap_msr_index(u_int msr, u_int *idx)
{

	if (msr < MSR_VMX_BASIC || msr > MSR_VMX_TRUE_ENTRY_CTLS)
		return (EINVAL);
	/*
	 * Index 0 corresponds to MSR_VMX_BASIC; the range is
	 * contiguous apart from MSR_VMX_MISC (0x485) and
	 * MSR_VMX_VMCS_ENUM (0x48a), which we simply treat as
	 * one slot each.
	 */
	*idx = msr - MSR_VMX_BASIC;
	if (*idx >= nitems(vmx_cap_and_mask))
		return (EINVAL);
	return (0);
}

static void
vmx_cap_masks_init(void)
{
	uint64_t basic, host_val;
	u_int i;
	bool has_true_ctls;

	basic = rdmsr(MSR_VMX_BASIC);
	has_true_ctls = (basic & (1UL << 55)) != 0;

	for (i = 0; i < nitems(vmx_cap_and_mask); i++) {
		u_int msr = MSR_VMX_BASIC + i;
		uint64_t zeros, ones;

		host_val = vmx_cap_host_read(msr);
		if (msr == MSR_VMX_MISC ||
		    msr == MSR_VMX_VMCS_ENUM) {
			/*
			 * MISC and VMCS_ENUM are pure reporting MSRs;
			 * pass them through unmodified.
			 */
			vmx_cap_and_mask[i] = ~(uint64_t)0;
			vmx_cap_or_mask[i] = 0;
			continue;
		}

		/*
		 * The capability MSR layout (per Intel SDM §25.1):
		 *   bits 0-31   -> 0 indicates which bits MUST be 1
		 *   bits 32-63  -> 1 indicates which bits MAY be 1
		 * i.e. for a control MSR (the ctl-fixed pattern),
		 * the AND mask must keep the forced-zero bits at 0
		 * and the OR mask must turn on the forced-one bits.
		 *
		 * For data-only MSRs (VMCS_ENUM, MISC, EPT/VPID,
		 * VMFUNC) the host value is meaningful verbatim.
		 */
		zeros = ~host_val & 0xffffffff;
		ones = host_val & 0xffffffff00000000ULL;

		/*
		 * For the legacy control MSRs, if L0 does not provide
		 * the corresponding TRUE control MSR (no bit 55 in
		 * MSR_VMX_BASIC), then the legacy MSR cannot have any
		 * 1-bits in the upper 32 because the upper 32 is
		 * architecturally 0 for a legacy MSR.
		 */
		if (!has_true_ctls && msr != MSR_VMX_BASIC) {
			switch (msr) {
			case MSR_VMX_PINBASED_CTLS:
			case MSR_VMX_PROCBASED_CTLS:
			case MSR_VMX_EXIT_CTLS:
			case MSR_VMX_ENTRY_CTLS:
			case MSR_VMX_PROCBASED_CTLS2:
				ones = 0;
				break;
			default:
				break;
			}
		}

		vmx_cap_and_mask[i] = (uint64_t)0xffffffff & ~zeros;
		vmx_cap_or_mask[i] = ones & 0xffffffff00000000ULL;
	}
	vmx_cap_masks_initialized = true;
}

int
vmx_nested_cap_msr_read(struct vmx_vcpu *vcpu __unused, u_int msr, uint64_t *val)
{
	u_int idx;
	uint64_t host_val;

	if (!vmx_cap_masks_initialized)
		vmx_cap_masks_init();
	if (vmx_cap_msr_index(msr, &idx) != 0)
		return (EINVAL);

	host_val = vmx_cap_host_read(msr);
	*val = (host_val & vmx_cap_and_mask[idx]) | vmx_cap_or_mask[idx];
	return (0);
}

void
vmx_nested_msr_intercept_init(struct vmx *vmx, struct vmx_vcpu *vcpu)
{
	u_int msr;

	if (vmx == NULL || vmx->vm == NULL || !vmx->vm->nested_enabled)
		return;

	/*
	 * The MSR bitmap is shared between vcpus; install the L1
	 * range once at vBSP time, before VMPTRLD.
	 */
	if (vcpu->vcpuid != 0)
		return;

	/*
	 * Intercept all reads of the VMX capability range so L1 sees
	 * the nested-safe values rather than the raw L0 capability
	 * MSRs.  Writes remain intercepted too: the architecture
	 * requires #GP on WRMSR to any VMX capability MSR.
	 */
	for (msr = MSR_VMX_BASIC; msr <= MSR_VMX_TRUE_ENTRY_CTLS; msr++) {
		if (msr_bitmap_change_access(vmx->msr_bitmap, msr,
		    MSR_BITMAP_ACCESS_RW) != 0) {
			/*
			 * MSRs outside the two bitmap ranges
			 * (0..0x1FFF and 0xC0000000..0xC0001FFF)
			 * cannot be intercepted; the VMX capability
			 * range sits inside 0..0x1FFF so this branch
			 * is unreachable in practice.  Log anyway.
			 */
			printf("vmx_nested_msr_intercept_init: cannot "
			    "intercept msr %#x\n", msr);
		}
	}
}

void
vmx_msr_guest_init(struct vmx *vmx, struct vmx_vcpu *vcpu)
{
	/*
	 * The permissions bitmap is shared between all vcpus so initialize it
	 * once when initializing the vBSP.
	 */
	if (vcpu->vcpuid == 0) {
		guest_msr_rw(vmx, MSR_LSTAR);
		guest_msr_rw(vmx, MSR_CSTAR);
		guest_msr_rw(vmx, MSR_STAR);
		guest_msr_rw(vmx, MSR_SF_MASK);
		guest_msr_rw(vmx, MSR_KGSBASE);
		vmx_nested_msr_intercept_init(vmx, vcpu);
	}

	/*
	 * Initialize guest IA32_PAT MSR with default value after reset.
	 */
	vcpu->guest_msrs[IDX_MSR_PAT] = PAT_VALUE(0, PAT_WRITE_BACK) |
	    PAT_VALUE(1, PAT_WRITE_THROUGH)	|
	    PAT_VALUE(2, PAT_UNCACHED)		|
	    PAT_VALUE(3, PAT_UNCACHEABLE)	|
	    PAT_VALUE(4, PAT_WRITE_BACK)	|
	    PAT_VALUE(5, PAT_WRITE_THROUGH)	|
	    PAT_VALUE(6, PAT_UNCACHED)		|
	    PAT_VALUE(7, PAT_UNCACHEABLE);

	return;
}

void
vmx_msr_guest_enter(struct vmx_vcpu *vcpu)
{

	/* Save host MSRs (in particular, KGSBASE) and restore guest MSRs */
	update_pcb_bases(curpcb);
	wrmsr(MSR_LSTAR, vcpu->guest_msrs[IDX_MSR_LSTAR]);
	wrmsr(MSR_CSTAR, vcpu->guest_msrs[IDX_MSR_CSTAR]);
	wrmsr(MSR_STAR, vcpu->guest_msrs[IDX_MSR_STAR]);
	wrmsr(MSR_SF_MASK, vcpu->guest_msrs[IDX_MSR_SF_MASK]);
	wrmsr(MSR_KGSBASE, vcpu->guest_msrs[IDX_MSR_KGSBASE]);
}

void
vmx_msr_guest_enter_tsc_aux(struct vmx *vmx, struct vmx_vcpu *vcpu)
{
	uint64_t guest_tsc_aux = vcpu->guest_msrs[IDX_MSR_TSC_AUX];
	uint32_t host_aux = cpu_auxmsr();

	if (vmx_have_msr_tsc_aux && guest_tsc_aux != host_aux)
		wrmsr(MSR_TSC_AUX, guest_tsc_aux);
}

void
vmx_msr_guest_exit(struct vmx_vcpu *vcpu)
{

	/* Save guest MSRs */
	vcpu->guest_msrs[IDX_MSR_LSTAR] = rdmsr(MSR_LSTAR);
	vcpu->guest_msrs[IDX_MSR_CSTAR] = rdmsr(MSR_CSTAR);
	vcpu->guest_msrs[IDX_MSR_STAR] = rdmsr(MSR_STAR);
	vcpu->guest_msrs[IDX_MSR_SF_MASK] = rdmsr(MSR_SF_MASK);
	vcpu->guest_msrs[IDX_MSR_KGSBASE] = rdmsr(MSR_KGSBASE);

	/* Restore host MSRs */
	wrmsr(MSR_LSTAR, host_msrs[IDX_MSR_LSTAR]);
	wrmsr(MSR_CSTAR, host_msrs[IDX_MSR_CSTAR]);
	wrmsr(MSR_STAR, host_msrs[IDX_MSR_STAR]);
	wrmsr(MSR_SF_MASK, host_msrs[IDX_MSR_SF_MASK]);

	/* MSR_KGSBASE will be restored on the way back to userspace */
}

void
vmx_msr_guest_exit_tsc_aux(struct vmx *vmx, struct vmx_vcpu *vcpu)
{
	uint64_t guest_tsc_aux = vcpu->guest_msrs[IDX_MSR_TSC_AUX];
	uint32_t host_aux = cpu_auxmsr();

	if (vmx_have_msr_tsc_aux && guest_tsc_aux != host_aux)
		/*
		 * Note that it is not necessary to save the guest value
		 * here; vcpu->guest_msrs[IDX_MSR_TSC_AUX] always
		 * contains the current value since it is updated whenever
		 * the guest writes to it (which is expected to be very
		 * rare).
		 */
		wrmsr(MSR_TSC_AUX, host_aux);
}

int
vmx_rdmsr(struct vmx_vcpu *vcpu, u_int num, uint64_t *val, bool *retu)
{
	int error;

	error = 0;

	/*
	 * Nested-VMX: when the L1 hypervisor reads a VMX capability
	 * MSR, answer with the nested-safe masked value rather than
	 * the raw L0 host value.  The bitmap interception installed
	 * by vmx_nested_msr_intercept_init() ensures this branch is
	 * taken for every L1 access to 0x480-0x48F.
	 */
	if (vcpu->vmx != NULL && vcpu->vmx->vm != NULL &&
	    vcpu->vmx->vm->nested_enabled &&
	    num >= MSR_VMX_BASIC && num <= MSR_VMX_TRUE_ENTRY_CTLS) {
		return (vmx_nested_cap_msr_read(vcpu, num, val));
	}

	switch (num) {
	case MSR_MCG_CAP:
	case MSR_MCG_STATUS:
		*val = 0;
		break;
	case MSR_MTRRcap:
	case MSR_MTRRdefType:
	case MSR_MTRR4kBase ... MSR_MTRR4kBase + 7:
	case MSR_MTRR16kBase ... MSR_MTRR16kBase + 1:
	case MSR_MTRR64kBase:
	case MSR_MTRRVarBase ... MSR_MTRRVarBase + (VMM_MTRR_VAR_MAX * 2) - 1:
		if (vm_rdmtrr(&vcpu->mtrr, num, val) != 0) {
			vm_inject_gp(vcpu->vcpu);
		}
		break;
	case MSR_IA32_MISC_ENABLE:
		*val = misc_enable;
		break;
	case MSR_PLATFORM_INFO:
		*val = platform_info;
		break;
	case MSR_TURBO_RATIO_LIMIT:
	case MSR_TURBO_RATIO_LIMIT1:
		*val = turbo_ratio_limit;
		break;
	case MSR_PAT:
		*val = vcpu->guest_msrs[IDX_MSR_PAT];
		break;
	default:
		error = EINVAL;
		break;
	}
	return (error);
}

int
vmx_wrmsr(struct vmx_vcpu *vcpu, u_int num, uint64_t val, bool *retu)
{
	uint64_t changed;
	int error;

	error = 0;

	/*
	 * Nested-VMX: any WRMSR to the VMX capability range must
	 * be reported as #GP to L1.  The architecture mandates that
	 * these MSRs are read-only; an emulation that silently
	 * ignored the write would let L1 corrupt its view of L0.
	 */
	if (vcpu->vmx != NULL && vcpu->vmx->vm != NULL &&
	    vcpu->vmx->vm->nested_enabled &&
	    num >= MSR_VMX_BASIC && num <= MSR_VMX_TRUE_ENTRY_CTLS) {
		vm_inject_gp(vcpu->vcpu);
		return (0);
	}

	switch (num) {
	case MSR_MCG_CAP:
	case MSR_MCG_STATUS:
		break;		/* ignore writes */
	case MSR_MTRRcap:
	case MSR_MTRRdefType:
	case MSR_MTRR4kBase ... MSR_MTRR4kBase + 7:
	case MSR_MTRR16kBase ... MSR_MTRR16kBase + 1:
	case MSR_MTRR64kBase:
	case MSR_MTRRVarBase ... MSR_MTRRVarBase + (VMM_MTRR_VAR_MAX * 2) - 1:
		if (vm_wrmtrr(&vcpu->mtrr, num, val) != 0) {
			vm_inject_gp(vcpu->vcpu);
		}
		break;
	case MSR_IA32_MISC_ENABLE:
		changed = val ^ misc_enable;
		/*
		 * If the host has disabled the NX feature then the guest
		 * also cannot use it. However, a Linux guest will try to
		 * enable the NX feature by writing to the MISC_ENABLE MSR.
		 *
		 * This can be safely ignored because the memory management
		 * code looks at CPUID.80000001H:EDX.NX to check if the
		 * functionality is actually enabled.
		 */
		changed &= ~(1UL << 34);

		/*
		 * Punt to userspace if any other bits are being modified.
		 */
		if (changed)
			error = EINVAL;

		break;
	case MSR_PAT:
		if (pat_valid(val))
			vcpu->guest_msrs[IDX_MSR_PAT] = val;
		else
			vm_inject_gp(vcpu->vcpu);
		break;
	case MSR_TSC:
		error = vmx_set_tsc_offset(vcpu, val - rdtsc());
		break;
	case MSR_TSC_AUX:
		if (vmx_have_msr_tsc_aux)
			/*
			 * vmx_msr_guest_enter_tsc_aux() will apply this
			 * value when it is called immediately before guest
			 * entry.
			 */
			vcpu->guest_msrs[IDX_MSR_TSC_AUX] = val;
		else
			vm_inject_gp(vcpu->vcpu);
		break;
	default:
		error = EINVAL;
		break;
	}

	return (error);
}
