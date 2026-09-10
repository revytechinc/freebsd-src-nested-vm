# Chain to the tree-wide settings; bsd.init.mk only looks one level up.
#
# .PARSEDIR, not .CURDIR. .CURDIR is the directory make was invoked in, so from
# a subdirectory ${.CURDIR}/../Makefile.inc names THIS file and the include
# recurses forever. .PARSEDIR is the directory of the file being parsed.
.include "${.PARSEDIR}/../Makefile.inc"
