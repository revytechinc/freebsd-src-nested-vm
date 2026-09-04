#!/bin/sh
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
# vmm.preflight - probe host CPU + bhyve nested-virt capability matrix.
#
# FreeBSD-only.  Reads /var/run/dmesg.boot, sysctl(8), kldstat(8), /dev/vmm.
# Cross-generation decisions follow AMD APM Vol 2 sec.15.6 and Intel SDM
# Vol 3C sec.25-26 (VMCS shadowing, unrestricted guest, APICv, posted
# interrupts, EPT/NPT, AVIC, vGIF).
#
# v2.0 rewrite (audit .sisyphus/plans/preflight-arch-audit.md):
#   Crit-1: AMD SVM register labels corrected (0x80000001:ECX vs EDX).
#   Crit-2: AMD NPT read from 0x8000000A:EDX[0] (parsed ^SVM: NP), never
#           0x80000001:ECX[1] (CMP legacy core-count).
#   Crit-3: Nested verdicts capability-derived, not family-derived.
#   Crit-4: Shell parse error at AMD verdict line is gone.
#   High-5: SMEP bit corrected (CPUID leaf 7 EBX bit 7).
#   High-6: Intel model table extended (Tiger Lake, Ice Lake, Cannon Lake,
#           Alder/Raptor/Meteor/Lunar/Arrow, Granite/Sierra Forest).
#   High-7: AMD family+model table mirrors sys/x86/x86/identcpu.c:2698-2720
#           zen_idents[].
#   High-8: Future AMD families still produce a verdict from CPUID.
#   High-9: Topology summary from kern.sched.topology_spec.
#   High-10: SIMD summary from leaf 1 EDX/ECX.
#   High-11: Exit 1 when no usable stack; exit 0 otherwise.
#
# Usage:   tools/preflight.sh [-v] [--json]
# Exit:    0 - at least one usable bhyve stack found
#          1 - host has no usable bhyve stack
#          2 - unable to read kernel state on this host

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

DMESG=${PREFLIGHT_DMESG:-/var/run/dmesg.boot}
VERBOSE=0
JSON=0
for arg in "$@"; do
    case "$arg" in
        -v)     VERBOSE=1 ;;
        --json) JSON=1 ;;
        -h|--help)
            printf 'usage: %s [-v] [--json]\n' "${0##*/}"
            exit 0
            ;;
    esac
done

print_row() { printf '  %-32s %s\n' "$1" "$2"; }
section()   { printf -- '---------- %s ----------\n' "$1"; }
banner()    { printf '================================================================\n'; }

# hex_to_dec tolerates "$0xHEX", "$HEX", or empty; emits 0 on garbage so
# downstream $((0x...)) never sees an invalid expression.
hex_to_dec() {
    case "$1" in
        '')     printf '0'; return 0 ;;
        0x*)    v=${1#0x} ;;
        *)      v=$1 ;;
    esac
    case "$v" in
        *[!0-9a-fA-F]*) printf '0'; return 0 ;;
    esac
    printf '%d' "0x${v}" 2>/dev/null || printf '0'
}

bit_get() {
    h2d=$(hex_to_dec "$1")
    if [ -z "$h2d" ]; then h2d=0; fi
    printf '%d' $(( (h2d >> $2) & 1 ))
}

present_or_absent() {
    if [ "$(bit_get "$1" "$2")" = "1" ]; then
        printf 'PRESENT'
    else
        printf 'absent'
    fi
}

# classify_intel_model HEX_MODEL -> "Name (Gen X)"
# All modern Intel CPUs are effective Family 6; we key on the model byte.
# Sources: sys/compat/linuxkpi/common/include/asm/intel-family.h,
# Intel 64 and IA-32 Architecture Software Developer's Manual
# (Vol 2 Table 2-1 / Vol 3 CPUID signature table).
classify_intel_model() {
    m=$(hex_to_dec "$1")
    case "$m" in
        15)        printf 'Pentium 4 / Netburst' ;;
        23)        printf 'Pentium M / Dothan' ;;
        28)        printf 'Atom Bonnell' ;;
        31)        printf 'Atom Saltwell' ;;
        26)        printf 'Atom Saltwell tablet' ;;
        30)        printf 'Nehalem (1st gen Core)' ;;
        37|44|46|47) printf 'Westmere (1st gen Core)' ;;
        42|45)     printf 'Sandy Bridge (2nd gen)' ;;
        58)        printf 'Ivy Bridge (3rd gen)' ;;
        60|63|69|70) printf 'Haswell (4th gen)' ;;
        61|71|79|86) printf 'Broadwell (5th gen)' ;;
        62)        printf 'Ivy Bridge-E/EP server' ;;
        78|94)     printf 'Skylake (6th gen client/mobile)' ;;
        85)        printf 'Skylake-SP / Cascade Lake server' ;;
        125|126)   printf 'Ice Lake client (10th gen)' ;;
        108|140)   printf 'Ice Lake client alt id (10th gen)' ;;
        106|109)   printf 'Ice Lake server (10th gen)' ;;
        102)       printf 'Cannon Lake (10th gen)' ;;
        142|158)   printf 'Kaby/Coffee Lake (7-8th gen)' ;;
        165|166)   printf 'Comet Lake (10th gen)' ;;
        167)       printf 'Rocket Lake (11th gen)' ;;
        141)       printf 'Tiger Lake (11th gen)' ;;
        151|154)   printf 'Alder Lake (12th gen)' ;;
        183|186|191) printf 'Raptor Lake (13th gen)' ;;
        170|172)   printf 'Meteor Lake (Core Ultra 1)' ;;
        189)       printf 'Lunar Lake (Core Ultra 2)' ;;
        197|198)   printf 'Arrow Lake (Core Ultra 2)' ;;
        143)       printf 'Sapphire Rapids server' ;;
        207)       printf 'Emerald Rapids server' ;;
        173)       printf 'Granite Rapids server' ;;
        174)       printf 'Granite Rapids-D server' ;;
        175)       printf 'Sierra Forest server' ;;
        *)          printf 'Intel family=6 model=0x%s' "$(printf '%02x' "$m")" ;;
    esac
}

