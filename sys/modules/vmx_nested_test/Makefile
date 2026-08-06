# $FreeBSD$
#
# Build glue for the vmx_nested_test kernel loadable module.
#
# This module is a TEST-ONLY kld that exercises the VMX (Intel) register
# virtualization paths provided by the nested virt implementation compiled
# into vmm.ko (see sys/amd64/vmm/vmm_nested.c and sys/amd64/vmm/intel/vmx.c).
#
# Loading: kldload ./vmx_nested_test.ko
# Unload: kldunload vmx_nested_test
#
# The module exposes a SYSCTL_INT(_vmm_nested, OID_AUTO, selftest, CTLFLAG_RW)
# knob that triggers the self-test routines and prints PASS/FAIL to dmesg.
#
# Architecture (T4/T5 single-architecture decision):
#   - All nested impl code is compiled into vmm.ko (no separate *_nested.ko).
#   - Only the TEST modules are separate klds. Build will fail until T17
#     lands vmx_nested_test.c at sys/amd64/vmm/intel/vmx_nested_test.c.
#
# DO NOT add vmx_nested.c to vmm.ko SRCS — runtime gating is the contract.

PACKAGE=	tests

.PATH: ${SRCTOP}/sys/amd64/vmm/intel

# The test module #includes "vmcs.h" and "vmx.h" from the intel vmm
# tree; vmx.h in turn #includes the parent vmm "x86.h".  Add both
# directories to CFLAGS so all the headers resolve when compiling
# the module in isolation (without the vmm.ko SRCS set).
CFLAGS+= -I${SRCTOP}/sys/amd64/vmm/intel
CFLAGS+= -I${SRCTOP}/sys/amd64/vmm

KMOD=	vmx_nested_test
SRCS=	vmx_nested_test.c

.include <bsd.kmod.mk>