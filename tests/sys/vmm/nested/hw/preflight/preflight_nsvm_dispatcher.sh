#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Source-level check: nSVM VMRUN/VMLOAD/VMSAVE/CLGI/STGI are wired
# from svm.c into svm_nested_* and lookup is not a NULL stub.

# shellcheck shell=sh
set -u

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../../../../../.." && pwd)
SVM_C="${repo_root}/sys/amd64/vmm/amd/svm.c"
EXIT_C="${repo_root}/sys/amd64/vmm/amd/svm_nested_exit.c"
STUBS_C="${repo_root}/sys/amd64/vmm/amd/svm_nested_stubs.c"

if [ ! -r "${SVM_C}" ] || [ ! -r "${EXIT_C}" ] || [ ! -r "${STUBS_C}" ]; then
	echo "SKIP: nSVM sources not present under ${repo_root}"
	exit 0
fi

fail() {
	echo "FAIL: $1"
	exit 1
}

# VMRUN/VMLOAD/VMSAVE touch L1 memory and are completed from vm_run()
# (VM_EXITCODE_NESTED); CLGI/STGI are emulated in the exit handler.
grep -q 'VM_NESTED_OP_VMRUN' "${SVM_C}" || fail "svm.c does not defer VMRUN to vm_run()"
grep -q 'VM_NESTED_OP_VMLOAD' "${SVM_C}" || fail "svm.c does not defer VMLOAD to vm_run()"
grep -q 'VM_NESTED_OP_VMSAVE' "${SVM_C}" || fail "svm.c does not defer VMSAVE to vm_run()"
grep -q 'svm_nested_clgi(vcpu)' "${SVM_C}" || fail "svm.c does not call svm_nested_clgi"
grep -q 'svm_nested_stgi(vcpu)' "${SVM_C}" || fail "svm.c does not call svm_nested_stgi"
grep -q '\.nested[[:space:]]*=[[:space:]]*svm_nested_op' "${SVM_C}" || fail "svm.c does not install svm_nested_op"
grep -q 'svm_nested_vmrun(vcpu' "${STUBS_C}" || fail "svm_nested_op does not call svm_nested_vmrun"
grep -q 'svm_nested_release_l1_maps' "${SVM_C}" || fail "svm.c does not release L1 maps on vcpu cleanup"
grep -q 'vm_gpa_hold' "${SVM_C}" && fail "svm.c holds guest pages inside the exit handler"
if grep -q 'ns = NULL; /\* stub: svm_nested_lookup' "${EXIT_C}"; then
	fail "svm_nested_lookup still stubbed in svm_nested_exit.c"
fi
grep -q 'return (&vcpu->nested)' "${EXIT_C}" || fail "svm_nested_lookup does not return per-vcpu nested state"
if grep -q 'return (1);' "${STUBS_C}" && ! grep -q 'VMCB_INTCPT_VMRUN' "${STUBS_C}"; then
	fail "svm_nested_stubs.c still looks like empty return(1) stubs"
fi
grep -q 'VMCB_INTCPT_VMRUN' "${STUBS_C}" || fail "svm_nested_vmrun does not validate VMRUN intercept"

echo "PASS: preflight_nsvm_dispatcher VMRUN path wired"
exit 0