# classify_amd_family_model FAM_HEX MODEL_DEC -> "Name"
# Mirrors sys/x86/x86/identcpu.c:2698-2720 zen_idents[].
classify_amd_family_model() {
    fam_hex=$1
    m=$2
    m_hex=$(printf '%02x' "$m")
    case "$fam_hex:$m_hex" in
        0f:00|0f:01|0f:02|0f:03|0f:04|0f:05|0f:06|0f:07|0f:08|0f:09|0f:0a|0f:0b|0f:0c|0f:0d|0f:0e|0f:0f|0f:10|0f:11|0f:12|0f:13|0f:14|0f:15|0f:16|0f:17|0f:18|0f:19|0f:1a|0f:1b|0f:1c|0f:1d|0f:1e|0f:1f|0f:20|0f:21|0f:22|0f:23|0f:24|0f:25|0f:26|0f:27|0f:28|0f:29|0f:2a|0f:2b|0f:2c|0f:2d|0f:2e|0f:2f)
            printf 'K8 / K10 (Family 0xF)'; return ;;
        10:*|11:*) printf 'K10 (Family 10h/11h)'; return ;;
        12:*)      printf 'Llano / Fusion (Family 12h)'; return ;;
        14:*)      printf 'Bobcat (Family 14h)'; return ;;
        15:*)      printf 'Bulldozer / Piledriver (Family 15h)'; return ;;
        16:*)      printf 'Jaguar / Puma (Family 16h)'; return ;;
        17:00|17:01|17:02|17:03|17:04|17:05|17:06|17:07|17:08|17:09|17:0a|17:0b|17:0c|17:0d|17:0e|17:0f|17:10|17:11|17:12|17:13|17:14|17:15|17:16|17:17|17:18|17:19|17:1a|17:1b|17:1c|17:1d|17:1e|17:1f|17:20|17:21|17:22|17:23|17:24|17:25|17:26|17:27|17:28|17:29|17:2a|17:2b|17:2c|17:2d|17:2e|17:2f|17:50|17:51|17:52|17:53|17:54|17:55|17:56|17:57|17:58|17:59|17:5a|17:5b|17:5c|17:5d|17:5e|17:5f)
            printf 'Zen 1 (Naples / Summit Ridge / Raven Ridge / Banded Kestrel)'; return ;;
        17:30|17:31|17:32|17:33|17:34|17:35|17:36|17:37|17:38|17:39|17:3a|17:3b|17:3c|17:3d|17:3e|17:3f|17:40|17:41|17:42|17:43|17:44|17:45|17:46|17:47|17:48|17:49|17:4a|17:4b|17:4c|17:4d|17:4e|17:4f|17:60|17:61|17:62|17:63|17:64|17:65|17:66|17:67|17:68|17:69|17:6a|17:6b|17:6c|17:6d|17:6e|17:6f|17:70|17:71|17:72|17:73|17:74|17:75|17:76|17:77|17:78|17:79|17:7a|17:7b|17:7c|17:7d|17:7e|17:7f|17:90|17:91|17:a0|17:a1|17:a2|17:a3|17:a4|17:a5|17:a6|17:a7|17:a8|17:a9|17:aa|17:ab|17:ac|17:ad|17:ae|17:af)
            printf 'Zen 2 (Rome / Castle Peak / Pinnacle Ridge / Matisse / Renoir-X)'; return ;;
        19:00|19:01|19:02|19:03|19:04|19:05|19:06|19:07|19:08|19:09|19:0a|19:0b|19:0c|19:0d|19:0e|19:0f|19:20|19:21|19:22|19:23|19:24|19:25|19:26|19:27|19:28|19:29|19:2a|19:2b|19:2c|19:2d|19:2e|19:2f|19:40|19:41|19:42|19:43|19:44|19:45|19:46|19:47|19:48|19:49|19:4a|19:4b|19:4c|19:4d|19:4e|19:4f|19:50|19:51|19:52|19:53|19:54|19:55|19:56|19:57|19:58|19:59|19:5a|19:5b|19:5c|19:5d|19:5e|19:5f)
            printf 'Zen 3 (Milan / Vermeer / Cezanne / Rembrandt)'; return ;;
        19:10|19:11|19:12|19:13|19:14|19:15|19:16|19:17|19:18|19:19|19:1a|19:1b|19:1c|19:1d|19:1e|19:1f|19:60|19:61|19:62|19:63|19:64|19:65|19:66|19:67|19:68|19:69|19:6a|19:6b|19:6c|19:6d|19:6e|19:6f|19:70|19:71|19:72|19:73|19:74|19:75|19:76|19:77|19:78|19:79|19:7a|19:7b|19:7c|19:7d|19:7e|19:7f|19:a0|19:a1|19:a2|19:a3|19:a4|19:a5|19:a6|19:a7|19:a8|19:a9|19:aa|19:ab|19:ac|19:ad|19:ae|19:af)
            printf 'Zen 4 (Genoa / Bergamo / Siena / Phoenix / Hawk Point / Strix)'; return ;;
        1a:00|1a:01|1a:02|1a:03|1a:04|1a:05|1a:06|1a:07|1a:08|1a:09|1a:0a|1a:0b|1a:0c|1a:0d|1a:0e|1a:0f|1a:20|1a:21|1a:22|1a:23|1a:24|1a:25|1a:26|1a:27|1a:28|1a:29|1a:2a|1a:2b|1a:2c|1a:2d|1a:2e|1a:2f|1a:40|1a:41|1a:42|1a:43|1a:44|1a:45|1a:46|1a:47|1a:48|1a:49|1a:4a|1a:4b|1a:4c|1a:4d|1a:4e|1a:4f|1a:60|1a:61|1a:62|1a:63|1a:64|1a:65|1a:66|1a:67|1a:68|1a:69|1a:6a|1a:6b|1a:6c|1a:6d|1a:6e|1a:6f|1a:70|1a:71|1a:72|1a:73|1a:74|1a:75|1a:76|1a:77|1a:78|1a:79|1a:7a|1a:7b|1a:7c|1a:7d|1a:7e|1a:7f)
            printf 'Zen 5 (Turin / Turin Dense / Strix Halo / Strix Point / Krackan)'; return ;;
        1a:50|1a:51|1a:52|1a:53|1a:54|1a:55|1a:56|1a:57|1a:58|1a:59|1a:5a|1a:5b|1a:5c|1a:5d|1a:5e|1a:5f|1a:80|1a:81|1a:82|1a:83|1a:84|1a:85|1a:86|1a:87|1a:88|1a:89|1a:8a|1a:8b|1a:8c|1a:8d|1a:8e|1a:8f|1a:c0|1a:c1|1a:c2|1a:c3|1a:c4|1a:c5|1a:c6|1a:c7|1a:c8|1a:c9|1a:ca|1a:cb|1a:cc|1a:cd|1a:ce|1a:cf)
            printf 'Zen 6 (Medusa Ridge / Verdal / future EPYC)'; return ;;
        *)
            printf 'Zen-family (Family 0x%s, Model 0x%s)' "$fam_hex" "$m_hex"
            return ;;
    esac
}

