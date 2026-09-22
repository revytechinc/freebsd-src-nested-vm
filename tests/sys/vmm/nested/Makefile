PACKAGE=	nested-tests

TESTSDIR=	${TESTSBASE}/sys/vmm/nested

BINDIR=		${TESTSDIR}

ATF_TESTS_SH+=	nested_basic
ATF_TESTS_SH+=	hyperv_basic
ATF_TESTS_SH+=	vmx_basic
# The counterpart of vmx_basic, which was in the tree but listed nowhere: not
# registered, so kyua never ran it, and not installed, so it could not have
# been run by hand either. The Intel-named smoke test shipped and this one did
# not.
#
# What it actually checks is the hw.vmm.nested.enable surface, which is not
# vendor-specific despite the name -- it does not launch a guest, as its own
# header says. It skips where the hw.vmm.nested NODE is absent and FAILS
# where that node is present but the gate under it is not, so it is safe on a
# host running stock vmm(4) as well as on Intel.
#
# Known limit, recorded rather than papered over: require.kmods skips when
# vmm(4) is not LOADED, and a correctly deployed host has vmm_load="NO" (which
# is what deployment_safety's vmm_load_disabled case checks). So on such a
# host this reports SKIPPED rather than running. Loading vmm from the test
# would itself be a change to the host, so the caller is left to kldload vmm
# before running the suite if the check is wanted there.
ATF_TESTS_SH+=	svm_basic
# svm_basic writes hw.vmm.nested.enable, a HOST-GLOBAL knob, and puts it back.
# A test running beside it could save that temporary 1 and "restore" it
# permanently -- within one kyua run; this serialises nothing else on the
# host. (vmx_basic is not that test -- measured: it does not touch
# hw.vmm.nested.enable at all, only hw.vmm.nested.vmx and .svm, which it
# reads.) TEST_METADATA is where the tree declares this (see
# tests/sys/netinet, tests/sys/net/routing); atf_set "is_exclusive" is not a
# valid property and breaks the test program outright.
TEST_METADATA.svm_basic+=	is_exclusive="true"

${PACKAGE}FILES+=	nested_utils.subr
${PACKAGE}FILES+=	vmx_basic.sh
# No FILES entry for svm_basic.sh: ATF_TESTS_SH already installs the test, and
# a second raw copy would ship at SHAREMODE 0444 beside it for nothing. The
# vmx_basic.sh line above predates this and is left alone.

# Registered, not merely shipped. Shipping it through FILES alone gave a file
# with no generated atf-sh wrapper, no Kyuafile entry, no shebang (the source
# starts with "#-") and mode 0444 -- so its own documented `kyua test
# deployment_safety` could not work, and nothing would ever have run it. That
# is the shape of fault this whole change is about, so ending it half-fixed
# would be the wrong place to stop.
#
# Two of its cases rewrite /etc/sysctl.conf and /boot/loader.conf on the
# machine that runs them. Those are gated in the file with
# require.config vmm_nested_allow_boot_config_rewrite AND by a value check in each body, so
# they stay SKIPPED unless somebody asks for them:
#
#	kyua -v test_suites.FreeBSD.vmm_nested_allow_boot_config_rewrite=yes \
#	    test deployment_safety
#
# The variable is named for this test on purpose: a generic name would be a
# suite-wide switch other tests could share, so one line in kyua.conf would
# arm all of them at once. Neither case backs up what it rewrites, so the
# change is PERMANENT -- which is why it is opt-in and not merely exclusive.
#
# Both guards are needed. require.config only checks the variable is DEFINED,
# and it is enforced by kyua alone -- so the body check is what holds when the
# program is run by hand, which registering it makes possible for the first
# time. Its scripts_exist case -- which asserts the scripts ship AND are
# executable -- then runs everywhere, which is the case worth having.
ATF_TESTS_SH+=	deployment_safety
# Exclusive for a stronger reason than svm_basic: two of its cases rewrite
# boot configuration, and kyua parallelises per CASE, so without this they can
# race each other. Note the limit: it serialises cases within one kyua run,
# and nothing else on the machine.
TEST_METADATA.deployment_safety+=	is_exclusive="true"

# Without these the subdirectories are never built and never installed, so the
# harness has to be copied onto each host by hand -- and a host whose boot
# environment reverts silently takes an old harness with it, which then fails a
# perfectly good kernel. Ship the tests with the build they test.
# TESTS_SUBDIRS, not SUBDIR, for any directory that REGISTERS TESTS.
#
# The two are not interchangeable and the difference is invisible until you
# count what ran. bsd.test.mk adds every TESTS_SUBDIRS entry to SUBDIR, so the
# build and install behaviour is identical -- but only TESTS_SUBDIRS entries
# get an `include("<dir>/Kyuafile")' line in the generated Kyuafile. A test
# directory listed under plain SUBDIR is therefore built, installed, and
# registered in its OWN Kyuafile, and then never reached, because nothing
# includes it.
#
# Measured on an installed package before this change: 32 test programs were
# declared across the tree's Kyuafiles and `kyua test` at the top level ran 8
# cases from 5 programs. The other 27 programs -- 14 in hw/exit_plumbing
# (lapic, ioapic, pit, rtc, uart, msi, pci_cfg ...) and 10 in hw/stress (ahci,
# nvme, xhci, e1000, hda, dma nested paging ...) -- never executed. The run
# reported "5/8 passed" and looked like a green suite.
#
# Only directories that declare tests belong here. The rest install shell
# drivers as FILES and are run by hand; putting them in TESTS_SUBDIRS would
# generate an include for a Kyuafile that declares nothing.
#
# AND CHECK THE PACKAGE BEFORE ADDING ONE. The parent directory
# (tests/sys/vmm/Makefile) deliberately keeps `nested' under plain SUBDIR for
# exactly this reason: its Kyuafile ships in the `tests' package while
# everything here ships in `nested-tests', and kyua ABORTS on an include
# naming a Kyuafile that is not present -- so that one line would break the
# whole base test suite on any host that installed tests without nested-tests.
#
# The includes generated here are safe because abisnap, fuzz, hw and hw's own
# two test subdirectories all set PACKAGE=nested-tests, the same package as
# this Kyuafile. They are installed together or not at all, so the include can
# never dangle. Anything added to this list must be checked the same way.
TESTS_SUBDIRS+=	abisnap
TESTS_SUBDIRS+=	fuzz
TESTS_SUBDIRS+=	hw

SUBDIR+=	demo
SUBDIR+=	features
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
