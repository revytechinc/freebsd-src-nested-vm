.include <bsd.compat.pre.mk>
# For PKG_NAME_PREFIX: the installer selects base packages by name, so it must
# be built knowing the name the world build gave them.
.include <bsd.pkg.pre.mk>

SCRIPTS=auto \
	adduser \
	bootconfig \
	checksum \
	config \
	docsinstall \
	entropy \
	fetchmissingdists \
	finalconfig \
	firmware \
	hardening \
	hostname \
	jail \
	keymap \
	mirrorselect \
	mount \
	mount_aux \
	netconfig \
	netconfig_ipv4 \
	netconfig_ipv6 \
	pkgbase \
	rootpass \
	script \
	services \
	time \
	umount \
	wlanconfig \
	zfsboot

BINDIR= ${LIBEXECDIR}/bsdinstall

MAN=

pkgbase: pkgbase.in
	sed -e "s|%%_ALL_libcompats%%|${_ALL_libcompats}|" \
	    -e "s|%%PKG_NAME_PREFIX%%|${PKG_NAME_PREFIX}|" \
	    < ${.ALLSRC} > ${.TARGET}

.include <bsd.prog.mk>
