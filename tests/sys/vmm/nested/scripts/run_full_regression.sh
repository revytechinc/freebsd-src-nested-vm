#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
#
# Full nested-virt regression: sysctls, preflight matrix, optional
# vmx_nested_test.ko, bhyve -N presence.

set -eu

preflight_dir=$(cd "$(dirname "$0")/../hw/preflight" && pwd)
status=0

echo "=== host ==="
hostname
uname -v
sysctl hw.model hw.ncpu kern.vm_guest 2>/dev/null | cat

echo "=== vmm ==="
if ! kldstat -q -n vmm; then
	echo "vmm.ko not loaded; attempting kldload"
	sudo -n kldload vmm || sudo -n kldload /boot/kernel/vmm.ko || true
fi
kldstat | grep vmm || true

echo "=== sysctl ==="
sudo -n sysctl hw.vmm.nested_enable=1 2>/dev/null || true
sysctl hw.vmm.nested_enable hw.vmm.nested.vmx hw.vmm.nested.svm 2>&1 | tee /tmp/nv-sysctl.txt

echo "=== preflight.sh ==="
if [ -x /usr/local/bin/preflight ]; then
	sudo -n env PREFLIGHT_DMESG=/var/run/dmesg.boot /usr/local/bin/preflight | tee /tmp/nv-preflight.txt | tail -20
elif [ -x "${preflight_dir}/../../../../../tools/preflight.sh" ]; then
	sudo -n env PREFLIGHT_DMESG=/var/run/dmesg.boot \
	    "${preflight_dir}/../../../../../tools/preflight.sh" | tee /tmp/nv-preflight.txt | tail -20
else
	echo "SKIP preflight.sh binary"
fi

echo "=== 17-test matrix ==="
sudo -n env PREFLIGHT_DMESG=/var/run/dmesg.boot \
    bash "${preflight_dir}/run_preflight_tests.sh" | tee /tmp/nv-tests.txt
test_rc=${PIPESTATUS[0]}
if [ "$test_rc" -ne 0 ]; then
	status=1
fi

echo "=== vmx_nested_test.ko ==="
mod=""
for p in /boot/modules/vmx_nested_test.ko /boot/kernel/vmx_nested_test.ko \
    /tmp/vmx_nested_test.ko; do
	if [ -r "$p" ]; then
		mod=$p
		break
	fi
done
if [ -n "$mod" ]; then
	sudo -n kldunload vmx_nested_test 2>/dev/null || true
	if sudo -n kldload "$mod"; then
		dmesg | grep vmx_nested_test | tail -20
		sudo -n kldunload vmx_nested_test || true
	else
		echo "FAIL: kldload $mod"
		status=1
	fi
else
	echo "SKIP: vmx_nested_test.ko not installed"
fi

echo "=== bhyve -N ==="
bhyve_bin=""
for b in /usr/local/sbin/bhyve-nested /usr/sbin/bhyve bhyve; do
	if command -v "$b" >/dev/null 2>&1 || [ -x "$b" ]; then
		bhyve_bin=$b
		break
	fi
done
if [ -n "$bhyve_bin" ] && "$bhyve_bin" -h 2>&1 | grep -q -- '-N'; then
	echo "PASS: $bhyve_bin advertises -N"
else
	echo "FAIL: no bhyve with -N (tried bhyve-nested and /usr/sbin/bhyve)"
	status=1
fi

echo "=== SUMMARY exit=$status ==="
exit "$status"