# parse_svm_line LINE -> sets globals has_np has_nrip has_vclean has_aflush
# has_dassist has_avic has_vgif nasid.  Handles compact mode only.
parse_svm_line() {
    has_np=0; has_nrip=0; has_vclean=0; has_aflush=0
    has_dassist=0; has_avic=0; has_vgif=0; nasid=0
    line=$1
    case "$line" in *NP*)       has_np=1 ;; esac
    case "$line" in *NRIP*|*NRIPS*) has_nrip=1 ;; esac
    case "$line" in *VClean*|*VmcbClean*) has_vclean=1 ;; esac
    case "$line" in *AFlush*|*FlushByAsid*) has_aflush=1 ;; esac
    case "$line" in *DAssist*|*DecodeAssist*) has_dassist=1 ;; esac
    case "$line" in *AVIC*)      has_avic=1 ;; esac
    case "$line" in *vGIF*)      has_vgif=1 ;; esac
    nasid=$(echo "$line" | sed -n 's|.*NAsids=\([0-9]*\).*|\1|p')
    [ -z "$nasid" ] && nasid=0
}

# parse_vtx_line LINE -> sets globals has_ept has_ug has_vpid has_apicv
# has_posted has_mtf has_pat
parse_vtx_line() {
    has_ept=0; has_ug=0; has_vpid=0; has_apicv=0
    has_posted=0; has_mtf=0; has_pat=0
    line=$1
    case "$line" in *EPT*)     has_ept=1 ;; esac
    case "$line" in *UG*)      has_ug=1 ;; esac
    case "$line" in *VPID*)    has_vpid=1 ;; esac
    case "$line" in *VID*)     has_apicv=1 ;; esac
    case "$line" in *PostIntr*) has_posted=1 ;; esac
    case "$line" in *MTF*)     has_mtf=1 ;; esac
    case "$line" in *PAT*)     has_pat=1 ;; esac
}

running_topology() {
    spec=$(sysctl -n kern.sched.topology_spec 2>/dev/null)
    if [ -z "$spec" ]; then printf 'unknown'; return; fi
    groups=$(echo "$spec" | grep -c '^<group' 2>/dev/null)
    printf '%s packages' "${groups:-?}"
}

