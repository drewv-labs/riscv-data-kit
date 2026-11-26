#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Board Quirk: Waveshare ESP32-P4-WIFI6 ESP32-C6 SDIO Link
# Path: riscv-data-kit/boards/waveshare/esp32-p4-wifi6/quirks/c6-sdio.sh
# Summary: Toggle onboard ESP32-C6 Wi-Fi 6 / BLE 5.3 SDIO co-processor transport
#
# Usage:
#   sudo rvdk quirk c6-sdio [enable|disable|toggle|status] [--stage-dir <dir>]
#   boards/waveshare/esp32-p4-wifi6/quirks/c6-sdio.sh [enable|disable|status] [--stage-dir <dir>]
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
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../../.." && pwd)"

# @RVDK_INLINE_LIBS: common kit progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:QUIRK:C6-SDIO]\033[0m %s\n" "$1"; }
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
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]]; then
        # shellcheck source=lib/progbar.sh
        source "${_REPO_ROOT}/lib/progbar.sh"
    else
        rvdk_prog_init() { :; }
        rvdk_prog()      { :; }
    fi
fi

rvdk_log_init "RVDK:QUIRK:C6-SDIO"

ACTION="toggle"
STAGE_DIR=""
FORCE_APPLY="false"
QUIET="false"
ORIG_ARGS=("$@")

_c6_info() { [[ "$QUIET" == "true" ]] || log_info "$1"; }
_c6_ok()   { [[ "$QUIET" == "true" ]] || log_ok "$1"; }
_c6_skip() { [[ "$QUIET" == "true" ]] || log_skip "$1"; }

usage() {
    cat <<'EOF'
Usage:
  sudo rvdk quirk c6-sdio [enable|disable|toggle|status] [--stage-dir <dir>] [--force] [--quiet]

Actions:
  enable | on     Enable ESP32-C6 Wi-Fi 6 / BLE 5.3 4-bit SDIO host transport (40 MHz)
  disable | off   Disable ESP32-C6 SDIO co-processor transport (lowest quiescent power)
  toggle          Flip current c6-sdio state (default)
  status          Show configured ESP32-C6 SDIO transport state

Flags:
  --stage-dir <dir>  Write config fragments to <dir>/config/ instead of /etc/rvdk/
  --force            Rewrite config fragments even if already converged
  -q, --quiet        Suppress informational output
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        toggle)                      ACTION="toggle"; shift ;;
        on|enable|start|1)           ACTION="enable"; shift ;;
        off|disable|stop|0)          ACTION="disable"; shift ;;
        status|stat|check|--status)  ACTION="status"; shift ;;
        --stage-dir)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires a directory argument."
            STAGE_DIR="$2"; shift 2 ;;
        --stage-dir=*)
            STAGE_DIR="${1#*=}"
            [[ -z "$STAGE_DIR" ]] && log_fatal "Option '--stage-dir=' requires a non-empty directory."
            shift ;;
        --force)                     FORCE_APPLY="true"; shift ;;
        -q|--quiet)                  QUIET="true"; shift ;;
        --ephemeral|--persist|--persistent|--runtime)
            shift ;;
        --noprogbar|--no-progbar|--no-apt-update|--skip-apt-update)
            export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)                   usage; exit 0 ;;
        *)                           log_fatal "Unknown argument: $1 (try --help)" ;;
    esac
done

if [[ -n "$STAGE_DIR" ]]; then
    OUT_DIR="${STAGE_DIR%/}/config"
else
    OUT_DIR="/etc/rvdk"
fi

C6_ENV_FILE="${OUT_DIR}/c6-sdio.env"
C6_KCONFIG_FILE="${OUT_DIR}/sdkconfig.rvdk.c6-sdio.defaults"

_read_c6_enabled() {
    local val=""
    if [[ -r "$C6_ENV_FILE" ]]; then
        if typeset -f rvdk_kv_load >/dev/null 2>&1; then
            local RVDK_C6_SDIO_ENABLED=""
            rvdk_kv_load "$C6_ENV_FILE" RVDK_C6_SDIO_ENABLED
            val="$RVDK_C6_SDIO_ENABLED"
        else
            val="$(awk -F= '/^RVDK_C6_SDIO_ENABLED=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$C6_ENV_FILE" 2>/dev/null || true)"
        fi
    fi
    printf '%s\n' "$val"
}

