#!/bin/sh
# =============================================================================
#  run-stepthrough.sh -- boot Layer 1 of the CloudBSD nested "matryoshka" demo
# =============================================================================
#  Boots the Layer-1 guest on THIS host with its console on your
#  terminal (stdio).  After it boots you get an auto-login root shell and a
#  WELCOME TO LAYER 1 banner.  From there, follow the on-screen prompts:
#  read  ./go-deeper.sh  then run  sh ./go-deeper.sh  to descend into Layer 2,
#  and again for Layer 3, Layer 4.  Each layer is a real, full FreeBSD system
#  you can open a shell in and inspect.  'poweroff' climbs back up one level.
#
#  *** EXPERIMENTAL nested-virt code -- run only on a dedicated test host. ***
#
#  Knobs (env):
#    CORES=N      vCPUs to request per layer (default 1).  Subject to the SMP
#                 safety cap below (Intel clamps to 1; AMD caps at 2) unless
#                 ALLOW_SMP=1.  Worst case of ignoring this is a HUNG HOST.
#    ALLOW_SMP=1  lift the safety cap (loud warning; may hang the host).
#    MEM=..       Layer-1 RAM.  run-stepthrough sets this to half the host's
#                 memory, capped at 12G; each deeper layer auto-gets ~half.
# =============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
IMG=${IMG:-${HERE}/images/layer1.raw}
BHYVELOAD=/usr/sbin/bhyveload
BHYVE=/usr/sbin/bhyve
BHYVECTL=/usr/sbin/bhyvectl

MEM=${MEM:-12G}
CORES=${CORES:-1}
ALLOW_SMP=${ALLOW_SMP:-0}
VM="${VM:-stepthrough-l1-$$}"

[ "$(id -u)" -eq 0 ] || { echo "must run as root: doas sh $0" >&2; exit 1; }
[ -f "${IMG}" ] || { echo "missing Layer-1 image: ${IMG}" >&2; exit 1; }

# bhyve opens the disk read-write, so booting the master image writes into it
# and every later run inherits whatever the last person did -- which quietly
# destroys the one property this demo promises, that each run starts clean.
# run-stepthrough always passes a private copy; refuse the master outright so
# that running this script directly cannot contaminate it either.
MASTER=/usr/local/share/cloudbsd-demo/stepthrough/images/layer1.raw
if [ "${IMG}" = "${MASTER}" ] || [ "${IMG}" = "${HERE}/images/layer1.raw" ]; then
	echo "refusing to boot the master image directly: ${IMG}" >&2
	echo "the guest would write into it.  Copy it first, or use:" >&2
	echo "    doas /usr/local/libexec/cloudbsd-demo/run-stepthrough" >&2
	exit 1
fi

# Nested must be present + on.
sysctl hw.vmm.nested >/dev/null 2>&1 || { echo "not a nested kernel (no hw.vmm.nested)" >&2; exit 1; }
kldload vmm 2>/dev/null || true
sysctl hw.vmm.nested.enable=1 >/dev/null 2>&1 || true

# ---- SMP SAFETY GATE (identical policy to go-deeper.sh) ---------------------
# # remove/relax once nested multi-vCPU (smp-multicore branch) is fixed and
# # re-validated on BOTH Intel(VMX) and AMD(SVM).
_svm=$(sysctl -n hw.vmm.nested.svm 2>/dev/null || echo 0)
_vmx=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null || echo 0)
pick_cores() {
	want=$1; [ "$want" -ge 1 ] 2>/dev/null || want=1
	if [ "${_vmx}" != "0" ]; then
		if [ "$want" -gt 1 ] && [ "${ALLOW_SMP}" = "1" ]; then
			echo "Layer 1: ${want} vCPU on Intel -- *** EXPERIMENTAL, MAY HANG THE HOST *** (ALLOW_SMP=1)" >&2; echo "$want"; return; fi
		[ "$want" -gt 1 ] && echo "Layer 1: using 1 vCPU -- Intel nested SMP guard active (AP bring-up deadlock; set ALLOW_SMP=1 to override)" >&2 || echo "Layer 1: using 1 vCPU (Intel)" >&2
		echo 1; return
	elif [ "${_svm}" != "0" ]; then
		cap=2
		if [ "$want" -le "$cap" ]; then echo "Layer 1: using ${want} vCPU (AMD SVM, within safe cap ${cap})" >&2; echo "$want"; return; fi
		if [ "${ALLOW_SMP}" = "1" ]; then echo "Layer 1: ${want} vCPU on AMD -- *** ABOVE SAFE CAP ${cap}, MAY HANG THE HOST *** (ALLOW_SMP=1)" >&2; echo "$want"; return; fi
		echo "Layer 1: clamping ${want} -> ${cap} vCPU -- AMD nested SMP safe cap (ALLOW_SMP=1 to exceed)" >&2; echo "$cap"; return
	else
		echo "Layer 1: using 1 vCPU (no nested SMP support detected)" >&2; echo 1; return
	fi
}
NCPU=$(pick_cores "${CORES}")

cleanup() { ${BHYVECTL} --vm="${VM}" --destroy >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

echo ""
echo "=============================================================="
echo "  CloudBSD nested-virt STEP-THROUGH  (matryoshka demo)"
echo "  Booting Layer 1 on this host.  vCPUs=${NCPU} RAM=${MEM}"
echo "  When it boots: follow the WELCOME TO LAYER N prompts;"
echo "  read ./go-deeper.sh, then 'sh ./go-deeper.sh' to descend."
echo "=============================================================="
echo ""

${BHYVECTL} --vm="${VM}" --destroy >/dev/null 2>&1 || true
${BHYVELOAD} -c stdio -m "${MEM}" -d "${IMG}" \
	-e cloudbsd.layer=1 -e console=comconsole -e autoboot_delay=1 "${VM}" || {
		echo "bhyveload failed" >&2; exit 1; }
${BHYVE} -c "${NCPU}" -m "${MEM}" -A -H -P \
	-s 0,hostbridge -s 3,virtio-blk,"${IMG}" \
	-s 31,lpc -l com1,stdio "${VM}"
RC=$?
${BHYVECTL} --vm="${VM}" --destroy >/dev/null 2>&1 || true
echo ""
echo "Layer 1 powered off (exit ${RC}).  Bye."
exit 0