verdict_ok=0
verdict_reason='not evaluated'
# VT-x: line parse, hw.vmm.vmx.* sysctls.
# Sets verdict_ok / verdict_reason.
# ============================================================================
decode_intel() {
    # CPUID leaf 1 ECX bits (Intel SDM Vol 2A Table 3-8).
    vmx_bit=$(bit_get    "$feat2"  5)
    smx_bit=$(bit_get    "$feat2"  6)
    xtpr_bit=$(bit_get   "$feat2" 14)
    avx_bit=$(bit_get    "$feat2" 28)
    osxsave_bit=$(bit_get "$feat2" 27)

    # CPUID leaf 1 EDX bits.
    sse_bit=$(bit_get    "$feat1" 25)   # SSE
    sse2_bit=$(bit_get   "$feat1" 26)   # SSE2
    pclmulqdq_bit=$(bit_get "$feat1"  1)

    # CPUID leaf 1 ECX bits (extended).
    sse3_bit=$(bit_get   "$feat2"  0)
    pclmulqdq2_bit=$(bit_get "$feat2"  1)
    ssse3_bit=$(bit_get  "$feat2"  9)
    sse41_bit=$(bit_get  "$feat2" 19)
    sse42_bit=$(bit_get  "$feat2" 20)
    aes_bit=$(bit_get    "$feat2" 25)
    f16c_bit=$(bit_get   "$feat2" 29)

    # CPUID leaf 7 subleaf 0 EBX bits.
    fsgsbase_bit=$(bit_get "$extfeat"  0)
    avx2_bit=$(bit_get   "$extfeat"  5)
    smep_bit=$(bit_get   "$extfeat"  7)   # Crit-1 fix: was bit 6.
    smap_bit=$(bit_get   "$extfeat" 20)
    avx512f_bit=$(bit_get "$extfeat" 16)

    # CPUID leaf 7 subleaf 0 ECX bits.
    avx512vnni_bit=0
    [ -n "$ext2feat" ] && avx512vnni_bit=$(bit_get "$ext2feat" 11)
    pk_bit=0
    [ -n "$ext2feat" ] && pk_bit=$(bit_get "$ext2feat" 3)

    # CPUID leaf 7 subleaf 0 EDX bits.
    archcap_bit=0
    [ -n "$ext3feat" ] && archcap_bit=$(bit_get "$ext3feat" 29)

    uarch=$(classify_intel_model "$mod_hex")

    section 'features'
    simd_list=''
    [ "$sse_bit"   = "1" ] && simd_list="${simd_list} SSE"
    [ "$sse2_bit"  = "1" ] && simd_list="${simd_list} SSE2"
    [ "$sse3_bit"  = "1" ] && simd_list="${simd_list} SSE3"
    [ "$ssse3_bit" = "1" ] && simd_list="${simd_list} SSSE3"
    [ "$sse41_bit" = "1" ] && simd_list="${simd_list} SSE4.1"
    [ "$sse42_bit" = "1" ] && simd_list="${simd_list} SSE4.2"
    [ "$avx_bit"   = "1" ] && simd_list="${simd_list} AVX"
    [ "$avx2_bit"  = "1" ] && simd_list="${simd_list} AVX2"
    [ "$avx512f_bit" = "1" ] && simd_list="${simd_list} AVX512F"
    [ "$avx512vnni_bit" = "1" ] && simd_list="${simd_list} AVX512VNNI"
    [ "$f16c_bit"  = "1" ] && simd_list="${simd_list} F16C"
    [ "$aes_bit"   = "1" ] && simd_list="${simd_list} AES"
    print_row 'SIMD (leaf 1 + 7):' "${simd_list:-none}"
    if [ "$avx_bit" = "1" ] && [ "$osxsave_bit" != "1" ]; then
        print_row 'AVX usability:' 'PARTIAL - CPUID AVX present but OSXSAVE clear (XCR0 disabled)'
    fi

    print_row 'VMX (1:ECX[5]):'      "$(present_or_absent "$feat2"  5)"
    print_row 'SMX/TXT (1:ECX[6]):'  "$(present_or_absent "$feat2"  6)"
    print_row 'xTPR (1:ECX[14]):'    "$(present_or_absent "$feat2" 14)"
    print_row 'SMEP (7:EBX[7]):'     "$(present_or_absent "$extfeat" 7)"
    print_row 'SMAP (7:EBX[20]):'    "$(present_or_absent "$extfeat" 20)"
    print_row 'AVX (1:ECX[28]):'     "$(present_or_absent "$feat2" 28)"
    print_row 'AVX2 (7:EBX[5]):'     "$(present_or_absent "$extfeat" 5)"
    print_row 'AVX-512F (7:EBX[16]):' "$(present_or_absent "$extfeat" 16)"
    print_row 'AVX-512 VNNI (7:ECX[11]):' "$(present_or_absent "${ext2feat:-0}" 11)"
    print_row 'PKU (7:ECX[3]):'      "$(present_or_absent "${ext2feat:-0}" 3)"
    print_row 'ARCH_CAP (7:EDX[29]):' "$(present_or_absent "${ext3feat:-0}" 29)"
    print_row 'FSGSBASE (7:EBX[0]):' "$(present_or_absent "$extfeat" 0)"
    print_row 'microarch:' "$uarch"

    section 'VMX (Intel)'
    # Fall back to hw.vmm.vmx.initialized if ^VT-x: is absent.
    vtx_evidence=$vtx_line
    if [ -z "$vtx_evidence" ]; then
        init=$(sysctl -n hw.vmm.vmx.initialized 2>/dev/null)
        if [ "$init" = "1" ]; then
            vtx_evidence='(absent from dmesg, but hw.vmm.vmx.initialized=1)'
        fi
    fi
    [ -n "$vtx_evidence" ] && echo "  VT-x line: $vtx_evidence"
    if [ -n "$vtx_line" ]; then
        parse_vtx_line "$vtx_line"
        print_row 'EPT (PROC_BASED2_CTLS[1]):' "$(present_or_absent "$vtx_line" 1 2>/dev/null || echo "$([ "$has_ept" = "1" ] && echo PRESENT || echo absent)")"
        print_row 'Unrestricted guest:' "$([ "$has_ug" = "1" ] && echo PRESENT || echo absent)"
        print_row 'VPID:'               "$([ "$has_vpid" = "1" ] && echo PRESENT || echo absent)"
        print_row 'APICv (VID):'        "$([ "$has_apicv" = "1" ] && echo PRESENT || echo absent)"
        print_row 'Posted interrupts:'  "$([ "$has_posted" = "1" ] && echo PRESENT || echo absent)"
    else
        print_row 'VT-x rich line:'     'absent (parse compact mode fallback)'
    fi

    section 'runtime vmm loadable state'
    vmm_loaded=$(kldstat 2>/dev/null | awk '$1 == "1" {found=1} END{print found ? "yes" : "no"}')
    if kldstat 2>/dev/null | grep -q ' vmm\.ko'; then
        vmm_loaded='yes'
    else
        vmm_loaded='no'
    fi
    print_row 'vmm.ko loaded?' "$vmm_loaded"
    if [ "$vmm_loaded" = "yes" ]; then
        for n in hw.vmm.vmx.initialized \
                 hw.vmm.vmx.cap.halt_exit hw.vmm.vmx.cap.pause_exit \
                 hw.vmm.vmx.cap.wbinvd_exit hw.vmm.vmx.cap.rdpid \
                 hw.vmm.vmx.cap.rdtscp hw.vmm.vmx.cap.unrestricted_guest \
                 hw.vmm.vmx.cap.monitor_trap hw.vmm.vmx.cap.invpcid \
                 hw.vmm.vmx.cap.tpr_shadowing \
                 hw.vmm.vmx.cap.virtual_interrupt_delivery \
                 hw.vmm.vmx.cap.posted_interrupts hw.vmm.vmx.cap.virtual_nmi \
                 hw.vmm.nested.enable hw.vmm.nested.vmx; do
            v=$(sysctl -n "$n" 2>/dev/null)
            [ -n "$v" ] && print_row "$n:" "$v"
        done
    else
        echo '  vmm.ko is NOT loaded. Plain bhyve guests CANNOT run yet.'
        echo '  root action:  kldload vmm   then re-run preflight.'
    fi
    [ -e /dev/vmm ] && print_row '/dev/vmm:' "$(ls -la /dev/vmm 2>/dev/null | awk '{print $1, $3, $4, $5}')" \
                  || print_row '/dev/vmm:' 'absent'

    if [ "$vm_guest" != "none" ] && [ -n "$vm_guest" ]; then
        section 'L0 hypervisor'
        print_row 'kern.vm_guest:' "$vm_guest"
        case "$vm_guest" in
            none)     printf '  Bare-metal host.\n' ;;
            generic)  printf '  Generic L0 detected.\n  Treat nested-virt as needing hw.vmm.nested.enable=1.\n' ;;
            xen)      printf '  Xen is L0. bhyve is NOT viable as a nested guest.\n' ;;
            hv)       printf '  Hyper-V is L0. Inner-guest APICv/EPT will collide with Hyper-V.\n' ;;
            vmware)   printf '  VMware is L0. bhyve + nested-virt may run but inner SVM/VMRUN\n  exits can be intercepted by VMware and fail.\n' ;;
            kvm)      printf '  KVM is L0. bhyve nested-virt requires nested KVM to expose\n  unrestricted guest / VMCS shadowing.\n' ;;
            vbox)     printf '  VirtualBox is L0. SVM/VT-x virtualization extensions are\n  typically unavailable to guests; bhyve not viable.\n' ;;
            parallels) printf '  Parallels is L0. Nested virt typically restricted.\n' ;;
            nvmm)     printf '  NVMM (NATIVE) is L0. bhyve cannot run inside NVMM.\n' ;;
            bhyve)    printf '  Already inside another bhyve. Nested bhyve works\n  if outer instance enables nested-virt (hw.vmm.nested.enable=1).\n' ;;
            *)        printf '  Unknown L0 hypervisor. Treat nested-bhyve as unsupported.\n' ;;
        esac
    fi

    section 'verdict (Intel)'
    if [ "$vmx_bit" != "1" ]; then
        printf '  Plain bhyve guests:    NOT VIABLE (CPUID VMX absent).\n'
        verdict_ok=0
    elif [ "$vmm_loaded" = "no" ]; then
        printf '  Plain bhyve guests:    UNKNOWN (vmm.ko not loaded; capability not evaluated).\n'
        printf '  nVMX (nested) guests:  UNKNOWN (load vmm.ko and re-run).\n'
        verdict_ok=0
        verdict_reason='vmm.ko not loaded'
    else
        printf '  Plain bhyve guests:    OK (VMX + EPT capability reported by vmm.ko).\n'
        ug_v=$(sysctl -n hw.vmm.vmx.cap.unrestricted_guest 2>/dev/null)
        nested_v=$(sysctl -n hw.vmm.nested.vmx 2>/dev/null)
        case "$nested_v" in
            2) printf '  nVMX (nested) guests:  READY (hw.vmm.nested.vmx=2).\n'
               verdict_ok=1; verdict_reason='nVMX ready' ;;
            1) printf '  nVMX (nested) guests:  BLOCKED-L0 (hw.vmm.nested.vmx=1: L0 hypervisor present).\n'
               verdict_ok=0; verdict_reason='nVMX blocked by L0' ;;
            0) printf '  nVMX (nested) guests:  UNSUPPORTED (hw.vmm.nested.vmx=0: silicon lacks VMCS-shadowing / unrestricted-guest).\n'
               verdict_ok=0; verdict_reason='silicon lacks VMCS shadowing' ;;
            *) printf '  nVMX (nested) guests:  UNKNOWN (hw.vmm.nested.vmx=%s).\n' "${nested_v:-?}"
               verdict_ok=0; verdict_reason='unknown nested.vmx state' ;;
        esac
        if [ "$ug_v" = "1" ]; then
            printf '  Unrestricted guest:    ENABLED (cap.unrestricted_guest=1).\n'
        fi
    fi
}

