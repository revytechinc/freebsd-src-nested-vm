# Every directory in this tree ships in the nested-tests package rather than in
# tests. bsd.test.mk defaults PACKAGE to tests, and a directory that took that
# default would land in the wrong package silently -- while nested/Kyuafile,
# which is in nested-tests, would still include() it, so kyua would abort on the
# machines that installed nested-tests without tests.
#
# bsd.init.mk includes ../Makefile.inc, one level only, so a directory that
# gains subdirectories of its own needs a Makefile.inc chaining to this one.
PACKAGE=	nested-tests
