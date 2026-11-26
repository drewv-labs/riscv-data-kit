#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // ESWIN EIC7700X (SiFive P550 Core Complex) Ubuntu/Debian BSP
# Path: riscv-data-kit/bsp/eswin/eic7700x/bootstrap-ubuntu.sh
# Description: Bootloader protection, SSH-safe wired NIC check, sleep target
#              lockout, cpufreq performance governor, and KASLR-safe SiFive
#              P550 PMU counter exposure for ESWIN EIC7700X.
# ==============================================================================

set -Eeuo pipefail

ORIG_ARGS=("$@")
EXPOSE_KALLSYMS="false"
export DEBIAN_FRONTEND=noninteractive

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

# @RVDK_INLINE_LIBS: common bsp progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:EIC7700X]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_sanitize_locale() { export LANG="C.UTF-8" LC_ALL="C.UTF-8"; }
    fi
fi
if [[ -z "${_RVDK_BSP_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/bsp.sh" ]]; then
        # shellcheck source=lib/bsp.sh
        source "${_REPO_ROOT}/lib/bsp.sh"
    fi
fi
if [[ -z "${_RVDK_PROGBAR_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]]; then
        # shellcheck source=lib/progbar.sh
        source "${_REPO_ROOT}/lib/progbar.sh"
    else
        rvdk_prog_init() { :; }
        rvdk_prog()      { :; }
    fi
fi

rvdk_log_init "RVDK:EIC7700X"

usage() {
    cat <<'EOF'
Usage: sudo rvdk bsp [--expose-kallsyms] [--no-apt-update] [--noprogbar]
Layer 2 BSP script: bsp/eswin/eic7700x/bootstrap-ubuntu.sh

Options:
  --expose-kallsyms    Set kernel.kptr_restrict to 0 (exposes kernel symbols for perf; weakens KASLR)
  --no-apt-update      Skip apt-get update calls
  --noprogbar          Disable persistent bottom progress bar
  -h, --help           Show this help message and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --expose-kallsyms)                 EXPOSE_KALLSYMS="true"; shift ;;
        --skip-upgrade|--full-upgrade|--with-vendor-repo)
                                           shift ;;
        --debian-suite)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."
            shift 2 ;;
        --keep-mirrors)                    export RVDK_KEEP_VENDOR_MIRRORS="1"; shift ;;
        --no-apt-update|--skip-apt-update) export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)          export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)                         usage; exit 0 ;;
        *)                                 log_fatal "Unknown argument: $1 (try --help)" ;;
    esac
done

rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
rvdk_sanitize_locale

rvdk_prog_init "EIC7700X BSP: inspecting device tree..."
log_info "Detected Device-Tree Model: $(rvdk_bsp_read_dt_model)"

_eic_board_tag="${RVDK_BOARD_TAG:-eic7700x}"
if [[ ! "$_eic_board_tag" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    log_warn "Invalid RVDK_BOARD_TAG '${_eic_board_tag}'; defaulting to 'eic7700x'"
    _eic_board_tag="eic7700x"
fi

rvdk_prog 15 "EIC7700X BSP: protecting bootloader & DTB hooks..."
rvdk_bsp_protect_dpkg "/etc/apt/apt.conf.d/90-${_eic_board_tag}-bsp-protect" "ESWIN EIC7700X U-Boot/DTB"
rvdk_bsp_backup_boot_configs /boot/extlinux/extlinux.conf /boot/efi/extlinux.conf

rvdk_prog 35 "EIC7700X BSP: checking primary wired NIC..."
rvdk_bsp_persist_wired_nic "${_eic_board_tag}" end0 eth0

rvdk_prog 55 "EIC7700X BSP: masking sleep/suspend targets..."
rvdk_bsp_mask_sleep_targets

rvdk_prog 75 "EIC7700X BSP: locking SiFive P550 performance governor..."
rvdk_bsp_lock_cpufreq_performance "eic7700x" "Lock ESWIN EIC7700X SiFive P550 Harts to Performance Governor"

rvdk_prog 90 "EIC7700X BSP: unlocking SiFive P550 PMU counters..."
rvdk_bsp_unlock_pmu "/etc/sysctl.d/90-sifive-p550-pmu.conf" "SiFive P550 L1/PL2/L3" "$EXPOSE_KALLSYMS"

rvdk_prog 100 "ESWIN EIC7700X BSP hardening complete"
log_info "ESWIN EIC7700X BSP bootstrap complete."
