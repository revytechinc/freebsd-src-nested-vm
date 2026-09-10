#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Ship the measurement store with the tests, for the same reason the harness
# itself ships: a tool that is copied onto machines by hand drifts out of step
# with what it is measuring, and afterwards nobody can tell which copy produced
# a figure.
#
# This directory was the only one under tests/sys/vmm/nested without a Makefile,
# so it was the only one that never shipped. The store, its schema and the
# collector existed in the tree and were installed on no machine -- which means
# every measurement published so far was gathered by hand.

PACKAGE=	tests
TESTSDIR=	${TESTSBASE}/sys/vmm/nested/stats
BINDIR=		${TESTSDIR}

${PACKAGE}FILES+=	README.md
${PACKAGE}FILES+=	collect-inventory.sh
${PACKAGE}FILES+=	fleet.conf.sample.json
${PACKAGE}FILES+=	schema.sql
${PACKAGE}FILES+=	check_stats_package.sh

# Mode per file rather than for the group. This directory is mostly data -- a
# schema, a sample configuration, a README -- and only two members are
# programs. Marking the whole group executable would be the same mistake the
# scripts directory made, in the other direction.
${PACKAGE}FILESMODE=				0444
${PACKAGE}FILESMODE_collect-inventory.sh=	0555
${PACKAGE}FILESMODE_check_stats_package.sh=	0555

# The Python package as a GROUP rather than a SUBDIR. It has to land in a
# directory of its own name, because it is imported as one --
# `python3 -m nested_stats.cli' will not find these files flattened into the
# parent. A SUBDIR with its own Makefile does not work here: bsd.test.mk does
# not descend for `install', so the parent installs and the subdirectory
# silently does not -- measured, and the result is a store with no code in it.
FILESGROUPS+=		nstats
nstats+=		nested_stats/__init__.py
nstats+=		nested_stats/cli.py
nstats+=		nested_stats/export.py
nstats+=		nested_stats/ingest.py
nstats+=		nested_stats/inventory.py
nstats+=		nested_stats/mcp.py
nstats+=		nested_stats/store.py
nstatsDIR=		${TESTSDIR}/nested_stats
nstatsPACKAGE=		${PACKAGE}
# Imported, never executed directly.
nstatsMODE=		0444

.include <bsd.test.mk>
