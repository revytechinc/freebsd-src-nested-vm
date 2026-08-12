PACKAGE=	tests

TESTSDIR=	${TESTSBASE}/sys/vmm/nested

BINDIR=		${TESTSDIR}

ATF_TESTS_SH+=	nested_basic
ATF_TESTS_SH+=	hyperv_basic
ATF_TESTS_SH+=	vmx_basic

${PACKAGE}FILES+=	nested_utils.subr
${PACKAGE}FILES+=	vmx_basic.sh

.include <bsd.test.mk>
