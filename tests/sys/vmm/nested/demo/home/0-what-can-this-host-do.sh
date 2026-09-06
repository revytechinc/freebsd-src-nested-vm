#!/bin/sh
# Report what this particular machine can and cannot do, before you try.
echo "host   : $(hostname -s)"
echo "arch   : $(uname -m)"
echo "cpu    : $(sysctl -n hw.model)"
echo "cores  : $(sysctl -n hw.ncpu)   ram: $(( $(sysctl -n hw.physmem) / 1073741824 )) GB"
echo "kernel : $(uname -r)  (osreldate $(sysctl -n kern.osreldate))"
if [ "$(uname -m)" != "amd64" ]; then
	echo
	echo "This kit is amd64: the guests it boots are amd64 disk images, and"
	echo "the path it boots them by is the amd64 one. Scripts 1 to 4 will not"
	echo "run here, whatever the checks below say."
	command -v bhyveload >/dev/null 2>&1 ||
		echo "(bhyveload, which the demos use to load a guest, is not here.)"
	echo
fi
if ! kldstat -q -m vmmdev 2>/dev/null && ! kldstat 2>/dev/null | grep -q vmm; then
	echo "vmm    : not loaded  ->  doas kldload vmm"
else
	echo "vmm    : loaded ($(kldstat | grep -o 'vmm[a-z0-9-]*\.ko' | head -1))"
fi
e=$(sysctl -n hw.vmm.nested.enable 2>/dev/null)
v=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null)
s=$(sysctl -n hw.vmm.nested.svm 2>/dev/null)
if [ -z "$e" ]; then
	echo "nested : NOT AVAILABLE - this kernel has no nested-virt support."
	echo "         The demos need the nested build installed on this host."
else
	echo "nested : enable=$e  vmx=${v:--}  svm=${s:--}   (nonzero = ready)"
	if [ "${v:-0}" -ne 0 ] || [ "${s:-0}" -ne 0 ]; then
		echo "         this host can run the demos"
	else
		echo "         hardware preflight did not pass here"
	fi
fi
auto=/usr/local/share/cloudbsd-demo/auto/nested-demo.raw
step=/usr/local/share/cloudbsd-demo/stepthrough/images/layer1.raw
[ -f "$auto" ] && echo "demo 1 : image present" \
	|| echo "demo 1 : image MISSING ($auto) - re-run the installer"
[ -f "$step" ] && echo "demo 2 : image present" \
	|| echo "demo 2 : image MISSING ($step) - re-run the installer"
echo
echo "Demos 1 and 3 differ only in width: 1 gives each guest a single vCPU,"
echo "3 gives each guest all $(sysctl -n hw.ncpu) of this host's cores."
