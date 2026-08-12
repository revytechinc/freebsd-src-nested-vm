# $FreeBSD$
#
# Build glue for the hyperv_nested_test kernel loadable module.
#
# This module is a TEST-ONLY kld that exercises the Hyper-V enlightened MSR
# synthesis paths inside the bhyve/amd64 nested virt implementation compiled
# into vmm.ko (see sys/amd64/vmm/intel/vmx_msr.c and sys/amd64/vmm/amd/svm_msr.c,
# plus usr.sbin/bhyve/amd64/xmsr.c).
#
# Loading: kldload ./hyperv_nested_test.ko
# Unload: kldunload hyperv_nested_test
#
# The module exposes a SYSCTL_INT(_vmm_nested, OID_AUTO, selftest, CTLFLAG_RW)
# knob that triggers the self-test routines and prints PASS/FAIL to dmesg.
#
# Architecture (T4/T5 single-architecture decision):
#   - Hyper-V synthesis lives in the bhyve path (vmx_msr.c / svm_msr.c),
#     already compiled into vmm.ko for the kernel-side. There is no
#     separate Hyper-V kld; this is the test harness only.
#   - Only the TEST modules are separate klds. Build will fail until T36
#     lands hyperv_nested_test.c at sys/amd64/vmm/hyperv_nested_test.c.
#
# DO NOT create sys/modules/hyperv_nested/ — runtime gating is the contract.

PACKAGE=	tests

.PATH: ${SRCTOP}/sys/amd64/vmm

KMOD=	hyperv_nested_test
SRCS=	hyperv_nested_test.c

.include <bsd.kmod.mk>