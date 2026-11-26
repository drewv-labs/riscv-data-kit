#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Layer 2: Espressif ESP32-P4 Silicon SoC DeepTune
# Path: riscv-data-kit/bsp/espressif/esp32p4/deeptune.sh
#
# Description:
#   Idempotently generates declarative ESP-IDF / NuttX Kconfig fragments
#   (`sdkconfig.rvdk.iot.defaults` or `sdkconfig.rvdk.ai.defaults`) and
#   `deeptune.env` under `/etc/rvdk/` (on-target) or `<stage-dir>/config/`
#   (host-staged SD card provisioning).
# ==============================================================================

if [[ -n "${ZSH_VERSION:-}" ]]; then
    case "${0:-}" in
        zsh|-zsh|*/zsh|*/-zsh|zsh[0-9]*|*/zsh[0-9]*) ;;
        *)
            if [[ -f "${0:-}" ]]; then
                exec bash "$0" "$@"
            fi
            ;;
    esac
    printf '[FAIL] %s\n' "This script requires bash. When piping over stdin, run: curl ... | sudo bash" >&2
    exit 1
fi
set -Eeuo pipefail

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

# @RVDK_INLINE_LIBS: common kit progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:ESP32P4-DEEPTUNE]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_kv_load() { :; }
        rvdk_atomic_write() {
            local _dst="$1" _mode="${2:-0644}" _tmp
            mkdir -p "$(dirname "$_dst")"
            _tmp="$(mktemp "$(dirname "$_dst")/.$(basename "$_dst").rvdk.XXXXXX")"
            cat > "$_tmp"
            chmod "$_mode" "$_tmp"
            mv -f "$_tmp" "$_dst"
        }
        rvdk_sudo_preserve() {
            [[ $# -gt 0 ]] || return 1
            local -a _allow=(
                RVDK_ALLOW_CIDR RVDK_APT_DISTRO_DEFAULT RVDK_ARCH RVDK_BACKUP_ROOT
                RVDK_BASE_URL RVDK_BOARD RVDK_BOARDS_DIR RVDK_BOARD_QUIRKS RVDK_BOARD_TAG
                RVDK_BOOT_BACKUP_DIR RVDK_BRANCH RVDK_CACHE_DIR RVDK_DEEPTUNE_CHAIN
                RVDK_DEEPTUNE_ENV RVDK_DEEPTUNE_LAYERS RVDK_DT_MODEL RVDK_ENGINE_DIR
                RVDK_ENV_FILE RVDK_FLASH_FORCE_RAW RVDK_HOSTNAME RVDK_KEEP_VENDOR_MIRRORS
                RVDK_KIT_CACHE_FILE RVDK_LOCALE RVDK_MAX_VALID_EPOCH RVDK_MIN_VALID_EPOCH
                RVDK_MIRROR_URL RVDK_MMU RVDK_NO_APT_UPDATE RVDK_NO_PROGBAR RVDK_OS_ID
                RVDK_OS_VERSION_ID RVDK_P550_HDMI_STATE_FILE RVDK_P550_PLAT_DRV_BASE
                RVDK_PARENT_BADGE_SGR RVDK_PARENT_BAR_SGR RVDK_PARENT_LABEL
                RVDK_PARENT_PROGBAR RVDK_PARENT_STATE RVDK_PRIMARY_NIC
                RVDK_PROGBAR_SESSION RVDK_PROG_BASE RVDK_PROG_SPAN RVDK_RELEASE_BASE
                RVDK_REPO_URL RVDK_SECONDARY_NIC RVDK_SKIP_NET_GUARD RVDK_SOC
                RVDK_SOC_SLUG RVDK_STATE_DIR RVDK_SUB_STATE RVDK_SYSTEMD_UNIT_DIR
                RVDK_TIMEZONE RVDK_TUNE RVDK_TUNE_MODE
            )
            local -a _present=()
            local _v _csv=""
            for _v in "${_allow[@]}"; do
                if [[ -n "${!_v+x}" ]]; then
                    _present+=("$_v")
                fi
            done
            local _rc=0
            if [[ ${#_present[@]} -eq 0 ]]; then
                sudo "$@" || _rc=$?
                return "$_rc"
            fi
            for _v in "${_present[@]}"; do
                _csv="${_csv:+${_csv},}${_v}"
            done
            local _probe_err="" _probe_rc=0
            _probe_err="$(sudo --preserve-env="$_csv" -n true 2>&1)" || _probe_rc=$?
            if [[ "$_probe_rc" -eq 0 ]]; then
                sudo --preserve-env="$_csv" "$@" || _rc=$?
                return "$_rc"
            fi
            if [[ "$_probe_err" =~ (not[[:space:]]+allowed|SETENV|preserve-env|unrecognized[[:space:]]+option|unknown[[:space:]]+option|illegal[[:space:]]+option|invalid[[:space:]]+option|unexpected[[:space:]]+argument) ]] \
                || sudo -n true >/dev/null 2>&1; then
                sudo "$@" || _rc=$?
                return "$_rc"
            fi
            if sudo -v; then
                if sudo --preserve-env="$_csv" -n true >/dev/null 2>&1; then
                    sudo --preserve-env="$_csv" "$@" || _rc=$?
                    return "$_rc"
                fi
                sudo "$@" || _rc=$?
                return "$_rc"
            fi
            return 1
        }
    fi
fi
if [[ -z "${_RVDK_KIT_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/kit.sh" ]]; then
        # shellcheck source=lib/kit.sh
        source "${_REPO_ROOT}/lib/kit.sh"
    fi
fi
if [[ -z "${_RVDK_PROGBAR_SH_LOADED:-}" ]]; then
    _PROGBAR_CANDIDATE="${RVDK_PROGBAR_LIB:-}"
    [[ -z "$_PROGBAR_CANDIDATE" && -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]] && _PROGBAR_CANDIDATE="${_REPO_ROOT}/lib/progbar.sh"
    if [[ -n "$_PROGBAR_CANDIDATE" && -f "$_PROGBAR_CANDIDATE" ]]; then
        # shellcheck disable=SC1090
        source "$_PROGBAR_CANDIDATE"
    else
        rvdk_prog_init() { :; }
        rvdk_prog()      { :; }
    fi
fi

rvdk_log_init "RVDK:ESP32P4-DEEPTUNE"

ACTION="apply"
TUNE_REQUEST="${RVDK_TUNE:-}"
STAGE_DIR=""
FORCE_APPLY="false"
ORIG_ARGS=("$@")

usage() {
    cat <<'EOF'
Usage:
  sudo rvdk deeptune [--tune <iot|ai|data>] [status] [--stage-dir <dir>] [--force] [--noprogbar]
  bsp/espressif/esp32p4/deeptune.sh [--tune <iot|ai|data>] [status] [--stage-dir <dir>] [--force] [--noprogbar]

Layer 2 SoC script: bsp/espressif/esp32p4/deeptune.sh
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tune)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument: iot | ai | data"
            TUNE_REQUEST="$2"
            shift 2
            ;;
        --tune=*)
            TUNE_REQUEST="${1#*=}"
            shift
            ;;
        iot|edge-iot|sensor|mcu|ai|ml|edge-ai|edge-ml|data)
            TUNE_REQUEST="$1"
            shift
            ;;
        --stage-dir)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires a directory argument."
            STAGE_DIR="$2"
            shift 2
            ;;
        --stage-dir=*)
            STAGE_DIR="${1#*=}"
            [[ -z "$STAGE_DIR" ]] && log_fatal "Option '--stage-dir=' requires a non-empty directory."
            shift
            ;;
        status|--status)
            ACTION="status"
            shift
            ;;
        --force)
            FORCE_APPLY="true"
            shift
            ;;
        --no-apt-update|--skip-apt-update)
            export RVDK_NO_APT_UPDATE="1"
            shift
            ;;
        --noprogbar|--no-progbar)
            export RVDK_NO_PROGBAR="1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_fatal "Unknown argument: $1 (try --help)"
            ;;
    esac
