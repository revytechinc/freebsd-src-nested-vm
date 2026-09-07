#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# In-kernel unit tests for the nested-VMX helpers. Loading the module runs
# every test and prints PASS/FAIL/SKIP to the console; it is never loaded by a
# running system on its own.
#
# This Makefile did not exist, so the test file could not be built at all --
# and the symbols it calls were localised by kmod.mk's EXPORT_SYMS default, so
# it could not have linked either. Both are fixed together.

.PATH: ${SRCTOP}/sys/amd64/vmm/intel

KMOD=	vmx_nested_test
SRCS=	vmx_nested_test.c
SRCS+=	device_if.h bus_if.h pci_if.h
# The same option headers sys/modules/vmm builds with. Nothing reachable from
# here is conditional on them today -- vmcs.h guards prototypes, not struct
# members -- but this module links against vmm.ko and reasons about the layout
# of structures it shares, so the two builds must not be able to disagree
# about an option. Keeping the lists identical is cheaper than rediscovering
# why a sizeof() assertion passed in one module and failed in the other.
SRCS+=	opt_acpi.h		\
	opt_bhyve_snapshot.h	\
	opt_ddb.h

CFLAGS+= -I${SRCTOP}/sys/amd64/vmm
CFLAGS+= -I${SRCTOP}/sys/amd64/vmm/intel

.include <bsd.kmod.mk>
