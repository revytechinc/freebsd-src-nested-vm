#!/bin/sh
#
# Run several nested stacks at once: N guests on this host, each booting its
# own guest inside itself.
#
# The other demos go DOWN -- one guest, inside one guest. This one goes ACROSS.
# It is a different question and it fails differently: depth exercises the
# translation and reflection paths, width exercises everything that is shared
# between vCPU threads on the host, which is where contention and lock ordering
# show up.
#
#     sh 5-many-nested-at-once.sh          four stacks
#     sh 5-many-nested-at-once.sh -n 8     eight
#     sh 5-many-nested-at-once.sh -n auto  as many as this host has room for
#
# Each stack wants about 4 GB of memory and 3 GB of disk for its private copy
# of the guest image, and they all finish in roughly the time one of them takes
# unless the host runs short. The script works out what this machine can hold
# and refuses to start more than that, because a host driven into swap is a
# measurement of swap, not of nested virtualization.
#
set -u

DEMO=/usr/local/libexec/cloudbsd-demo/run-auto-demo
IMAGE=/usr/local/share/cloudbsd-demo/auto/nested-demo.raw
WORKDIR=/usr/local/share/cloudbsd-demo/auto
# What one stack costs. MEM matches run-auto-demo; the disk is one copy of the
# guest image, which each run makes for itself.
MEM_PER_GB=4
DISK_PER_GB=3

N=4
while [ $# -gt 0 ]; do
	case "$1" in
	-n)	[ $# -ge 2 ] || { echo "-n needs a value" >&2; exit 1; }
		N=$2; shift ;;
	-h|--help) sed -n '2,22p' "$0"; exit 0 ;;
	*)	echo "usage: $0 [-n count|auto]" >&2; exit 1 ;;
	esac
	shift
done

if ! sysctl -n hw.vmm.nested.enable >/dev/null 2>&1; then
	echo "this kernel has no nested-virt support; nothing to run."
	echo "run 0-what-can-this-host-do.sh to see what this machine is."
	exit 1
fi
[ -x "$DEMO" ]  || { echo "missing $DEMO -- re-run the installer" >&2; exit 1; }
[ -f "$IMAGE" ] || { echo "missing $IMAGE -- re-run the installer" >&2; exit 1; }

# --- what this host can actually hold --------------------------------------
CORES=$(sysctl -n hw.ncpu)
RAMGB=$(( $(sysctl -n hw.physmem) / 1073741824 ))
FREEGB=$(df -k "$WORKDIR" | tail -1 | awk '{print int($4/1048576)}')
# Leave a quarter of memory to the host. A host that swaps stops measuring the
# thing we came to measure.
BY_RAM=$(( (RAMGB * 3 / 4) / MEM_PER_GB ))
BY_DISK=$(( FREEGB / DISK_PER_GB ))
BY_CPU=$CORES
FIT=$BY_RAM
[ "$BY_DISK" -lt "$FIT" ] && FIT=$BY_DISK
[ "$BY_CPU" -lt "$FIT" ] && FIT=$BY_CPU
[ "$FIT" -lt 1 ] && FIT=1

if [ "$N" = auto ]; then
	N=$FIT
fi
case "$N" in ''|*[!0-9]*) echo "-n takes a number or \"auto\"" >&2; exit 1 ;; esac
[ "$N" -ge 1 ] || { echo "-n must be at least 1" >&2; exit 1; }
if [ "$N" -gt "$FIT" ]; then
	echo "This host has room for about ${FIT} stacks (${RAMGB} GB RAM, ${FREEGB} GB free,"
	echo "${CORES} cores) and you asked for ${N}. Running ${N} anyway would put the host"
	echo "into swap, which measures the swap device rather than the hypervisor."
	echo "Re-run with  -n ${FIT}  or  -n auto."
	exit 1
fi

LOGDIR=$HOME/nested-demo/many-$$
mkdir -p "$LOGDIR"

echo "host   : $(hostname -s)  ${CORES} cores, ${RAMGB} GB RAM, ${FREEGB} GB free"
echo "running: ${N} stacks, each a guest booting a guest inside itself"
echo "logs   : ${LOGDIR}"
echo
echo "They start together, so the interesting number is not how long one takes"
echo "but whether all ${N} still finish."
echo

start=$(date +%s)
i=1
while [ "$i" -le "$N" ]; do
	doas "$DEMO" > "${LOGDIR}/stack-${i}.log" 2>&1 &
	echo "  started stack ${i} (pid $!)"
	i=$((i + 1))
done

wait
elapsed=$(( $(date +%s) - start ))

ok=0
i=1
echo
while [ "$i" -le "$N" ]; do
	if grep -q NESTED_DEMO_L2_OK "${LOGDIR}/stack-${i}.log" 2>/dev/null; then
		printf '  stack %-3d OK\n' "$i"
		ok=$((ok + 1))
	else
		printf '  stack %-3d DID NOT COMPLETE  (%s)\n' "$i" "${LOGDIR}/stack-${i}.log"
	fi
	i=$((i + 1))
done

echo
echo "------------------------------------------------------------------"
printf ' %s: %d of %d nested stacks completed, in %ds\n' "$(hostname -s)" "$ok" "$N" "$elapsed"
echo "------------------------------------------------------------------"
[ "$ok" -eq "$N" ] || echo "The logs above are the artifact; keep the ones that did not finish."

# Leave nothing running. Each run cleans up after itself, but a stack that was
# killed rather than finished can leave its VM behind, and the next run of
# anything would then fail for a reason that has nothing to do with it.
for vm in $(ls /dev/vmm 2>/dev/null | grep '^cloudbsd-demo-auto-\|^nesteddemo-l1-'); do
	bhyvectl --destroy --vm="$vm" >/dev/null 2>&1 || true
done

[ "$ok" -eq "$N" ]