done

if [[ -n "$STAGE_DIR" ]]; then
    OUT_DIR="${STAGE_DIR%/}/config"
else
    OUT_DIR="/etc/rvdk"
fi

ENV_FILE="${OUT_DIR}/deeptune.env"
IOT_CFG_FILE="${OUT_DIR}/sdkconfig.rvdk.iot.defaults"
AI_CFG_FILE="${OUT_DIR}/sdkconfig.rvdk.ai.defaults"

print_status() {
    local active_tune="unconfigured" active_frag="none"
    if [[ -r "$ENV_FILE" ]]; then
        if typeset -f rvdk_kv_load >/dev/null 2>&1; then
            local RVDK_TUNE="" RVDK_SDKCONFIG_FRAGMENT=""
            rvdk_kv_load "$ENV_FILE" RVDK_TUNE RVDK_SDKCONFIG_FRAGMENT
            active_tune="${RVDK_TUNE:-unconfigured}"
            active_frag="${RVDK_SDKCONFIG_FRAGMENT:-none}"
        else
            active_tune="$(awk -F= '/^RVDK_TUNE=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$ENV_FILE" 2>/dev/null || echo "unconfigured")"
            active_frag="$(awk -F= '/^RVDK_SDKCONFIG_FRAGMENT=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$ENV_FILE" 2>/dev/null || echo "none")"
        fi
    fi
    local frag_state="absent"
    if [[ "$active_frag" != "none" && -f "${OUT_DIR}/${active_frag}" ]]; then
        frag_state="present (${OUT_DIR}/${active_frag})"
    fi

    log_info "Layer 2 SoC (espressif/esp32p4):"
    printf "  • Config Directory  : %s\n" "$OUT_DIR"
    printf "  • Active Tune       : %s\n" "$active_tune"
    printf "  • Kconfig Fragment  : %s\n" "$frag_state"
}

