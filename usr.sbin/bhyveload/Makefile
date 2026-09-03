PROG=	bhyveload
SRCS=	bhyveload.c
MAN=	bhyveload.8
PACKAGE=	bhyve

LIBADD=	vmmapi

CFLAGS+=-I${SRCTOP}/stand/userboot
# In-tree vmmapi.h for VMMAPI_OPEN_CREATE_NESTED.
CFLAGS+=-I${SRCTOP}/lib/libvmmapi

.include <bsd.prog.mk>
