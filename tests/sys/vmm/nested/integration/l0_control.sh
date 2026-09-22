#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# l0_control.sh: the CONTROL for l2_smoke.sh's stress mode.
#
# It boots the same guest, the same way, the same number of times as
# L2_CYCLES -- but directly on L0, with no L1 in between. Everything else is
# held constant: bhyveload -h /, the same bhyve arguments, an nmdm console
# read the same way, the same banner string and the same sixty-second poll.
#
# It exists because the nested loop produced frozen guests -- RIP and vm-exit
# count identical three seconds apart -- and a black-box harness cannot say
# whether that belongs to the nested path, to bhyve, to the guest kernel or to
# the way the harness drives them. Holding all but the nesting constant is the
# cheapest way to separate them, and it does not need a kernel change.
#
# Measured on freedev010 (Ryzen 3 3200G, deepnest16): 25/25 here, against
# roughly a fifth to a third of nested launches freezing in the same period.
# A clean run of 25 is about 0.0008 likely if the per-launch freeze rate were
# the nested one, so the difference is not noise.
#
# A failure HERE is the more interesting result: it would mean the freeze is
# not nested-specific after all, and the nested finding would have to be
# withdrawn.
#
# Usage: doas env N=25 sh l0_control.sh
# Same bhyveload -h / + bhyve shape, same banner check, same timings.
set -u
N=${N:-25}
i=0; ok=0
while [ "$i" -lt "$N" ]; do
	bhyvectl --vm=l0ctl --destroy >/dev/null 2>&1
	: > /tmp/l0c
	( cat /dev/nmdm_l0ctl${i}B > /tmp/l0c 2>/dev/null & echo $! > /tmp/l0catpid )
	sleep 1
	if bhyveload -m 512M -h / -e console=comconsole -e autoboot_delay=0 l0ctl >/dev/null 2>&1; then
		bhyve -c 1 -m 512M -A -H -P -s 0,hostbridge -s 31,lpc \
		    -l com1,/dev/nmdm_l0ctl${i}A l0ctl >/tmp/l0err.$i 2>&1 &
		p=$!
		n=0
		while [ "$n" -lt 60 ]; do
			grep -q 'Copyright (c) 199' /tmp/l0c && break
			sleep 1; n=$((n+1))
		done
		if grep -q 'Copyright (c) 199' /tmp/l0c; then
			ok=$((ok+1))
		else
			echo "L0MISS:$i exits=$(bhyvectl --vm=l0ctl --get-stats 2>/dev/null | grep -i 'total number of vm exits' | awk '{print $NF}')"
			bhyvectl --vm=l0ctl --cpu=0 --get-rip 2>&1 | head -1
		fi
		kill -9 $p >/dev/null 2>&1
	fi
	kill -9 "$(cat /tmp/l0catpid 2>/dev/null)" >/dev/null 2>&1
	i=$((i+1))
done
bhyvectl --vm=l0ctl --destroy >/dev/null 2>&1
echo "L0CONTROL RESULT=$ok/$i"
