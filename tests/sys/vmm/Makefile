PACKAGE=	tests

TESTSDIR=	${TESTSBASE}/sys/vmm

BINDIR=		${TESTSDIR}

ATF_TESTS_SH+=	vmm_cred_jail

# SUBDIR rather than TESTS_SUBDIRS. TESTS_SUBDIRS also writes
# include("nested/Kyuafile") into this directory's Kyuafile, which ships in
# the tests package -- while everything under nested/ now ships in
# nested-tests. kyua aborts on a missing include, so that line would break
# the whole base test suite on any machine that installed tests without
# nested-tests. Run the nested suite as:
#
#	kyua test -k /usr/tests/sys/vmm/nested/Kyuafile
SUBDIR+=	nested

${PACKAGE}FILES+=	utils.subr

.include <bsd.test.mk>
