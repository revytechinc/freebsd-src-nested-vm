PACKAGE=	tests

TESTSDIR=	${TESTSBASE}/sys/vmm/nested/hw/preflight

BINDIR=		${TESTSDIR}

ATF_TESTS_SH+=	preflight_integrity

${PACKAGE}FILES+=	preflight_unit_help.sh \
			preflight_unit_classify.sh \
			preflight_sysctl_paths.sh \
			preflight_intel_ivybridge.sh \
			run_preflight_tests.sh

.include <bsd.test.mk>