/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * Nested virtualization support for bhyve.
 * Original BSD code; KVM is referenced only for design.
 */

#ifndef _VMM_NESTED_H_
#define _VMM_NESTED_H_

#include <sys/systm.h>
#include <sys/types.h>

/*
 * Shared bitmap primitives used by both SVM and VMX nested-virt code.
 * Layout mirrors the AMD MSRPM (2 KB read + 2 KB write per 4 KB page, two
 * pages) and the Intel VMX MSR bitmap (one 4 KB page shared across all
 * regions); the per-platform callers know which layout is in use.
 */
struct nested_bitmap {
	uint8_t	*map;
	size_t	 size;
};

static __inline void
nested_bitmap_init(struct nested_bitmap *nb, void *backing, size_t size)
{
	nb->map = backing;
	nb->size = size;
	memset(nb->map, 0, size);
}

/* SVM-only: 0x0000-0x1FFF page 0, 0xC0000000-0xC0001FFF page 1. */
#define SVM_MSR_BITMAP_PAGE0	0x0000
#define SVM_MSR_BITMAP_PAGE1	0xC0000000

#define NV_MAGIC_INTEL	0x564E4E49	/* 'INNV' */
#define NV_MAGIC_AMD	0x534E4E41	/* 'ANNS' */

enum nested_platform {
	NV_PLATFORM_INTEL = 0,
	NV_PLATFORM_AMD   = 1,
};

/* Per-vCPU nested state. Platform-specific extension struct is allocated
 * by the factory and tacked on via the cookie. */
struct nested_vcpu_state {
	uint32_t	magic;
	enum nested_platform platform;
};

/* Factory: returns a zeroed per-vCPU nested state. */
struct nested_vcpu_state *nested_vcpu_state_factory(enum nested_platform p,
    struct vm *vm, int vcpuid);

#endif /* _VMM_NESTED_H_ */