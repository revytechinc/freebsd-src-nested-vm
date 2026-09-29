# This directory ships its preflight scripts as FILES, with
# run_preflight_tests.sh as the driver, and declares no ATF test. It used to
# declare ATF_TESTS_SH+= preflight_integrity, but preflight_integrity.sh is
# not in the tree -- so kyua had nothing to run either way. The stale
# reference only became visible once this directory was wired into the build.
PACKAGE=	nested-tests

TESTSDIR=	${TESTSBASE}/sys/vmm/nested/hw/preflight

BINDIR=		${TESTSDIR}


# Listed in no Makefile until now, so the dispatcher never shipped.
${PACKAGE}FILES+=	preflight_nsvm_dispatcher.sh
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
			preflight_arch_output_test.sh \
			preflight_arch_consistency_test.sh \
			preflight_critical_bugfix_test.sh \
			run_preflight_tests.sh

# Every member of this group is a script. bsd.files.mk would give them
# SHAREMODE (0444), which cannot be executed by anyone, root included. The
# driver happens to invoke them as `bash <file>` so the modes have not bitten
# yet, but shipping a program unexecutable is the fault this whole change is
# about, and one `./script` anywhere would surface it. Set for the group, not
# per file, so a script added above cannot miss it.
${PACKAGE}FILESMODE=	0555

.include <bsd.test.mk>
