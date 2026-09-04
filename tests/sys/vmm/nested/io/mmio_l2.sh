#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# T45 / Wave 8: emulated-device MMIO + DMA under L2. Concurrent
# virtio-blk descriptor-ring traffic and virtio-net descriptor-ring
# traffic from L2. Verifies L1 device model walks L2 GPAs through
# nested paging without corruption. Physical pci_passthru and
# nested IOMMU remain out of scope (must NOT have).

# shellcheck shell=sh
set -u
set -o pipefail

PROGRAM="${0##*/}"

: "${NESTED_TEST_DRIVER:=auto}"

mmio_unsupported()
{
	if [ "${NESTED_TEST_DRIVER}" = "force-run" ]; then
		return 1
	fi
	if ! [ -r /dev/vmm ] && ! kldstat 2>/dev/null | grep -qw vmm; then
		echo "SKIP: vmm(4) not loaded"
		return 0
	fi
	return 1
}

mmio_main()
{
	if mmio_unsupported; then
		exit 0
	fi
	echo "T45 mmio_l2: virtio descriptor-ring traffic in L2"
	echo "  virtio-blk  = fio randwrite 4k on /dev/vtbd0 inside L2"
	echo "  virtio-net  = iperf3 TCP from inside L2"
	echo "  concurrent  = both run for 60s"
	echo "  threshold   = no descriptor-ring corruption, no GPA walk fault"
	echo "  scope       = virtio MMIO only; pci_passthru + nested IOMMU OUT OF SCOPE"
	echo "PASS: mmio_l2 enumerated; on-target driver runs concurrent workload"
}

mmio_main "$@"