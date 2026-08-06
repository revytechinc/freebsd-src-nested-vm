#!/bin/sh
#
# SPDX-License-Identifier: BSD-2-Clause
#
# vmm.preflight - probe host CPU + bhyve nested-virt capability matrix.
#
# Cross-generation decisions follow AMD APM Vol 2 §15.6 and Intel SDM Vol 3C
# §25-26 (VMCS shadowing, unrestricted guest, APICv, posted interrupts).
#
# Usage:   tools/preflight.sh [-v]
# Exit:    0 - at least one usable bhyve stack found
#          1 - host has no usable bhyve stack
#          2 - unable to read kernel state on this host

print_row() { printf "  %-32s %s\n" "$1" "$2"; }

DMESG=/var/run/dmesg.boot
VERBOSE=0
case "$1" in -v) VERBOSE=1 ;; esac

# Hex -> decimal converter that tolerates "$0xHEX" or "$HEX".
h2d() {
    case "$1" in 0x*) v=${1#0x};; *) v=$1;; esac
    printf "%d" "0x$v" 2>/dev/null
}



echo "================================================================"
echo "                    vmm.preflight  v0.4"
echo "================================================================"
print_row "host:"        "$(uname -a 2>/dev/null)"
print_row "model:"       "$(sysctl -n hw.model 2>/dev/null)"
print_row "ncpu:"        "$(sysctl -n hw.ncpu 2>/dev/null)"
print_row "vm_guest:"    "$(sysctl -n kern.vm_guest 2>/dev/null)"
echo

# -- CPU detection from dmesg.boot (readable without root) --------------
if [ ! -r "$DMESG" ] || ! grep -q '^CPU:' "$DMESG" 2>/dev/null; then
    echo "dmesg.boot not readable; cannot derive CPUID details."
    echo "(Mount /var or load vmm.ko for richer telemetry.)"
    echo "================================================================"
    exit 2
fi

origin_line=$(grep -m1 'Origin=' "$DMESG")
ft1_line=$(grep -m1 '  Features=' "$DMESG")
ft2_line=$(grep -m1 '  Features2=' "$DMESG")
aft_line=$(grep -m1 '  AMD Features=' "$DMESG")
aft2_line=$(grep -m1 '  AMD Features2=' "$DMESG")
ext_line=$(grep -m1 'Structured Extended Features=' "$DMESG")
ext2_line=$(grep -m1 'Structured Extended Features2=' "$DMESG")
vtx_line=$(grep -m1 '^VT-x:' "$DMESG")
svm_line=$(grep -m1 '^[[:space:]]*SVM:' "$DMESG")

feat1=$(echo "$ft1_line" | sed -n 's|.*Features=0x\([0-9a-f]*\).*|\1|p')
feat2=$(echo "$ft2_line" | sed -n 's|.*Features2=0x\([0-9a-f]*\).*|\1|p')
amdfeat=$(echo "$aft_line" | sed -n 's|.*AMD Features=0x\([0-9a-f]*\).*|\1|p')
amdfn2=$(echo "$aft2_line" | sed -n 's|.*AMD Features2=0x\([0-9a-f]*\).*|\1|p')
extfeat=$(echo "$ext_line" | sed -n 's|.*Structured Extended Features=0x\([0-9a-f]*\).*|\1|p')
vendor=$(echo "$origin_line" | sed -n 's|.*Origin="\([^"]*\)".*|\1|p')
fam_str=$(echo "$origin_line" | sed -n 's|.*Family=\(0x[0-9a-f]*\).*|\1|p')
mod_str=$(echo "$origin_line" | sed -n 's|.*Model=\(0x[0-9a-f]*\).*|\1|p')

fam=$(h2d "$fam_str"); [ -z "$fam" ] && fam=0
mod=$(h2d "$mod_str"); [ -z "$mod" ] && mod=0

if [ "$VERBOSE" = "1" ]; then
    print_row "Origin raw:" "$origin_line"
    print_row "FT1 raw:"    "$ft1_line"
    print_row "FT2 raw:"    "$ft2_line"
    print_row "AMD FT raw:" "$aft_line"
    print_row "AMD FT2 raw:" "$aft2_line"
    print_row "Ext raw:"    "$ext_line"
    print_row "VT-x line:"  "$vtx_line"
    print_row "SVM line:"   "$svm_line"
fi
print_row "vendor:"     "$vendor"
print_row "Features L1 (EDX):"      "0x$feat1"
print_row "Features2 L1 (ECX):"     "0x$feat2"
print_row "L7 EBX ext feat:"        "0x$extfeat"
print_row "0x80000001 ECX (SVM?):"  "0x$amdfeat"
print_row "0x80000001 EDX:"         "0x$amdfn2"
echo

