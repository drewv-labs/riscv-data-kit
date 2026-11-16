#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Tenstorrent Atlantis (8x Ascalon-X RVA23 OoO) Silicon BSP
# Path: riscv-data-kit/bsp/tenstorrent/atlantis/forge.sh
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

rvdk_log_init "RVDK:ATLANTIS"
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

rvdk_prog_init "Tenstorrent Atlantis BSP: inspecting device tree..."
log_info "Detected Device-Tree Model: $(rvdk_bsp_read_dt_model)"

rvdk_prog 30 "Tenstorrent Atlantis BSP: protecting OpenSBI/UEFI/DTB hooks..."
rvdk_bsp_protect_dpkg "/etc/apt/apt.conf.d/90-tenstorrent-bsp-protect" "Tenstorrent Atlantis UEFI/DTB"
rvdk_bsp_backup_boot_configs /boot/extlinux/extlinux.conf /boot/efi/extlinux.conf

rvdk_prog 50 "Tenstorrent Atlantis BSP: checking primary wired NIC..."
rvdk_bsp_persist_wired_nic "atlantis" end0 eth0

rvdk_prog 68 "Tenstorrent Atlantis BSP: masking sleep/suspend targets..."
rvdk_bsp_mask_sleep_targets

rvdk_prog 85 "Tenstorrent Atlantis BSP: locking Ascalon-X governor & PMU..."
rvdk_bsp_lock_cpufreq_performance "atlantis" "Lock Tenstorrent Atlantis Ascalon-X Harts to Performance Governor"
rvdk_bsp_unlock_pmu "/etc/sysctl.d/90-tenstorrent-ascalon-pmu.conf" "Tenstorrent Ascalon-X" "$EXPOSE_KALLSYMS"

rvdk_prog 100 "Tenstorrent Atlantis BSP hardening complete"
log_info "Tenstorrent Atlantis BSP bootstrap complete."
