/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 FreeBSD Foundation
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

/*
 * Wave 0 / Task 0d — nested-virt register-virtualization plan.
 *
 * Thin wrapper that exercises libvmmapi's VMMAPI_OPEN_CREATE_NESTED flag.
 * The caller cleans up via `bhyvectl --vm=<name> --destroy`.
 */

#include <err.h>
#include <errno.h>
#include <getopt.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <vmmapi.h>

static void
usage(const char *progname)
{
	fprintf(stderr,
	    "Usage: %s [-v] <vmname>\n"
	    "  -v   verbose: dump vmctx pointer\n",
	    progname);
}

int
main(int argc, char **argv)
{
	const char *vmname;
	struct vmctx *ctx;
	int ch, flags;
	bool verbose;

	verbose = false;
	while ((ch = getopt(argc, argv, "v")) != -1) {
		switch (ch) {
		case 'v':
			verbose = true;
			break;
		default:
			usage(argv[0]);
			return (1);
		}
	}

	if (optind >= argc) {
		usage(argv[0]);
		return (1);
	}
	vmname = argv[optind];

	flags = VMMAPI_OPEN_CREATE | VMMAPI_OPEN_CREATE_NESTED;
	if (verbose)
		fprintf(stderr,
		    "bhyve_nested: vm_openf(\"%s\", CREATE|NESTED)\n",
		    vmname);

	ctx = vm_openf(vmname, flags);
	if (ctx == NULL) {
		if (errno == ENOENT) {
			warnx("vm_openf(%s): VM not created; "
			    "check hw.vmm.nested.enable and kernel "
			    "VMMCTL_CREATE_NESTED support", vmname);
		} else {
			err(1, "vm_openf(%s)", vmname);
		}
		return (1);
	}

	printf("bhyve_nested: opened '%s' with VMMAPI_OPEN_CREATE_NESTED\n",
	    vmname);
	if (verbose)
		printf("bhyve_nested: ctx=%p\n", (void *)ctx);

	/*
	 * Intentionally do not destroy the VM; the caller decides cleanup
	 * timing (matches vmm_cred_jail.sh pattern). vmctx itself is closed
	 * on exit; the underlying /dev/vmm/<name> stays around.
	 */
	return (0);
}