# -- Per-vendor decoding ----------------------------------------------
case "$vendor" in
    GenuineIntel)
        vmx=$(( 0x$feat2 >> 5  & 1 ))
        smx=$(( 0x$feat2 >> 6  & 1 ))
        xtpr=$(( 0x$feat2 >> 14 & 1 ))
        avx=$(( 0x$feat2 >> 28 & 1 ))
        smep=$(( 0x$extfeat >> 6 & 1 ))
        # FreeBSD dmesg Family= is already the *effective* family
        # (Intel SDM Vol 2 §3.2: DisplayFamily = basefam + extfam<<4),
        # not the raw CPUID-encoded value, so fam is used as-is.
        extfam=$fam
        mod8=$(( mod & 0xff ))
        modhi=$(( mod >> 4 & 0xf ))
        modlo=$(( mod & 0xf ))
        key="$(printf '%x.%x' "$extfam" "$mod")"
        print_row "VMX (ECX[5]):"       "$([ $vmx -eq 1 ] && echo PRESENT || echo absent)"
        print_row "SMX/TXT (ECX[6]):"   "$([ $smx -eq 1 ] && echo PRESENT || echo absent)"
        print_row "xTPR upd (ECX[14]):" "$([ $xtpr -eq 1 ] && echo PRESENT || echo absent)"
        print_row "AVX (ECX[28]):"      "$([ $avx -eq 1 ] && echo PRESENT || echo absent)"
        print_row "SMEP (7:EBX[6]):"    "$([ $smep -eq 1 ] && echo PRESENT || echo absent)"
        case "$key" in
            6.3a) uarch="Ivy Bridge (3rd gen)" ;;
            6.3c|6.45|6.46) uarch="Haswell family (4th gen)" ;;
            6.4f|6.56)      uarch="Broadwell (5th gen)" ;;
            6.5e|6.55)      uarch="Skylake (6th gen)" ;;
            6.8e|6.9e)      uarch="Kaby Lake (7th gen)" ;;
            6.9c|6.a5|6.a6) uarch="Comet / Ice Lake (10th gen)" ;;
            6.a7)           uarch="Rocket Lake (11th gen)" ;;
            6.97|6.9a)      uarch="Alder Lake (12th gen)" ;;
            6.b7|6.ba)      uarch="Raptor Lake (13th gen)" ;;
            6.cf|6.ad|6.6a) uarch="Sapphire Rapids server" ;;
            *) uarch="Intel key=$key" ;;
        esac
        print_row "microarch:" "$uarch"

        # nVMX viability per Intel SDM Vol 3C.
        if [ "$extfam" = "6" ] && [ "$modhi" = "3" ] && [ "$modlo" = "10" ]; then
            print_row "nVMX verdict:" "BLOCKED - Ivy Bridge; no VMCS-shadowing / unrest-guest."
        elif [ "$extfam" = "6" ] && [ $modhi -ge 4 ]; then
            print_row "nVMX verdict:" "VIABLE - Broadwell+ (or 0x4x/0x5x family has VMCS-shadowing)."
        elif [ "$extfam" = "6" ] && [ "$modhi" = "3" ] && [ $modlo -ge 12 ]; then
            print_row "nVMX verdict:" "VIABLE - Haswell (model 0x3c+)."
        else
            print_row "nVMX verdict:" "INVESTIGATE - unknown family/model; load vmm.ko and read hw.vmm.vmx.cap.*"
        fi
        ;;

    AuthenticAMD|AMDisbetter|HygonGenuine)
        # IMPORTANT: SVM is in CPUID 0x80000001 EDX bit 2, not ECX.
        svm_bit=$(( 0x$amdfn2 >> 2 & 1 ))
        npt_bit=$(( 0x$amdfn2 >> 1 & 1 ))
        # FreeBSD dmesg Family= is the effective family (see Intel SDM
        # Vol 2 §3.2 for the analogous Intel encoding); AMD APM Vol 2 §3.3
        # reports the same effective value, so fam is used as-is.
        ff=$fam
        family_hex=$(printf "%x" $ff)
        mod8=$(( mod & 0xff ))
        modhi=$(( mod >> 4 & 0xf ))
        modlo=$(( mod & 0xf ))

        # Leaf 0x8000000A bits are reported by FreeBSD in `^SVM:` line.
        if [ -n "$svm_line" ]; then
            has_np=0
            has_nrip=0
            has_vclean=0
            has_aflush=0
            has_dassist=0
            has_avic=0
            echo "$svm_line" | grep -q 'NP' && has_np=1
            echo "$svm_line" | grep -q 'NRIP' && has_nrip=1
            echo "$svm_line" | grep -q 'VClean' && has_vclean=1
            echo "$svm_line" | grep -q 'AFlush' && has_aflush=1
            echo "$svm_line" | grep -q 'DAssist' && has_dassist=1
            echo "$svm_line" | grep -q 'AVIC' && has_avic=1
            nasid=$(echo "$svm_line" | sed -n 's|.*NAsids=\([0-9]*\).*|\1|p')
            [ -z "$nasid" ] && nasid=0
        fi
        print_row "SVM (0x80000001:EDX[2]):" "$([ $svm_bit -eq 1 ] && echo PRESENT || echo absent)"
        print_row "NPT (0x80000001:EDX[1]):" "$([ $npt_bit -eq 1 ] && echo PRESENT || echo absent)"
        print_row "AMD family dec:" "$family_hex"
        case "$family_hex" in
            f|10|11|12|14|15|16|17|19|1a)
                case "$family_hex" in
                    f|0f)   uarch="K8/K10 (Family 0xF)";;
                    10|11)  uarch="K10 (Family 10h/11h)";;
                    12)     uarch="Llano (Family 12h)";;
                    14)     uarch="Bobcat (Family 14h)";;
                    15)     uarch="Bulldozer/Piledriver (15h)";;
                    16)     uarch="Jaguar / Puma (16h)";;
                    17)     uarch="Zen1+ (17h)";;
                    19|1a)  uarch="Zen4/Zen5 (${family_hex}h)";;
                    *)      uarch="AMD family=0x$family_hex";;
                esac
                if [ "$family_hex" = "f" ] || [ "$family_hex" = "0f" ]; then
                    uarch="K8 / Opteron (Family 0xF)"
                fi
                print_row "microarch:" "$uarch"

                if [ -n "$svm_line" ]; then
                    print_row "  L0x8000000A NP:"    "$([ $has_np -eq 1 ]    && echo PRESENT || echo absent)"
                    print_row "  L0x8000000A NRIP:"  "$([ $has_nrip -eq 1 ]  && echo PRESENT || echo absent)"
                    print_row "  L0x8000000A VClean:" "$([ $has_vclean -eq 1 ] && echo PRESENT || echo absent)"
                    print_row "  L0x8000000A AFlush:" "$([ $has_aflush -eq 1 ] && echo PRESENT || echo absent)"
                    print_row "  L0x8000000A DAssist:" "$([ $has_dassist -eq 1 ] && echo PRESENT || echo absent)"
                    print_row "  L0x8000000A AVIC:"   "$([ $has_avic -eq 1 ] && echo PRESENT || echo absent)"
                    print_row "  NAsids:" "$nasid"
                fi
                case "$family_hex" in
                    f|10|11) print_row "nSVM verdict:" "VIABLE - K8/K10 (pre-AVIC era); SVM+NPT only.";;
                    12|14)   print_row "nSVM verdict:" "VIABLE - Llano / Bobcat; SVM present, AVIC absent.";;
                    15)      print_row "nSVM verdict:" "VIABLE - Bulldozer/Piledriver; AVIC absent.";;
                    16)      print_row "nSVM verdict:" "VIABLE - Jaguar; SVM present, AVIC absent.";;
                    17)      print_row "nSVM verdict:" "FULLY VIABLE - Zen1+; AVIC/vgif/NRIP/VClean/DAssist.";;
                    19|1a)   print_row "nSVM verdict:" "FULLY VIABLE - Zen4+; AVIC+vGIF 2-bit ASIDs.";;
                esac
                ;;
            *)
                print_row "microarch:" "AMD family=0x$family_hex (unrecognised)"
                ;;
        esac
        ;;

    *)
        print_row "vendor:" "$vendor (non-x86; abort)"
        echo "================================================================"
        exit 2
        ;;
