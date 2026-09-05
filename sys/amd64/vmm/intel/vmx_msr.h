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

#ifndef _VMX_MSR_H_
#define	_VMX_MSR_H_

struct vmx;

void vmx_msr_init(void);
void vmx_msr_guest_init(struct vmx *vmx, struct vmx_vcpu *vcpu);
void vmx_msr_guest_enter_tsc_aux(struct vmx *vmx, struct vmx_vcpu *vcpu);
void vmx_msr_guest_enter(struct vmx_vcpu *vcpu);
void vmx_msr_guest_exit(struct vmx_vcpu *vcpu);
void vmx_msr_guest_exit_tsc_aux(struct vmx *vmx, struct vmx_vcpu *vcpu);
int vmx_rdmsr(struct vmx_vcpu *vcpu, u_int num, uint64_t *val, bool *retu);
int vmx_wrmsr(struct vmx_vcpu *vcpu, u_int num, uint64_t val, bool *retu);

uint32_t vmx_revision(void);

/*
 * Nested-VMX MSR virtualization (Wave 3 / T12-T16).
 *
 * When a VM is created with VMMAPI_OPEN_CREATE_NESTED, the L1 guest
 * must be able to read the same VMX capability MSR layout as L0
 * would expose to L1 in a native-VMX run.  The capability MSR range
 * (0x480-0x48F) is intercepted via the MSR bitmap, and reads are
 * answered by vmx_nested_cap_msr_read() which returns the L0 host
 * values AND-OR'd with a nested-safe mask so L1 cannot discover L0
 * microarchitecture details that cannot actually be nested.
 *
 * The masks are computed once at module-init time and stored in
 * static storage.
 */
int vmx_nested_cap_msr_read(struct vmx_vcpu *vcpu, u_int msr, uint64_t *val);

/*
 * Install the L1-targeted bitmap interceptions for the VMX
 * capability MSR range (0x480-0x48F).  Must be called from
 * vmx_msr_guest_init() on vcpuid 0, before VMPTRLD so the MSR
 * bitmap is in place when the VMCS becomes active.  No-op if
 * nested_enabled is false for this VM.
 */
void vmx_nested_msr_intercept_init(struct vmx *vmx, struct vmx_vcpu *vcpu);

int vmx_set_ctlreg(int ctl_reg, int true_ctl_reg, uint32_t ones_mask,
		   uint32_t zeros_mask, uint32_t *retval);

/*
 * According to Section 21.10.4 "Software Access to Related Structures",
 * changes to data structures pointed to by the VMCS must be made only when
 * there is no logical processor with a current VMCS that points to the
 * data structure.
 *
 * This pretty much limits us to configuring the MSR bitmap before VMCS
 * initialization for SMP VMs. Unless of course we do it the hard way - which
 * would involve some form of synchronization between the vcpus to vmclear
 * all VMCSs' that point to the bitmap.
 */
#define	MSR_BITMAP_ACCESS_NONE	0x0
#define	MSR_BITMAP_ACCESS_READ	0x1
#define	MSR_BITMAP_ACCESS_WRITE	0x2
#define	MSR_BITMAP_ACCESS_RW	(MSR_BITMAP_ACCESS_READ|MSR_BITMAP_ACCESS_WRITE)
void	msr_bitmap_initialize(char *bitmap);
int	msr_bitmap_change_access(char *bitmap, u_int msr, int access);

#define	guest_msr_rw(vmx, msr) \
    msr_bitmap_change_access((vmx)->msr_bitmap, (msr), MSR_BITMAP_ACCESS_RW)

#define	guest_msr_ro(vmx, msr) \
    msr_bitmap_change_access((vmx)->msr_bitmap, (msr), MSR_BITMAP_ACCESS_READ)

#endif
