PACKAGE=	nested-tests

TESTSDIR=	${TESTSBASE}/sys/vmm/nested/integration

BINDIR=		${TESTSDIR}
PROGS+=		bhyve_nested

# The build system rejects DPADD/LDADD+=-lfoo for a library it knows:
# src.libnames.mk turns it into a hard error. LIBADD is the supported
# spelling and pulls the dependency in for free.
LIBADD+=	vmmapi

.include <bsd.test.mk>