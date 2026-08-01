PACKAGE=	tests

TESTSDIR=	${TESTSBASE}/sys/vmm/nested/integration

BINDIR=		${TESTSDIR}
PROGS+=		bhyve_nested

DPADD+=		${LIBVMMAPI}
LDADD+=		-lvmmapi

.include <bsd.test.mk>