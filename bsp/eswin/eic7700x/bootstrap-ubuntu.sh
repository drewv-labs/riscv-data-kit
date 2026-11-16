#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // SiFive HiFive Premier P550 / Milk-V Megrez (ESWIN EIC7700X) BSP
# Path: riscv-data-kit/bsp/eswin/eic7700x/bootstrap-ubuntu.sh
# Description: Bootloader protection, SSH-safe wired NIC check, sleep target
#              lockout, cpufreq performance governor, PWM fan control, and
#              KASLR-safe SiFive P550 PMU counter exposure for ESWIN EIC7700X.
# ==============================================================================

set -Eeuo pipefail

ORIG_ARGS=("$@")
EXPOSE_KALLSYMS="false"
export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

# @RVDK_INLINE_LIBS: common apt bsp progbar
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${_REPO_ROOT}/lib/common.sh"
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/apt.sh" ]]; then
    # shellcheck source=lib/apt.sh
    source "${_REPO_ROOT}/lib/apt.sh"
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

rvdk_log_init "RVDK:EIC7700X"
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

rvdk_prog_init "EIC7700X BSP: inspecting device tree..."
log_info "Detected Device-Tree Model: $(rvdk_bsp_read_dt_model)"

rvdk_prog 15 "EIC7700X BSP: protecting bootloader & DTB hooks..."
rvdk_bsp_protect_dpkg "/etc/apt/apt.conf.d/90-p550-bsp-protect" "ESWIN EIC7700X U-Boot/DTB"
rvdk_bsp_backup_boot_configs /boot/extlinux/extlinux.conf /boot/efi/extlinux.conf

rvdk_prog 35 "EIC7700X BSP: checking primary wired NIC (end0)..."
rvdk_bsp_persist_wired_nic "p550" end0 eth0

rvdk_prog 55 "EIC7700X BSP: masking sleep/suspend targets..."
rvdk_bsp_mask_sleep_targets

rvdk_prog 75 "EIC7700X BSP: locking P550 performance governor..."
rvdk_bsp_lock_cpufreq_performance "eic7700x" "Lock ESWIN EIC7700X SiFive P550 Harts to Performance Governor"

rvdk_prog 90 "EIC7700X BSP: PWM fan controller & P550 PMU unlock..."
if command -v apt-cache >/dev/null 2>&1 && apt-cache show fancontrol-config-p550-premier >/dev/null 2>&1; then
    if ! dpkg -s fancontrol-config-p550-premier >/dev/null 2>&1; then
        rvdk_apt_ensure fancontrol-config-p550-premier
        log_ok "Installed fancontrol-config-p550-premier"
    else
        log_skip "fancontrol-config-p550-premier already installed"
    fi
fi

rvdk_bsp_unlock_pmu "/etc/sysctl.d/90-sifive-p550-pmu.conf" "SiFive P550 L1/PL2/L3" "$EXPOSE_KALLSYMS"

rvdk_prog 100 "ESWIN EIC7700X BSP hardening complete"
log_info "ESWIN EIC7700X BSP bootstrap complete."
