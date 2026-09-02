PACKAGE=lib${LIB}
LIB=	vmmapi
SHLIB_MAJOR=	7
SRCS=	vmmapi.c
INCS=	vmmapi.h

CFLAGS+= -I${.CURDIR}
# Pick up in-tree VMMCTL_CREATE_NESTED from sys/dev/vmm/vmm_dev.h
CFLAGS+= -I${SRCTOP}/sys

.PATH:	${.CURDIR}/${MACHINE_CPUARCH}

.include "${MACHINE_CPUARCH}/Makefile.inc"

LIBADD=	util

.include <bsd.lib.mk>
