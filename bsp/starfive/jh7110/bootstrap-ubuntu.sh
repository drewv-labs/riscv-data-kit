#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // StarFive JH7110 / JH7110S (SiFive U74) Ubuntu BSP Bootstrapper
# Path: riscv-data-kit/bsp/starfive/jh7110/bootstrap-ubuntu.sh
# Description: Idempotent Layer 2 BSP hardening for StarFive JH7110 / JH7110S
#              (VisionFive 2, VisionFive 2 Lite, Milk-V Mars, Orange Pi RV) on Ubuntu.
# ==============================================================================

set -Eeuo pipefail

ORIG_ARGS=("$@")
EXPOSE_KALLSYMS="false"

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

# @RVDK_INLINE_LIBS: common bsp progbar
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${_REPO_ROOT}/lib/common.sh"
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/bsp.sh" ]]; then
    # shellcheck source=lib/bsp.sh
    source "${_REPO_ROOT}/lib/bsp.sh"
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]]; then
    # shellcheck source=lib/progbar.sh
    source "${_REPO_ROOT}/lib/progbar.sh"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_log_init "RVDK:JH7110"
rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
rvdk_sanitize_locale

while [[ $# -gt 0 ]]; do
    case "$1" in
        --expose-kallsyms)                 EXPOSE_KALLSYMS="true"; shift ;;
        --no-apt-update|--skip-apt-update) export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)          export RVDK_NO_PROGBAR="1"; shift ;;
        *)                                 shift ;;
    esac
done

rvdk_prog_init "JH7110 Ubuntu BSP: inspecting device tree..."
log_info "Detected Device-Tree Model: $(rvdk_bsp_read_dt_model)"

rvdk_prog 20 "JH7110 BSP: protecting U-Boot & DTB hooks..."
rvdk_bsp_protect_dpkg "/etc/apt/apt.conf.d/90-starfive-bsp-protect" "StarFive U-Boot/DTB"
rvdk_bsp_backup_boot_configs \
    /boot/extlinux/extlinux.conf \
    /boot/boot/extlinux/extlinux.conf \
    /boot/efi/extlinux.conf \
    /etc/default/u-boot \
    /etc/kernel/postinst.d/zz-u-boot-menu \
    /etc/flash-kernel/machine

rvdk_prog 45 "JH7110 BSP: checking primary wired NIC..."
rvdk_bsp_persist_wired_nic "jh7110" end0 eth0

rvdk_prog 65 "JH7110 BSP: masking sleep/suspend targets..."
rvdk_bsp_mask_sleep_targets

MAX_KHZ="$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "")"
if [[ "$MAX_KHZ" =~ ^[0-9]+$ ]] && (( MAX_KHZ > 0 )); then
    MAX_MHZ_LABEL="$(( MAX_KHZ / 1000 )) MHz"
else
    MAX_MHZ_LABEL="max OPP"
fi

rvdk_prog 82 "JH7110 BSP: locking ${MAX_MHZ_LABEL} U74 governor..."
rvdk_bsp_lock_cpufreq_performance "jh7110" "Lock StarFive JH7110/JH7110S SiFive U74 Harts to Performance Governor"

rvdk_prog 92 "JH7110 BSP: unlocking SiFive U74 PMU counters..."
rvdk_bsp_unlock_pmu "/etc/sysctl.d/90-starfive-u74-pmu.conf" "SiFive U74" "$EXPOSE_KALLSYMS"

rvdk_prog 100 "StarFive JH7110/JH7110S Ubuntu BSP hardening complete"
log_info "StarFive JH7110/JH7110S (Ubuntu) BSP bootstrap complete."
