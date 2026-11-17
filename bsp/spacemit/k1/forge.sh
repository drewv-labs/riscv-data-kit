#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // SpacemiT K1 / M1 / Ky X1 (8x X60 RVA22 + RVV 1.0) Silicon BSP
# Path: riscv-data-kit/bsp/spacemit/k1/forge.sh
# Boards: Orange Pi RV2, Orange Pi R2S, Banana Pi BPI-F3, BPI-CM6, Milk-V Jupiter
# OSes:   SpacemiT Bianbu OS, Ubuntu 24.04+, Debian / Armbian, OpenWrt (procd)
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

rvdk_log_init "RVDK:SPACEMIT-K1"
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

rvdk_prog_init "SpacemiT K1 BSP: inspecting device tree..."
log_info "Detected Device-Tree Model: $(rvdk_bsp_read_dt_model)"

rvdk_prog 18 "SpacemiT K1 BSP: protecting U-Boot & DTB hooks..."
rvdk_bsp_protect_dpkg "/etc/apt/apt.conf.d/90-spacemit-bsp-protect" "SpacemiT/Ky U-Boot/DTB"
rvdk_bsp_backup_boot_configs \
    /boot/orangepiEnv.txt \
    /boot/env_k1-x.txt \
    /boot/spacemit/env_k1-x.txt \
    /boot/extlinux/extlinux.conf \
    /boot/efi/extlinux.conf \
    /boot/armbianEnv.txt \
    /etc/default/u-boot

rvdk_prog 36 "SpacemiT K1 BSP: converging SD/eMMC rootfs labels..."
rvdk_bsp_converge_mmc_root_labels

rvdk_prog 54 "SpacemiT K1 BSP: checking primary wired NIC..."
rvdk_bsp_persist_wired_nic "spacemit" end0 end1 eth0 eth1 enP2p1s0 enP1p1s0

rvdk_prog 70 "SpacemiT K1 BSP: masking sleep/suspend targets..."
rvdk_bsp_mask_sleep_targets

rvdk_prog 85 "SpacemiT K1 BSP: locking 8x X60 performance governor..."
rvdk_bsp_lock_cpufreq_performance "spacemit-k1" "Lock SpacemiT K1/M1/Ky X1 X60 Harts to Performance Governor"

rvdk_prog 94 "SpacemiT K1 BSP: unlocking X60 PMU counters..."
rvdk_bsp_unlock_pmu "/etc/sysctl.d/90-spacemit-x60-pmu.conf" "SpacemiT X60" "$EXPOSE_KALLSYMS"

rvdk_prog 100 "SpacemiT K1/M1 BSP hardening complete"
log_info "SpacemiT K1/M1 BSP bootstrap complete."
