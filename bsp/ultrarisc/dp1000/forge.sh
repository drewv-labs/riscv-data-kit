#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // UltraRISC UR-DP1000 (8x CP100 OoO — Milk-V Titan) Silicon BSP
# Path: riscv-data-kit/bsp/ultrarisc/dp1000/forge.sh
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

rvdk_log_init "RVDK:DP1000"
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

rvdk_prog_init "UR-DP1000 BSP: inspecting device tree & PCIe..."
log_info "Detected Device-Tree Model: $(rvdk_bsp_read_dt_model)"

rvdk_prog 25 "UR-DP1000 BSP: protecting UEFI/GRUB/DTB hooks..."
rvdk_bsp_protect_dpkg "/etc/apt/apt.conf.d/90-ultrarisc-bsp-protect" "UltraRISC UR-DP1000 UEFI/GRUB"
rvdk_bsp_backup_boot_configs /etc/default/grub /boot/efi/EFI/debian/grub.cfg

rvdk_prog 45 "UR-DP1000 BSP: checking primary wired NIC..."
rvdk_bsp_persist_wired_nic "dp1000" enp1s0 end0 eth0

rvdk_prog 65 "UR-DP1000 BSP: masking sleep/suspend targets..."
rvdk_bsp_mask_sleep_targets

rvdk_prog 82 "UR-DP1000 BSP: locking 8x CP100 performance governor..."
rvdk_bsp_lock_cpufreq_performance "dp1000" "Lock UltraRISC UR-DP1000 CP100 Harts to Performance Governor"

rvdk_prog 92 "UR-DP1000 BSP: unlocking CP100 PMU counters..."
rvdk_bsp_unlock_pmu "/etc/sysctl.d/90-ultrarisc-cp100-pmu.conf" "UltraRISC UR-CP100" "$EXPOSE_KALLSYMS"

rvdk_prog 100 "UltraRISC UR-DP1000 BSP hardening complete"
log_info "UltraRISC UR-DP1000 BSP bootstrap complete."