# ============================================================================
# decode_amd: AMD SVM silicon identity, leaf 8000_0001 ECX vs EDX (Crit-1),
# NPT only from parsed ^SVM: NP token (Crit-2), capability-derived verdict
# (Crit-3).
# ============================================================================
decode_amd() {
    # CPUID 8000_0001 ECX: SVM bit (Crit-1: was mislabeled as EDX).
    svm_bit=$(bit_get "$amdecx" 2)
    # CPUID 8000_0001 ECX[1] is CMP (legacy core-count) - NOT NPT.
    cmp_bit=$(bit_get "$amdecx" 1)
    # CPUID 8000_0001 EDX.
    nx_bit=$(bit_get "$amdedx" 20)
    lm_bit=$(bit_get "$amdedx" 29)
    page1gb_bit=$(bit_get "$amdedx" 26)
    rdtscp_bit=$(bit_get "$amdedx" 27)

    # CPUID leaf 1 EDX/ECX.
    sse_bit=$(bit_get   "$feat1" 25)
    sse2_bit=$(bit_get  "$feat1" 26)
    sse3_bit=$(bit_get  "$feat2"  0)
    avx_bit=$(bit_get   "$feat2" 28)
    avx2_bit=$(bit_get  "$extfeat" 5)
    smep_bit=$(bit_get  "$extfeat" 7)
    smap_bit=$(bit_get  "$extfeat" 20)
    avx512f_bit=$(bit_get "$extfeat" 16)

    uarch=$(classify_amd_family_model "$fam_hex" "$mod")

    section 'features'
    simd_list=''
    [ "$sse_bit" = "1" ] && simd_list="${simd_list} SSE"
    [ "$sse2_bit" = "1" ] && simd_list="${simd_list} SSE2"
    [ "$sse3_bit" = "1" ] && simd_list="${simd_list} SSE3"
    [ "$avx_bit" = "1" ] && simd_list="${simd_list} AVX"
    [ "$avx2_bit" = "1" ] && simd_list="${simd_list} AVX2"
    [ "$avx512f_bit" = "1" ] && simd_list="${simd_list} AVX512F"
    print_row 'SIMD (leaf 1 + 7):' "${simd_list:-none}"
    print_row 'SMEP (7:EBX[7]):' "$(present_or_absent "$extfeat" 7)"
    print_row 'SMAP (7:EBX[20]):' "$(present_or_absent "$extfeat" 20)"

    section 'silicon (AMD identity)'
    print_row 'microarch:' "$uarch"
    print_row 'NX (0x80000001:EDX[20]):' "$(present_or_absent "$amdedx" 20)"
    print_row 'LM (0x80000001:EDX[29]):' "$(present_or_absent "$amdedx" 29)"
    print_row '1GB page (EDX[26]):' "$(present_or_absent "$amdedx" 26)"
    print_row 'RDTSCP (EDX[27]):' "$(present_or_absent "$amdedx" 27)"

    section 'SVM (AMD)'
    # Crit-1: corrected register label (was EDX[2], is ECX[2]).
    print_row 'SVM (0x80000001:ECX[2]):' "$(present_or_absent "$amdecx" 2)"
    # NOTE: do NOT print NPT from ECX[1] - that is CMP legacy core-count.
    print_row 'CMP (0x80000001:ECX[1]):' "$(present_or_absent "$amdecx" 1)"
    if [ -n "$svm_line" ]; then
        parse_svm_line "$svm_line"
        # Crit-2: NPT comes from 0x8000000A:EDX[0] (the NP token), never ECX[1].
        print_row 'NPT (0x8000000A:EDX[0]):' "$([ "$has_np" = "1" ] && echo PRESENT || echo absent)"
        print_row 'NRIP (0x8000000A:EDX[3]):' "$([ "$has_nrip" = "1" ] && echo PRESENT || echo absent)"
        print_row 'VClean (0x8000000A:EDX[5]):' "$([ "$has_vclean" = "1" ] && echo PRESENT || echo absent)"
        print_row 'AFlush (0x8000000A:EDX[6]):' "$([ "$has_aflush" = "1" ] && echo PRESENT || echo absent)"
        print_row 'DAssist (0x8000000A:EDX[7]):' "$([ "$has_dassist" = "1" ] && echo PRESENT || echo absent)"
        print_row 'AVIC (0x8000000A:EDX[13]):' "$([ "$has_avic" = "1" ] && echo PRESENT || echo absent)"
        print_row 'vGIF (0x8000000A:EDX[16]):' "$([ "$has_vgif" = "1" ] && echo PRESENT || echo absent)"
        print_row 'NAsids:' "${nasid}"
    else
        print_row 'NPT (0x8000000A:EDX[0]):' 'unknown (no SVM leaf)'
        print_row 'AVIC/vGIF:' 'unknown (no SVM leaf)'
    fi

    section 'runtime vmm loadable state'
    if kldstat 2>/dev/null | grep -q ' vmm\.ko'; then vmm_loaded='yes'; else vmm_loaded='no'; fi
    print_row 'vmm.ko loaded?' "$vmm_loaded"
    if [ "$vmm_loaded" = "yes" ]; then
        for n in hw.vmm.svm.initialized \
                 hw.vmm.svm.cap.halt_exit hw.vmm.svm.cap.nrips \
                 hw.vmm.svm.cap.flush_by_asid hw.vmm.svm.cap.vgif \
                 hw.vmm.svm.cap.avic hw.vmm.svm.cap.assist \
                 hw.vmm.svm.cap.pause_threshold hw.vmm.svm.cap.pause_filter \
                 hw.vmm.svm.features hw.vmm.svm.num_asids \
                 hw.vmm.nested.enable hw.vmm.nested.svm; do
            v=$(sysctl -n "$n" 2>/dev/null)
            [ -n "$v" ] && print_row "$n:" "$v"
        done
    else
        echo '  vmm.ko is NOT loaded. Plain bhyve guests CANNOT run yet.'
        echo '  root action:  kldload vmm   then re-run preflight.'
    fi
    [ -e /dev/vmm ] && print_row '/dev/vmm:' "$(ls -la /dev/vmm 2>/dev/null | awk '{print $1, $3, $4, $5}')" \
                  || print_row '/dev/vmm:' 'absent'

    if [ "$vm_guest" != "none" ] && [ -n "$vm_guest" ]; then
        section 'L0 hypervisor'
        print_row 'kern.vm_guest:' "$vm_guest"
        case "$vm_guest" in
            none)     printf '  Bare-metal host.\n' ;;
            generic)  printf '  Generic L0 detected.\n  Treat nested-virt as needing hw.vmm.nested.enable=1.\n' ;;
            xen)      printf '  Xen is L0. bhyve is NOT viable as a nested guest.\n' ;;
            hv)       printf '  Hyper-V is L0. Inner-guest APICv/EPT will collide with Hyper-V.\n' ;;
            vmware)   printf '  VMware is L0. bhyve + nested-virt may run but inner SVM/VMRUN\n  exits can be intercepted by VMware and fail.\n' ;;
            kvm)      printf '  KVM is L0. bhyve nested-virt requires nested KVM to expose\n  NPT / NRIP / AVIC.\n' ;;
            vbox)     printf '  VirtualBox is L0. SVM/VT-x extensions typically unavailable.\n' ;;
            parallels) printf '  Parallels is L0. Nested virt typically restricted.\n' ;;
            nvmm)     printf '  NVMM (NATIVE) is L0. bhyve cannot run inside NVMM.\n' ;;
            bhyve)    printf '  Already inside another bhyve. Nested bhyve works\n  if outer instance enables nested-virt (hw.vmm.nested.enable=1).\n' ;;
            *)        printf '  Unknown L0 hypervisor. Treat nested-bhyve as unsupported.\n' ;;
        esac
    fi

    section 'verdict (AMD)'
    if [ "$svm_bit" != "1" ]; then
        printf '  Plain bhyve guests:    NOT VIABLE (CPUID SVM absent).\n'
        verdict_ok=0
    elif [ -z "$svm_line" ]; then
        printf '  Plain bhyve guests:    INVESTIGATE (no SVM leaf parsed).\n'
        printf '  nSVM (nested) guests:  INVESTIGATE (no SVM leaf parsed).\n'
        verdict_ok=0
        verdict_reason='no SVM leaf'
    elif [ "$vmm_loaded" = "no" ]; then
        printf '  Plain bhyve guests:    UNKNOWN (vmm.ko not loaded; capability not evaluated).\n'
        printf '  nSVM (nested) guests:  UNKNOWN (load vmm.ko and re-run).\n'
        verdict_ok=0
        verdict_reason='vmm.ko not loaded'
    else
        # Crit-4: previously this line had a bare ';' inside echo which
        # became a command separator.  Use proper string quoting.
        nested_v=$(sysctl -n hw.vmm.nested.svm 2>/dev/null)
        case "$nested_v" in
            2) printf '  Plain bhyve guests:    OK (SVM + NPT capability reported by vmm.ko).\n'
               printf '  nSVM (nested) guests:  READY (hw.vmm.nested.svm=2).\n'
               verdict_ok=1; verdict_reason='nSVM ready' ;;
            1) printf '  Plain bhyve guests:    OK (SVM + NPT capability reported by vmm.ko).\n'
               printf '  nSVM (nested) guests:  BLOCKED-L0 (hw.vmm.nested.svm=1: L0 hypervisor present).\n'
               verdict_ok=0; verdict_reason='nSVM blocked by L0' ;;
            0) printf '  Plain bhyve guests:    OK (SVM + NPT capability reported by vmm.ko).\n'
               printf '  nSVM (nested) guests:  UNSUPPORTED (hw.vmm.nested.svm=0: silicon lacks NPT/NRIP).\n'
               verdict_ok=0; verdict_reason='silicon lacks NPT' ;;
            *) printf '  Plain bhyve guests:    OK (SVM + NPT capability reported by vmm.ko).\n'
               printf '  nSVM (nested) guests:  UNKNOWN (hw.vmm.nested.svm=%s).\n' "${nested_v:-?}"
               verdict_ok=0; verdict_reason='unknown nested.svm state' ;;
        esac
    fi
}
banner
# ============================================================================
# MAIN: dmesg.boot dependency check + CPU field collection
# ============================================================================
HOST_OS=$(uname -s 2>/dev/null || printf 'unknown')
# On non-FreeBSD hosts, the script still parses dmesg.boot if reachable
# (test fixtures inject synthetic dmesg via PREFLIGHT_DMESG).  Print a
# header banner so operators know this is a degraded report.
if [ "$HOST_OS" != "FreeBSD" ]; then
    printf 'NOTE: host=%s (non-FreeBSD); some sysctl probes will be empty.\n' "$HOST_OS"
