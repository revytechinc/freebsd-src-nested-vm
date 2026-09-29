PACKAGE=	nested-tests

TESTSDIR=	${TESTSBASE}/sys/vmm/nested/integration

BINDIR=		${TESTSDIR}
PROGS+=		bhyve_nested

# The build system rejects DPADD/LDADD+=-lfoo for a library it knows:
# src.libnames.mk turns it into a hard error. LIBADD is the supported
# spelling and pulls the dependency in for free.
LIBADD+=	vmmapi

# The shell drivers, which were omitted. Every other directory under nested/
# lists its .sh files here; this one listed none, so all five were built
# around and never installed -- l2_smoke.sh among them, the only test in the
# tree that proves an L2 guest executes. A host therefore had fixtures/ and no
# way to use them, and the harness had to be copied on by hand, which is
# exactly what the parent Makefile's comment says this wiring exists to stop.
#
# scripts/run_l2_smoke.sh ships and invokes l2_smoke.sh, so the wrapper was
# installed without the thing it wraps.
${PACKAGE}FILES+=	bhyve_in_bhyve.sh
${PACKAGE}FILES+=	l0_control.sh
${PACKAGE}FILES+=	l2_smoke.sh
${PACKAGE}FILES+=	smp_l1.sh
${PACKAGE}FILES+=	stress_vmrun.sh
${PACKAGE}FILES+=	triple_nested.sh

# bsd.files.mk would give these SHAREMODE (0444), and a 0444 script cannot be
# executed -- not even by root, which needs at least one x bit. Set it for the
# group rather than per file, so a script added above without a matching mode
# line cannot reproduce the bug. Every member of this group is a program.
${PACKAGE}FILESMODE=	0555

# Unit tests for l2_smoke.sh's argument validation, DECLARED as a test rather
# than shipped as a FILES entry. Shipping is not executing: a *_test.sh that
# installs and never runs is the "gap that looks like coverage" the parent
# Makefile documents at length. It needs no root, no vmm(4) and no L1 image,
# so unlike its siblings here it is safe for kyua to run unattended.
#
# This is why `integration' is in TESTS_SUBDIRS rather than plain SUBDIR: the
# directory now declares a test, so the generated include has something to
# reach. The safety criterion the parent Makefile sets out is met -- PACKAGE
# is nested-tests above, the same package as the Kyuafile that includes it, so
# the include cannot dangle on a host that installed tests without
# nested-tests. The other scripts here stay FILES and are still run by hand.
PLAIN_TESTS_SH+=	l2_smoke_args_test

.include <bsd.test.mk>