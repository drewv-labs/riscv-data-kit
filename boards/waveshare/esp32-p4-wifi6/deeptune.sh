#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Layer 3: Waveshare ESP32-P4-WIFI6-DEV-KIT DeepTune
# Path: riscv-data-kit/boards/waveshare/esp32-p4-wifi6/deeptune.sh
#
# Description:
#   Configures Waveshare ESP32-P4-WIFI6-DEV-KIT carrier peripheral defaults
#   (ESP32-C6 SDIO transport, IP101GRI 100M RMII Ethernet PHY, MIPI-CSI/DSI
#   power-gating, and USB-Serial-JTAG console rate) in
#   `<stage-dir>/config/board-waveshare-p4.defaults` or `/etc/rvdk/board-waveshare-p4.defaults`.
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
        log_info()  { printf "\033[1;36m[RVDK:WAVESHARE-P4-DEEPTUNE]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_kv_load() { :; }
        rvdk_atomic_write() {
            local _dst="$1" _mode="${2:-0644}" _tmp
            mkdir -p "$(dirname "$_dst")"
            _tmp="$(mktemp "$(dirname "$_dst")/.$(basename "$_dst").rvdk.XXXXXX")"
            cat > "$_tmp"
            chmod "$_mode" "$_tmp"
            mv -f "$_tmp" "$_dst"
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

rvdk_log_init "RVDK:WAVESHARE-P4-DEEPTUNE"

if ! typeset -f rvdk_sudo_preserve >/dev/null 2>&1; then
    rvdk_sudo_preserve() {
        [[ $# -gt 0 ]] || return 1
        local -a _allowlist=(
            RVDK_ALLOW_CIDR
            RVDK_APT_DISTRO_DEFAULT
            RVDK_ARCH
            RVDK_BOARD
            RVDK_BOARD_QUIRKS
            RVDK_BOARD_TAG
            RVDK_BOOT_BACKUP_DIR
            RVDK_BRANCH
            RVDK_CACHE_DIR
            RVDK_DEEPTUNE_CHAIN
            RVDK_DEEPTUNE_ENV
            RVDK_DEEPTUNE_LAYERS
            RVDK_DT_MODEL
            RVDK_FLASH_FORCE_RAW
            RVDK_HOSTNAME
            RVDK_KEEP_VENDOR_MIRRORS
            RVDK_LOCALE
            RVDK_MAX_VALID_EPOCH
            RVDK_MIN_VALID_EPOCH
            RVDK_MMU
            RVDK_NO_APT_UPDATE
            RVDK_NO_PROGBAR
            RVDK_OS_ID
            RVDK_OS_VERSION_ID
            RVDK_P550_HDMI_STATE_FILE
            RVDK_PARENT_BADGE_SGR
            RVDK_PARENT_BAR_SGR
            RVDK_PARENT_LABEL
            RVDK_PARENT_PROGBAR
            RVDK_PARENT_STATE
            RVDK_PRIMARY_NIC
            RVDK_PROGBAR_SESSION
            RVDK_PROG_BASE
            RVDK_PROG_SPAN
            RVDK_SECONDARY_NIC
            RVDK_SKIP_NET_GUARD
            RVDK_SOC
            RVDK_SOC_SLUG
            RVDK_SUB_STATE
            RVDK_TIMEZONE
            RVDK_TUNE
            RVDK_TUNE_MODE
        )
        local preserve_csv=""
        local var_name
        for var_name in "${_allowlist[@]}"; do
            if [[ -n "${!var_name+x}" ]]; then
                preserve_csv+="${preserve_csv:+,}${var_name}"
            fi
        done

        local rc=0
        if [[ -z "$preserve_csv" ]]; then
            sudo "$@" || rc=$?
            return "$rc"
        fi

        local probe_err="" probe_rc=0
        probe_err="$(sudo --preserve-env="$preserve_csv" -n true 2>&1)" || probe_rc=$?
        if [[ "$probe_rc" -eq 0 ]]; then
            sudo --preserve-env="$preserve_csv" "$@" || rc=$?
            return "$rc"
        fi

        if [[ "$probe_err" =~ (not[[:space:]]+allowed|SETENV|preserve-env|unrecognized[[:space:]]+option|unknown[[:space:]]+option|illegal[[:space:]]+option|invalid[[:space:]]+option|unexpected[[:space:]]+argument) ]] \
            || sudo -n true >/dev/null 2>&1; then
            sudo "$@" || rc=$?
            return "$rc"
        fi

        if sudo -v; then
            if sudo --preserve-env="$preserve_csv" -n true >/dev/null 2>&1; then
                sudo --preserve-env="$preserve_csv" "$@" || rc=$?
                return "$rc"
            fi
            sudo "$@" || rc=$?
            return "$rc"
        fi
        return 1
    }
fi

ACTION="apply"
TUNE_REQUEST="${RVDK_TUNE:-}"
STAGE_DIR=""
FORCE_APPLY="false"
ORIG_ARGS=("$@")

usage() {
    cat <<'EOF'
Usage:
  sudo rvdk deeptune [--tune <iot|ai|data>] [status] [--stage-dir <dir>] [--force] [--noprogbar]
  boards/waveshare/esp32-p4-wifi6/deeptune.sh [--tune <iot|ai|data>] [status] [--stage-dir <dir>] [--force] [--noprogbar]

Layer 3 Board script: boards/waveshare/esp32-p4-wifi6/deeptune.sh
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

BOARD_DEFAULTS="${OUT_DIR}/board-waveshare-p4.defaults"
SOC_ENV_FILE="${OUT_DIR}/deeptune.env"
C6_ENV_FILE="${OUT_DIR}/c6-sdio.env"
C6_QUIRK="${_SCRIPT_DIR:+$_SCRIPT_DIR/quirks/c6-sdio.sh}"

print_status() {
    local cfg_tune="unconfigured" c6_mode="sdio-4bit-40mhz (default)" mipi_mode="unconfigured"
    if [[ -r "$BOARD_DEFAULTS" ]]; then
        cfg_tune="$(awk -F= '/^RVDK_TUNE=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$BOARD_DEFAULTS" 2>/dev/null || echo "unconfigured")"
        c6_mode="$(awk -F= '/^RVDK_C6_SDIO_TRANSPORT=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$BOARD_DEFAULTS" 2>/dev/null || echo "sdio-4bit-40mhz")"
        mipi_mode="$(awk -F= '/^RVDK_MIPI_CSI_POWER=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$BOARD_DEFAULTS" 2>/dev/null || echo "unconfigured")"
    fi
    log_info "Layer 3 Board (waveshare/esp32-p4-wifi6):"
    printf "  • Defaults File     : %s\n" "$BOARD_DEFAULTS"
    printf "  • Board Tune        : %s\n" "$cfg_tune"
    printf "  • C6 SDIO Transport : %s\n" "$c6_mode"
    printf "  • MIPI-CSI/DSI      : %s\n" "$mipi_mode"
    if [[ -n "$C6_QUIRK" && -f "$C6_QUIRK" ]]; then
        if [[ -n "$STAGE_DIR" ]]; then
            bash "$C6_QUIRK" status --stage-dir "$STAGE_DIR"
        else
            bash "$C6_QUIRK" status
        fi
    fi
}

if [[ "$ACTION" == "status" ]]; then
    print_status
    exit 0
fi

if [[ -z "$STAGE_DIR" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && command -v sudo >/dev/null 2>&1; then
        _rvdk_sudo_rc=0
        rvdk_sudo_preserve bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} || _rvdk_sudo_rc=$?
        exit "$_rvdk_sudo_rc"
    else
        log_fatal "Root privileges required for on-target /etc/rvdk writes (or pass --stage-dir <dir>)."
    fi
fi

if [[ -z "$TUNE_REQUEST" && -r "$SOC_ENV_FILE" ]]; then
    if typeset -f rvdk_kv_load >/dev/null 2>&1; then
        RVDK_TUNE=""
        rvdk_kv_load "$SOC_ENV_FILE" RVDK_TUNE
        TUNE_REQUEST="$RVDK_TUNE"
    else
        TUNE_REQUEST="$(awk -F= '/^RVDK_TUNE=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$SOC_ENV_FILE" 2>/dev/null || true)"
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
        log_warn "Waveshare ESP32-P4 is riscv32 nommu without PG18/NVMe; mapping '--tune data' to 'iot' peripheral profile"
        TUNE_MODE="iot"
        TUNE_LABEL="iot"
        ;;
    *)
        log_fatal "Invalid --tune '${TUNE_REQUEST}' (expected: iot | ai | data)"
        ;;
esac

C6_TRANSPORT="sdio-4bit-40mhz"
if [[ -r "$C6_ENV_FILE" ]]; then
    c6_flag=""
    if typeset -f rvdk_kv_load >/dev/null 2>&1; then
        RVDK_C6_SDIO_ENABLED=""
        rvdk_kv_load "$C6_ENV_FILE" RVDK_C6_SDIO_ENABLED
        c6_flag="$RVDK_C6_SDIO_ENABLED"
    else
        c6_flag="$(awk -F= '/^RVDK_C6_SDIO_ENABLED=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$C6_ENV_FILE" 2>/dev/null || true)"
    fi
    [[ "$c6_flag" == "false" ]] && C6_TRANSPORT="disabled"