if [[ "$ACTION" == "status" ]]; then
    print_status
    exit 0
fi

if [[ -z "$STAGE_DIR" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && command -v sudo >/dev/null 2>&1; then
        _sudo_rc=0
        rvdk_sudo_preserve bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} || _sudo_rc=$?
        exit "$_sudo_rc"
    else
        log_fatal "Root privileges required for on-target /etc/rvdk writes (or pass --stage-dir <dir>)."
    fi
fi

if [[ -z "$TUNE_REQUEST" && -r "$ENV_FILE" ]]; then
    if typeset -f rvdk_kv_load >/dev/null 2>&1; then
        RVDK_TUNE=""
        rvdk_kv_load "$ENV_FILE" RVDK_TUNE
        TUNE_REQUEST="$RVDK_TUNE"
    else
        TUNE_REQUEST="$(awk -F= '/^RVDK_TUNE=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$ENV_FILE" 2>/dev/null || true)"
    fi
fi
TUNE_REQUEST="$(tr '[:upper:]' '[:lower:]' <<< "${TUNE_REQUEST:-iot}")"

case "$TUNE_REQUEST" in
    iot|edge-iot|sensor|mcu)
        TUNE_MODE="iot"
        TUNE_LABEL="iot"
        ;;
    ai|ml|edge-ai|edge-ml)
        TUNE_MODE="ai"
        TUNE_LABEL="ai"
        ;;
    data)
        log_warn "ESP32-P4 is riscv32 nommu without PG18/NVMe; mapping '--tune data' to minimal 'iot' Kconfig profile"
        TUNE_MODE="iot"
        TUNE_LABEL="iot"
        ;;
    *)
        log_fatal "Invalid --tune '${TUNE_REQUEST}' (expected: iot | ai | data)"
        ;;
esac

rvdk_prog_init "ESP32-P4 DeepTune (--tune ${TUNE_LABEL}): generating Kconfig fragment..."
log_info "Converging Espressif ESP32-P4 DeepTune (--tune ${TUNE_LABEL} | out=${OUT_DIR})..."

mkdir -p "$OUT_DIR"

