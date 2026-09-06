PACKAGE=	tests

TESTSDIR=	${TESTSBASE}/sys/vmm/nested

BINDIR=		${TESTSDIR}

ATF_TESTS_SH+=	nested_basic
ATF_TESTS_SH+=	hyperv_basic
ATF_TESTS_SH+=	vmx_basic

${PACKAGE}FILES+=	nested_utils.subr
${PACKAGE}FILES+=	vmx_basic.sh

# Without these the subdirectories are never built and never installed, so the
# harness has to be copied onto each host by hand -- and a host whose boot
# environment reverts silently takes an old harness with it, which then fails a
# perfectly good kernel. Ship the tests with the build they test.
SUBDIR+=	abisnap
SUBDIR+=	features
SUBDIR+=	fuzz
SUBDIR+=	hw
SUBDIR+=	integration
SUBDIR+=	io
SUBDIR+=	negative
SUBDIR+=	parity
SUBDIR+=	perf
SUBDIR+=	recovery
SUBDIR+=	resource
SUBDIR+=	scripts
SUBDIR+=	snapshot
SUBDIR+=	soak

.include <bsd.test.mk>
