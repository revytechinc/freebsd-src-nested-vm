# $FreeBSD$
#
# Build glue for the svm_nested_test kernel loadable module.
#
# This module is a TEST-ONLY kld that exercises the SVM (AMD) register
# virtualization paths provided by the nested virt implementation compiled
# into vmm.ko (see sys/amd64/vmm/vmm_nested.c and sys/amd64/vmm/amd/svm.c).
#
# Loading: kldload ./svm_nested_test.ko
# Unload: kldunload svm_nested_test
#
# The module exposes a SYSCTL_INT(_vmm_nested, OID_AUTO, selftest, CTLFLAG_RW)
# knob that triggers the self-test routines and prints PASS/FAIL to dmesg.
#
# Architecture (T4/T5 single-architecture decision):
#   - All nested impl code is compiled into vmm.ko (no separate *_nested.ko).
#   - Only the TEST modules are separate klds. Build will fail until T11
#     lands svm_nested_test.c at sys/amd64/vmm/amd/svm_nested_test.c.
#
# DO NOT add svm_nested.c to vmm.ko SRCS — runtime gating is the contract.

PACKAGE=	tests

.PATH: ${SRCTOP}/sys/amd64/vmm/amd

KMOD=	svm_nested_test
SRCS=	svm_nested_test.c

.include <bsd.kmod.mk>