PROG=	bhyveload
SRCS=	bhyveload.c
MAN=	bhyveload.8
PACKAGE=	bhyve

LIBADD=	vmmapi

CFLAGS+=-I${SRCTOP}/stand/userboot
# In-tree vmmapi.h, which may be ahead of the installed one.
CFLAGS+=-I${SRCTOP}/lib/libvmmapi

.include <bsd.prog.mk>