fi

rvdk_prog_init "Waveshare ESP32-P4 DeepTune (--tune ${TUNE_LABEL}): converging board peripherals..."
mkdir -p "$OUT_DIR"

if [[ "$TUNE_MODE" == "ai" ]]; then
    MIPI_POWER="enabled"
    MIPI_KCFG="y"
else
    MIPI_POWER="disabled"
    MIPI_KCFG="n"
fi

WANT_BOARD_DEFAULTS="# Managed by RVDK (boards/waveshare/esp32-p4-wifi6/deeptune.sh | tune=${TUNE_LABEL})
RVDK_BOARD=\"waveshare/esp32-p4-wifi6\"
RVDK_TUNE=\"${TUNE_LABEL}\"
RVDK_C6_SDIO_TRANSPORT=\"${C6_TRANSPORT}\"
RVDK_RMII_ETH_PHY=\"ip101gri-100m\"
RVDK_MIPI_CSI_POWER=\"${MIPI_POWER}\"
RVDK_MIPI_DSI_POWER=\"${MIPI_POWER}\"
RVDK_USB_JTAG_VID_PID=\"303a:1001\"
RVDK_CONSOLE_BAUD=\"115200\"
CONFIG_ETH_USE_ESP32_EMAC=y
CONFIG_ETH_PHY_IP101=y
CONFIG_ETH_RMII_CLK_INPUT=y
CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y
CONFIG_ESP_CONSOLE_UART_BAUDRATE=115200
CONFIG_ESP_LCD_MIPI_DSI_ENABLE=${MIPI_KCFG}
CONFIG_ESP_VIDEO_MIPI_CSI_ENABLE=${MIPI_KCFG}"

if [[ "$FORCE_APPLY" == "true" ]] || [[ ! -f "$BOARD_DEFAULTS" || -L "$BOARD_DEFAULTS" ]] || ! printf '%s\n' "$WANT_BOARD_DEFAULTS" | cmp -s - "$BOARD_DEFAULTS" 2>/dev/null; then
    printf '%s\n' "$WANT_BOARD_DEFAULTS" | rvdk_atomic_write "$BOARD_DEFAULTS" 0644
    log_ok "Converged Waveshare ESP32-P4 board defaults (${BOARD_DEFAULTS} | tune=${TUNE_LABEL}, MIPI=${MIPI_POWER})"
else
    log_skip "Waveshare ESP32-P4 board defaults already converged (${BOARD_DEFAULTS})"
fi

rvdk_prog 100 "Waveshare ESP32-P4 DeepTune (--tune ${TUNE_LABEL}) complete"