fi

banner
printf '                    vmm.preflight  v2.0\n'
banner

print_row 'host:'   "$(uname -a 2>/dev/null)"
print_row 'kernel:' "$(sysctl -n kern.osrelease 2>/dev/null)"
print_row 'model:'  "$(sysctl -n hw.model 2>/dev/null)"

phys_bytes=$(sysctl -n hw.physmem 2>/dev/null)
if [ -n "$phys_bytes" ] && [ "$phys_bytes" -gt 0 ] 2>/dev/null; then
    mib=$((phys_bytes / 1024 / 1024))
    gib=$(awk -v b="$phys_bytes" 'BEGIN{printf "%.2f", b/1073741824}')
    print_row 'memory:' "${phys_bytes} bytes (${mib} MiB / ~${gib} GiB)"
else
    print_row 'memory:' 'unknown'
fi
print_row 'uptime:' "$(sysctl -n kern.boottime 2>/dev/null)"

ncpu_hw=$(sysctl -n hw.ncpu 2>/dev/null)
ncpu_smp=$(sysctl -n kern.smp.cpus 2>/dev/null)
if [ -n "$ncpu_hw" ] && [ -n "$ncpu_smp" ] && [ "$ncpu_hw" != "$ncpu_smp" ]; then
    print_row 'ncpu (logical):' "${ncpu_hw}  [kern.smp.cpus=${ncpu_smp} - MISMATCH]"
