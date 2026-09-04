SUBDIR=	distextract distfetch include partedit runconsoles scripts
SUBDIR_PARALLEL=
SUBDIR_DEPEND_distextract = include
SUBDIR_DEPEND_distfetch = include
SUBDIR_DEPEND_partedit = include
SCRIPTS= bsdinstall
MAN= bsdinstall.8
PACKAGE=	bsdinstall

SCRIPTS+=	startbsdinstall
SCRIPTSDIR_startbsdinstall=	${LIBEXECDIR}/bsdinstall

UPDATE_DEPENDFILE= no

FILESDIR=	${SHAREDIR}/bsdinstall
FILES=		FreeBSD-base.conf

_BRANCH!=	${MAKE} -C ${SRCTOP}/release -V BRANCH
BRANCH?=	${_BRANCH:C/-p[0-9]+$//}
_REVISION!=	${MAKE} -C ${SRCTOP}/release -V REVISION
REVISION?=	${_REVISION}

.if ${BRANCH} == CURRENT || ${BRANCH} == STABLE
KEYSDIR=	pkg
SUBURL=		base_latest
.elif ${BRANCH} == RELEASE
KEYSDIR=	pkgbase-${REVISION:C/\.[0-9]+//}
SUBURL=		base_release_${REVISION:C/[0-9]+\.//}
.elif ${BRANCH:C/[0-9]+$//} == BETA || \
    ${BRANCH:C/[0-9]+$//} == RC
KEYSDIR=	pkgbase-${REVISION:C/\.[0-9]+//}
SUBURL= 	base_release_${REVISION:C/[0-9]+\.//}_${BRANCH:tl}
.else
.warning Invalid branch "${BRANCH}"
KEYSDIR=	pkg
SUBURL=		base_latest
.endif

# PKGBASE_REPO_CONF may be set to the path of a ready-made pkg repository
# configuration file, which is then installed as the network pkgbase
# repository used by bsdinstall(8) instead of the generated default.  This
# lets a downstream build point its installation media at its own pkgbase
# repository without modifying FreeBSD-base.conf.in.
.if defined(PKGBASE_REPO_CONF) && !empty(PKGBASE_REPO_CONF)
FreeBSD-base.conf: ${PKGBASE_REPO_CONF}
	cat ${.ALLSRC} > ${.TARGET}
.else
FreeBSD-base.conf: FreeBSD-base.conf.in
	sed "s|%%SUBURL%%|${SUBURL}|;s|%%KEYSDIR%%|${KEYSDIR}|" < ${.ALLSRC} > ${.TARGET}
.endif

.include <bsd.prog.mk>
