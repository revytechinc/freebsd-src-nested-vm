PACKAGE=	tests

TESTSDIR=	${TESTSBASE}/sys/vmm/nested

BINDIR=		${TESTSDIR}

ATF_TESTS_SH+=	nested_basic
ATF_TESTS_SH+=	hyperv_basic
ATF_TESTS_SH+=	vmx_basic
ATF_TESTS_SH+=	svm_basic

${PACKAGE}FILES+=	nested_utils.subr
${PACKAGE}FILES+=	vmx_basic.sh
${PACKAGE}FILES+=	svm_basic.sh
${PACKAGE}FILES+=	deployment_safety.sh
${PACKAGE}FILES+=	nested-test
${PACKAGE}FILESMODE_nested-test=	${BINMODE}

# Without these the subdirectories are never built and never installed, so the
# harness has to be copied onto each host by hand -- and a host whose boot
# environment reverts silently takes an old harness with it, which then fails a
# perfectly good kernel. Ship the tests with the build they test.
# Directories holding ATF test programs must be listed in TESTS_SUBDIRS,
# not SUBDIR.  share/mk/suite.test.mk generates the installed Kyuafile and
# emits `include("<dir>/Kyuafile")` only for TESTS_SUBDIRS entries, so a
# test directory in SUBDIR installs correctly to /usr/tests and is then
# invisible to kyua(1) -- it never runs, and nothing reports an error.
# bsd.test.mk states the rule: "list here any directories that contain
# test programs but use SUBDIR for directories that may contain helper
# binaries and/or data files."
TESTS_SUBDIRS+=	abisnap
TESTS_SUBDIRS+=	hw

# Helper, data and tooling directories: built and installed, but they hold
# no ATF test programs for kyua to descend into.
SUBDIR+=	demo
SUBDIR+=	lib
SUBDIR+=	features
SUBDIR+=	fuzz
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
SUBDIR+=	stats

.include <bsd.test.mk>