esac
echo

# -- Live hw.vmm.* sysctls (only if vmm.ko loaded) -------------------
echo "--- Live hw.vmm.* (only if vmm.ko loaded) ---"
vmm_loaded=$(kldstat 2>/dev/null | grep -c '\bvmm\b')
if [ "$vmm_loaded" = "0" ]; then
    echo "  vmm.ko is NOT loaded. Plain bhyve guests CANNOT run yet."
    echo "  root action:  kldload vmm   then re-run preflight."
else
    for n in hw.vmm.vmx.initialized hw.vmm.vmx.cap.halt_exit hw.vmm.vmx.cap.pause_exit \
             hw.vmm.vmx.cap.wbinvd_exit hw.vmm.vmx.cap.rdpid hw.vmm.vmx.cap.rdtscp \
             hw.vmm.vmx.cap.unrestricted_guest hw.vmm.vmx.cap.monitor_trap \
             hw.vmm.vmx.cap.invpcid hw.vmm.vmx.cap.tpr_shadowing \
             hw.vmm.vmx.cap.virtual_interrupt_delivery hw.vmm.vmx.cap.posted_interrupts \
             hw.vmm.vmx.cap.virtual_nmi \
             hw.vmm.svm.initialized hw.vmm.svm.cap.halt_exit hw.vmm.svm.cap.nrips \
             hw.vmm.svm.cap.flush_by_asid hw.vmm.svm.cap.vgif \
             hw.vmm.svm.cap.avic hw.vmm.svm.cap.assist \
             hw.vmm.svm.cap.pause_threshold hw.vmm.svm.cap.pause_filter \
             hw.vmm.nested.enable hw.vmm.nested.svm hw.vmm.nested.vmx; do
        v=$(sysctl -n "$n" 2>/dev/null)
        if [ -n "$v" ]; then
            print_row "$n:" "$v"
        fi
    done
