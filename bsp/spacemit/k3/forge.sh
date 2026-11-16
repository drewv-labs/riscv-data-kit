#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // SpacemiT K3 (8x X100 RVA23 + 1024b RVV 1.0) Silicon BSP
# Path: riscv-data-kit/bsp/spacemit/k3/forge.sh
# Boards: Milk-V Jupiter 2, Firefly AIBOX-K3
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

rvdk_log_init "RVDK:SPACEMIT-K3"
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

rvdk_prog_init "SpacemiT K3 BSP: inspecting device tree..."
log_info "Detected Device-Tree Model: $(rvdk_bsp_read_dt_model)"

rvdk_prog 25 "SpacemiT K3 BSP: protecting U-Boot & DTB hooks..."
rvdk_bsp_protect_dpkg "/etc/apt/apt.conf.d/90-spacemit-bsp-protect" "SpacemiT K3 U-Boot/DTB"
rvdk_bsp_backup_boot_configs /boot/extlinux/extlinux.conf /boot/efi/extlinux.conf /etc/default/u-boot

rvdk_prog 45 "SpacemiT K3 BSP: checking primary wired NIC..."
rvdk_bsp_persist_wired_nic "spacemit-k3" end0 eth0

rvdk_prog 65 "SpacemiT K3 BSP: masking sleep/suspend targets..."
rvdk_bsp_mask_sleep_targets

rvdk_prog 82 "SpacemiT K3 BSP: locking 8x X100 performance governor..."
rvdk_bsp_lock_cpufreq_performance "spacemit-k3" "Lock SpacemiT K3 X100 Harts to Performance Governor"

rvdk_prog 92 "SpacemiT K3 BSP: unlocking X100 PMU counters..."
rvdk_bsp_unlock_pmu "/etc/sysctl.d/90-spacemit-x100-pmu.conf" "SpacemiT X100" "$EXPOSE_KALLSYMS"

rvdk_prog 100 "SpacemiT K3 BSP hardening complete"
log_info "SpacemiT K3 BSP bootstrap complete."
