PACKAGE=	tests

ATF_TESTS_SH+=	bhyveload_test

# The VM cases create and destroy VMs, which live in a single global
# namespace, so they must not run alongside anything else doing the same.
TEST_METADATA+=	is_exclusive="true"

.include <bsd.test.mk>