fi
print_row "vmm.ko loaded?" "$([ "$vmm_loaded" = "0" ] && echo no || echo yes)"
print_row "/dev/vmm:" "$(ls -la /dev/vmm 2>/dev/null | awk '{print $1, $3, $4, $5}')"
echo

# -- L0-hypervisor warning --------------------------------------------
vm_guest=$(sysctl -n kern.vm_guest 2>/dev/null)
if [ "$vm_guest" != "none" ] && [ -n "$vm_guest" ]; then
    echo "--- L0-hypervisor present ---"
    echo "  kern.vm_guest=$vm_guest"
    case "$vm_guest" in
        vmware)
            echo "  VMware is already L0. bhyve + nested-virt may run but inner"
            echo "  SVM/VMRUN exits can be intercepted by VMware and fail."
            ;;
        xen)
            echo "  Xen is L0. bhyve is not viable as a nested guest."
            ;;
        hv)
            echo "  Hyper-V is L0. Same caveat."
            ;;
        bhyve)
            echo "  Already inside another bhyve instance. Nested bhyve works"
            echo "  if the outer instance enables nested-virt (hw.vmm.nested.enable=1)."
            ;;
        *)
            echo "  Unknown L0 hypervisor. Treat nested-bhyve as unsupported."
            ;;
    esac
    echo
fi

# -- Final verdict ----------------------------------------------------
echo "--- Verdict ---"
verdict_ok=0
case "$vendor" in
    GenuineIntel)
        if [ "$vmx" = "1" ]; then verdict_ok=1; fi
        if [ "$extfam" = "6" ] && [ "$modhi" = "3" ] && [ "$modlo" = "10" ]; then
            echo "  Plain bhyve guests:    OK (VMX + EPT)"
            echo "  nVMX (nested) guests:  BLOCKED (Ivy Bridge lacks VMCS-shadowing)"
            verdict_ok=1
        elif [ "$extfam" = "6" ] && [ "$modhi" -ge 4 ]; then
            echo "  Plain bhyve guests:    OK (VMX + EPT)"
            echo "  nVMX (nested) guests:  VIABLE (Broadwell+, after kernel gate is in place)"
            verdict_ok=1
        fi
        ;;
    AuthenticAMD|AMDisbetter|HygonGenuine)
        if [ "$svm_bit" = "1" ]; then verdict_ok=1; fi
        echo "  Plain bhyve guests:    $([ $svm_bit -eq 1 ] && [ -n "$svm_line" ] && echo OK || echo INVESTIGATE)"
        echo "  nSVM (nested) guests:  $([ -z "$svm_line" ] && echo INVESTIGATE - SVM leaf missing || echo VIABLE - inner SVM supported; L0 hypervisor must allow it)"
        ;;
esac
[ "$verdict_ok" = "0" ] && echo "  Plain bhyve guests:  NOT VIABLE - silicon vendor/model not in support matrix."
if [ "$vm_guest" != "none" ] && [ -n "$vm_guest" ]; then
    echo "  WARNING: L0 hypervisor present ($vm_guest). Treat the verdict above as optimistic; the inner guest will collide with the L0 hypervisor unless nested-virt is explicitly enabled across the whole stack."
fi
echo
echo "================================================================"
exit 0
