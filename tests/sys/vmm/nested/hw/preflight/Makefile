PACKAGE=	tests

TESTSDIR=	${TESTSBASE}/sys/vmm/nested/hw/preflight

BINDIR=		${TESTSDIR}

ATF_TESTS_SH+=	preflight_integrity

${PACKAGE}FILES+=	preflight_unit_help.sh \
			preflight_unit_classify.sh \
			preflight_sysctl_paths.sh \
			preflight_intel_ivybridge.sh \
			preflight_vmx_cap_msr_masks.sh \
			preflight_nested_classify_skylake.sh \
			preflight_amd_classify_zen2_zen3.sh \
			preflight_cr4_vmxe.sh \
			preflight_vmx_capability_typing.sh \
			preflight_ept12_walker.sh \
			preflight_invept_descriptor.sh \
			preflight_unit_test_module.sh \
			preflight_vmcs_shadowing_scoped.sh \
			preflight_vmcs12_state_transitions.sh \
			run_preflight_tests.sh

.include <bsd.test.mk>
