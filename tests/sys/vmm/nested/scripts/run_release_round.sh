#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# run_release_round.sh -- test a release artifact on every host, to completion.
#
# A round is the unit of work.  It does NOT stop at the first failure: a round
# is expected to surface several unrelated faults -- a disk problem on one
# machine, a networking problem on another -- and they will not all appear on
# the same host.  Stopping early throws away everything the rest of the round
# would have told us, and each restart costs a full matrix.
#
# So: every host is tested, every finding is collected, and the summary at the
# end lists all of them together.  Fix them as a batch, then run the round
# again -- a change to shared code voids every earlier pass, so a partial
# re-test is not a re-test.
#
# Hosts run in PARALLEL. The fleet is large and mostly idle; serialising a
# round across it wastes hours for no benefit.
#
# Usage:
#   run_release_round.sh <artifact> <host> [host ...]
#
# Exit 0 only if every host reached a passing verdict.

set -u

PROGRAM="${0##*/}"
ART=${1:?usage: $PROGRAM <artifact> <host> [host ...]}
shift
[ $# -gt 0 ] || { echo "$PROGRAM: name at least one host" >&2; exit 2; }

ROUND=${ROUND:-$(date -u +%Y%m%dT%H%M%SZ)}
WORK=${WORK:-/tmp/round-$ROUND}
REMOTE_HELPER=${REMOTE_HELPER:-$(dirname "$0")/boot_artifact.sh}
SSH="ssh -4 -o ConnectTimeout=60 -o BatchMode=yes"

mkdir -p "$WORK"
[ -f "$ART" ] || { echo "$PROGRAM: no such artifact: $ART" >&2; exit 2; }
SHA=$(sha256 -q "$ART" 2>/dev/null || sha256sum "$ART" | cut -d' ' -f1)

echo "round:    $ROUND"
echo "artifact: $(basename "$ART")"
echo "sha256:   $SHA"
echo "hosts:    $*"
echo

# One host, start to finish.  Writes its own result file and never exits
# non-zero in a way that would stop the round.
test_one() {
	_h=$1
	_r="$WORK/$_h.result"
	{
		if ! $SSH "$_h" true 2>/dev/null; then
			echo "verdict: UNREACHABLE"
			exit 0
		fi
		# Stage the artifact only if the host does not already have this
		# exact one; a 1.5GB copy per host per round is the slowest part
		# of a round and is usually unnecessary.
		_have=$($SSH "$_h" "sha256 -q /tmp/$(basename "$ART") 2>/dev/null" 2>/dev/null || true)
		if [ "$_have" != "$SHA" ]; then
			echo "staging: copying artifact"
			cat "$ART" | $SSH "$_h" "cat > /tmp/$(basename "$ART")" 2>/dev/null
		else
			echo "staging: already present"
		fi
		# Everything on the remote side is named for THIS round. Two
		# rounds overlapping on one host would otherwise share a VM
		# name, a result file and a blanket pkill: the second would
		# kill the first's guest and both would read whichever verdict
		# happened to be left behind.
		_tag=r$(echo "$ROUND" | tr -cd '0-9' | tail -c 10)
		$SSH "$_h" "cat > /tmp/boot_artifact.$_tag.sh" < "$REMOTE_HELPER" 2>/dev/null
		$SSH "$_h" "doas sh -c 'chmod +x /tmp/boot_artifact.$_tag.sh;
			bhyvectl --vm=$_tag --destroy >/dev/null 2>&1;
			nohup /tmp/boot_artifact.$_tag.sh /tmp/$(basename "$ART") $_tag \
			    >/tmp/$_tag.log 2>&1 </dev/null &'" 2>/dev/null
		# Poll for the verdict rather than holding the connection open:
		# an ssh session that times out takes the guest with it.
		_n=0
		while [ "$_n" -lt 40 ]; do
			if $SSH "$_h" "doas grep -q DONE /tmp/$_tag.result 2>/dev/null" 2>/dev/null; then
				break
			fi
			sleep 15
			_n=$((_n + 1))
		done
		$SSH "$_h" "doas cat /tmp/$_tag.result 2>/dev/null" 2>/dev/null
		$SSH "$_h" "doas sh -c 'sysctl -n hw.model'" 2>/dev/null | sed 's/^/cpu: /'
	} > "$_r" 2>&1
}

for h in "$@"; do
	test_one "$h" &
done
wait

# ---- summary: every host, pass and fail together --------------------------
echo "================ round $ROUND ================"
printf "%-24s %-12s %-34s %s\n" HOST VERDICT CPU CONSOLE
fails=0; total=0
for h in "$@"; do
	_r="$WORK/$h.result"
	v=$(sed -n 's/^verdict: //p' "$_r" 2>/dev/null | head -1)
	c=$(sed -n 's/^console: *//p' "$_r" 2>/dev/null | head -1)
	m=$(sed -n 's/^cpu: //p' "$_r" 2>/dev/null | head -1 | cut -c1-34)
	total=$((total + 1))
	case "${v:-NO-RESULT}" in
	BOOTED) ;;
	*) fails=$((fails + 1)) ;;
	esac
	printf "%-24s %-12s %-34s %s\n" "$h" "${v:-NO-RESULT}" "${m:-unknown}" "${c:-}"
done
echo
echo "$((total - fails))/$total passed; results in $WORK"

if [ "$fails" -gt 0 ]; then
	echo
	echo "FINDINGS -- all of them, so they can be fixed as one batch:"
	for h in "$@"; do
		v=$(sed -n 's/^verdict: //p' "$WORK/$h.result" 2>/dev/null | head -1)
		[ "$v" = "BOOTED" ] && continue
		echo "  --- $h: ${v:-NO-RESULT}"
		sed -n 's/^/      /p' "$WORK/$h.result" 2>/dev/null | tail -6
	done
	exit 1
fi
exit 0