print_status() {
    local cur_state
    cur_state="$(_read_c6_enabled)"
    local state_desc="enabled (default; unconfigured)"
    if [[ "$cur_state" == "true" ]]; then
        state_desc="enabled (4-bit SDIO @ 40 MHz -> ESP32-C6)"
    elif [[ "$cur_state" == "false" ]]; then
        state_desc="disabled (low-power RMII/headless)"
    fi
    log_info "Quirk c6-sdio (waveshare/esp32-p4-wifi6):"
    printf "  • State             : %s\n" "$state_desc"
    printf "  • Config File       : %s\n" "$C6_ENV_FILE"
    printf "  • Kconfig Fragment  : %s\n" "$C6_KCONFIG_FILE"
}

if [[ "$ACTION" == "status" ]]; then
    print_status
    exit 0
fi

if [[ -z "$STAGE_DIR" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        exec sudo -E bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    else
        log_fatal "Root privileges required for on-target /etc/rvdk writes (or pass --stage-dir <dir>)."
    fi
fi

if [[ "$ACTION" == "toggle" ]]; then
    cur_en="$(_read_c6_enabled)"
    if [[ "$cur_en" == "false" ]]; then
        ACTION="enable"
    else
        ACTION="disable"
    fi
fi

rvdk_prog_init "Waveshare ESP32-P4 Quirk: converging c6-sdio (${ACTION})..."
mkdir -p "$OUT_DIR"

if [[ "$ACTION" == "enable" ]]; then
    WANT_ENV="# Managed by RVDK (boards/waveshare/esp32-p4-wifi6/quirks/c6-sdio.sh)
RVDK_BOARD=\"waveshare/esp32-p4-wifi6\"
RVDK_C6_SDIO_ENABLED=\"true\"
RVDK_C6_SDIO_TRANSPORT=\"sdio\"
RVDK_C6_SDIO_CLK_MHZ=\"40\"
RVDK_C6_SDIO_BUS_WIDTH=\"4\"
RVDK_C6_SDIO_SLAVE_TARGET=\"esp32c6\""
    WANT_KCONFIG="# Managed by RVDK (boards/waveshare/esp32-p4-wifi6/quirks/c6-sdio.sh | c6-sdio=enabled)
CONFIG_ESP_WIFI_REMOTE_ENABLED=y
CONFIG_SLAVE_IDF_TARGET_ESP32C6=y
CONFIG_ESP_HOSTED_SDIO_HOST_INTERFACE=y
CONFIG_ESP_HOSTED_SDIO_4_BIT_BUS=y
CONFIG_ESP_HOSTED_SDIO_CLOCK_FREQ_KHZ=40000"
else
    WANT_ENV="# Managed by RVDK (boards/waveshare/esp32-p4-wifi6/quirks/c6-sdio.sh)
RVDK_BOARD=\"waveshare/esp32-p4-wifi6\"
RVDK_C6_SDIO_ENABLED=\"false\"
RVDK_C6_SDIO_TRANSPORT=\"disabled\"
RVDK_C6_SDIO_CLK_MHZ=\"0\"
RVDK_C6_SDIO_BUS_WIDTH=\"0\"
RVDK_C6_SDIO_SLAVE_TARGET=\"none\""
    WANT_KCONFIG="# Managed by RVDK (boards/waveshare/esp32-p4-wifi6/quirks/c6-sdio.sh | c6-sdio=disabled)
CONFIG_ESP_WIFI_REMOTE_ENABLED=n
CONFIG_ESP_HOSTED_SDIO_HOST_INTERFACE=n"
fi

CHANGED="false"
if [[ "$FORCE_APPLY" == "true" ]] || [[ ! -f "$C6_ENV_FILE" || -L "$C6_ENV_FILE" ]] || ! printf '%s\n' "$WANT_ENV" | cmp -s - "$C6_ENV_FILE" 2>/dev/null; then
    printf '%s\n' "$WANT_ENV" | rvdk_atomic_write "$C6_ENV_FILE" 0644
    CHANGED="true"
fi
if [[ "$FORCE_APPLY" == "true" ]] || [[ ! -f "$C6_KCONFIG_FILE" || -L "$C6_KCONFIG_FILE" ]] || ! printf '%s\n' "$WANT_KCONFIG" | cmp -s - "$C6_KCONFIG_FILE" 2>/dev/null; then
    printf '%s\n' "$WANT_KCONFIG" | rvdk_atomic_write "$C6_KCONFIG_FILE" 0644
    CHANGED="true"
fi

if [[ "$CHANGED" == "true" ]]; then
    _c6_ok "ESP32-C6 SDIO co-processor transport set to '${ACTION}' (${C6_ENV_FILE})"
else
    _c6_skip "ESP32-C6 SDIO co-processor transport already '${ACTION}' (${C6_ENV_FILE})"
fi

rvdk_prog 100 "Quirk c6-sdio (${ACTION}) complete"