if [[ "$TUNE_MODE" == "iot" ]]; then
    TARGET_CFG="$IOT_CFG_FILE"
    STALE_CFG="$AI_CFG_FILE"
    WANT_CFG="# Managed by RVDK (bsp/espressif/esp32p4/deeptune.sh | tune=iot)
CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ_360=y
CONFIG_PM_ENABLE=y
CONFIG_FREERTOS_USE_TICKLESS_IDLE=y
CONFIG_FREERTOS_HZ=1000
CONFIG_SPIRAM=y
CONFIG_SPIRAM_SPEED_200M=y
CONFIG_SPIRAM_ALLOW_BSS_SEG_EXTERNAL_MEMORY=y
CONFIG_SDMMC_HOST_DEFAULT_MAX_FREQ_KHZ=40000
CONFIG_FATFS_LFN_HEAP=y
CONFIG_LOG_DEFAULT_LEVEL_WARN=y
CONFIG_ESP_WIFI_REMOTE_ENABLED=y
CONFIG_SLAVE_IDF_TARGET_ESP32C6=y"
else
    TARGET_CFG="$AI_CFG_FILE"
    STALE_CFG="$IOT_CFG_FILE"
    WANT_CFG="# Managed by RVDK (bsp/espressif/esp32p4/deeptune.sh | tune=ai)
CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ_400=y
CONFIG_PM_ENABLE=n
CONFIG_COMPILER_OPTIMIZATION_PERF=y
CONFIG_SPIRAM=y
CONFIG_SPIRAM_SPEED_200M=y
CONFIG_SPIRAM_XIP_FROM_PSRAM=y
CONFIG_CACHE_L2_CACHE_256KB=y
CONFIG_CACHE_L2_CACHE_LINE_128B=y
CONFIG_ESP_SYSTEM_ALLOW_RTC_FAST_MEM_AS_HEAP=y
CONFIG_SDMMC_HOST_DEFAULT_MAX_FREQ_KHZ=40000"
fi

TARGET_FRAG_NAME="$(basename "$TARGET_CFG")"
WANT_ENV="# Managed by RVDK (bsp/espressif/esp32p4/deeptune.sh)
RVDK_SOC=\"espressif/esp32p4\"
RVDK_SOC_SLUG=\"espressif-esp32p4\"
RVDK_ARCH=\"riscv32\"
RVDK_MMU=\"none\"
RVDK_TUNE=\"${TUNE_LABEL}\"
RVDK_TUNE_MODE=\"${TUNE_MODE}\"
RVDK_SDKCONFIG_FRAGMENT=\"${TARGET_FRAG_NAME}\""

CHANGED="false"
if [[ -f "$STALE_CFG" || -L "$STALE_CFG" ]]; then
    rm -f "$STALE_CFG"
    CHANGED="true"
fi

if [[ "$FORCE_APPLY" == "true" ]] || [[ ! -f "$TARGET_CFG" || -L "$TARGET_CFG" ]] || ! printf '%s\n' "$WANT_CFG" | cmp -s - "$TARGET_CFG" 2>/dev/null; then
    printf '%s\n' "$WANT_CFG" | rvdk_atomic_write "$TARGET_CFG" 0644
    CHANGED="true"
fi

if [[ "$FORCE_APPLY" == "true" ]] || [[ ! -f "$ENV_FILE" || -L "$ENV_FILE" ]] || ! printf '%s\n' "$WANT_ENV" | cmp -s - "$ENV_FILE" 2>/dev/null; then
    printf '%s\n' "$WANT_ENV" | rvdk_atomic_write "$ENV_FILE" 0644
    CHANGED="true"
fi

if [[ "$CHANGED" == "true" ]]; then
    log_ok "Wrote ESP32-P4 Kconfig fragment (${TARGET_CFG}) and state (${ENV_FILE})"
else
    log_skip "ESP32-P4 Kconfig fragment (${TARGET_CFG}) and state (${ENV_FILE}) already converged"
fi

rvdk_prog 100 "ESP32-P4 DeepTune (--tune ${TUNE_LABEL}) complete"
