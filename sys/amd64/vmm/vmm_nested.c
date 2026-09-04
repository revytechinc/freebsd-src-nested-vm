/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * All rights reserved.
 */

#include <sys/param.h>
#include <sys/malloc.h>
#include <sys/systm.h>
#include <sys/kernel.h>

#include <machine/vmm.h>

#include <dev/vmm/vmm_vm.h>

#include "vmm_nested.h"

static MALLOC_DEFINE(M_VMM_NESTED, "vmm-nested",
    "bhyve nested-virt per-vcpu state");

struct nested_vcpu_state *
nested_vcpu_state_factory(enum nested_platform p, struct vm *vm, int vcpuid)
{
	struct nested_vcpu_state *nv;

	nv = malloc(sizeof(*nv), M_VMM_NESTED, M_WAITOK | M_ZERO);
	switch (p) {
	case NV_PLATFORM_INTEL:
		nv->magic = NV_MAGIC_INTEL;
		break;
	case NV_PLATFORM_AMD:
		nv->magic = NV_MAGIC_AMD;
		break;
	default:
		free(nv, M_VMM_NESTED);
		return (NULL);
	}
	nv->platform = p;
	return (nv);
}