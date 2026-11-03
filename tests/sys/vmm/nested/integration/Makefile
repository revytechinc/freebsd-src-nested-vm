PACKAGE=	tests

TESTSDIR=	${TESTSBASE}/sys/vmm/nested/integration

BINDIR=		${TESTSDIR}
PROGS+=		bhyve_nested

# The build system rejects DPADD/LDADD+=-lfoo for a library it knows:
# src.libnames.mk turns it into a hard error. LIBADD is the supported
# spelling and pulls the dependency in for free.
LIBADD+=	vmmapi

# These five were present in the directory and named in no Makefile, so
# they were never installed and could not run on any host.  l2_smoke.sh is
# the only test in the tree that proves an L2 guest actually executed.
${PACKAGE}FILES+=	bhyve_in_bhyve.sh
${PACKAGE}FILES+=	l2_smoke.sh
${PACKAGE}FILES+=	smp_l1.sh
${PACKAGE}FILES+=	stress_vmrun.sh
${PACKAGE}FILES+=	triple_nested.sh

.include <bsd.test.mk>