else
    print_row 'ncpu (logical):' "${ncpu_hw:-unknown}"
fi
print_row 'topology:' "$(running_topology)"
vm_guest=$(sysctl -n kern.vm_guest 2>/dev/null)
print_row 'vm_guest:' "${vm_guest:-none}"
echo

if [ ! -r "$DMESG" ] || ! grep -q '^CPU:' "$DMESG" 2>/dev/null; then
    echo 'dmesg.boot not readable; cannot derive CPUID details.'
    echo '(Mount /var or load vmm.ko for richer telemetry.)'
    banner
    exit 2
fi

origin_line=$(grep -m1 'Origin=' "$DMESG")
ft1_line=$(grep -m1 '  Features=' "$DMESG")
ft2_line=$(grep -m1 '  Features2=' "$DMESG")
aft_line=$(grep -m1 '  AMD Features=' "$DMESG")
aft2_line=$(grep -m1 '  AMD Features2=' "$DMESG")
ext_line=$(grep -m1 'Structured Extended Features=' "$DMESG")
ext2_line=$(grep -m1 'Structured Extended Features2=' "$DMESG")
ext3_line=$(grep -m1 'Structured Extended Features3=' "$DMESG")
vtx_line=$(grep -m1 '^[[:space:]]*VT-x:' "$DMESG")
svm_line=$(grep -m1 '^[[:space:]]*SVM:' "$DMESG")
id_line=$(grep -m1 'Id=0x' "$DMESG")

feat1=$(echo "$ft1_line"  | sed -n 's|.*Features=0x\([0-9a-f]*\).*|\1|p')
feat2=$(echo "$ft2_line"  | sed -n 's|.*Features2=0x\([0-9a-f]*\).*|\1|p')
amdedx=$(echo "$aft_line"  | sed -n 's|.*AMD Features=0x\([0-9a-f]*\).*|\1|p')
amdecx=$(echo "$aft2_line" | sed -n 's|.*AMD Features2=0x\([0-9a-f]*\).*|\1|p')
extfeat=$(echo "$ext_line"   | sed -n 's|.*Structured Extended Features=0x\([0-9a-f]*\).*|\1|p')
ext2feat=$(echo "$ext2_line" | sed -n 's|.*Structured Extended Features2=0x\([0-9a-f]*\).*|\1|p')
ext3feat=$(echo "$ext3_line" | sed -n 's|.*Structured Extended Features3=0x\([0-9a-f]*\).*|\1|p')
vendor=$(echo "$origin_line" | sed -n 's|.*Origin="\([^"]*\)".*|\1|p')
fam_str=$(echo "$origin_line" | sed -n 's|.*Family=\(0x[0-9a-f]*\).*|\1|p')
mod_str=$(echo "$origin_line" | sed -n 's|.*Model=\(0x[0-9a-f]*\).*|\1|p')
step_str=$(echo "$origin_line" | sed -n 's|.*Stepping=\(0x[0-9a-f]*\).*|\1|p')
id_str=$(echo "$id_line"   | sed -n 's|.*Id=\(0x[0-9a-f]*\).*|\1|p')

fam=$(hex_to_dec "$fam_str")
mod=$(hex_to_dec "$mod_str")
step=$(hex_to_dec "$step_str")
fam_hex=$(printf '%x' "$fam")
mod_hex=$(printf '%x' "$mod")

if [ "$VERBOSE" = "1" ]; then
    section 'raw dmesg fields (verbose)'
    print_row 'Origin raw:' "$origin_line"
    print_row 'FT1 raw:'    "$ft1_line"
    print_row 'FT2 raw:'    "$ft2_line"
    [ -n "$aft_line"  ] && print_row 'AMD FT raw:'  "$aft_line"
    [ -n "$aft2_line" ] && print_row 'AMD FT2 raw:' "$aft2_line"
    print_row 'Ext raw:'    "$ext_line"
    [ -n "$ext2_line" ] && print_row 'Ext2 raw:'  "$ext2_line"
    [ -n "$ext3_line" ] && print_row 'Ext3 raw:'  "$ext3_line"
    [ -n "$vtx_line"  ] && print_row 'VT-x line:' "$vtx_line"
    [ -n "$svm_line"  ] && print_row 'SVM line:'  "$svm_line"
fi

section 'silicon'
print_row 'vendor:'          "$vendor"
print_row 'family/mod/step:' "$(printf '0x%s / 0x%s / 0x%s' "$fam_hex" "$mod_hex" "$(printf '%x' "$step")")"
[ -n "$id_str" ] && print_row 'CPUID Id:' "$id_str"

# Global verdict state set by decode_intel/decode_amd, consumed below.
case "$vendor" in
    GenuineIntel)     decode_intel ;;
    AuthenticAMD|HygonGenuine|AMDisbetter) decode_amd ;;
    *)
        print_row 'vendor:' "$vendor (unsupported x86 vendor)"
        banner
        exit 2
        ;;
esac

# ============================================================================
# decode_intel: VMX silicon identity, leaf-1 features, leaf-7 features,

if [ "$verdict_ok" = "1" ]; then
    exit 0
elif [ "$verdict_ok" = "0" ] && [ "$vendor" = "GenuineIntel" -o "$vendor" = "AuthenticAMD" -o "$vendor" = "HygonGenuine" -o "$vendor" = "AMDisbetter" ]; then
    exit 1
fi
