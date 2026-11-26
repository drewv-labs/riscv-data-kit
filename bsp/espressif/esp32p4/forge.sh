#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Espressif ESP32-P4 (2x HP RISC-V32 NoMMU + ESP32-C6 SDIO) BSP
# Path: riscv-data-kit/bsp/espressif/esp32p4/forge.sh
# Boards: Waveshare ESP32-P4-WIFI6-DEV-KIT (waveshare/esp32-p4-wifi6)
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

ORIG_ARGS=("$@")
STAGE_DIR=""

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
        log_info()  { printf "\033[1;36m[RVDK:ESP32P4]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_sanitize_locale() { export LANG="C.UTF-8" LC_ALL="C.UTF-8"; }
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

rvdk_log_init "RVDK:ESP32P4"

usage() {
    cat <<'EOF'
Usage:
  sudo rvdk bsp [--stage-dir <dir>] [--noprogbar]
  bsp/espressif/esp32p4/forge.sh [--stage-dir <dir>] [--noprogbar]

Options:
  --stage-dir <dir>   Stage provenance metadata into <dir>/config/rvdk-kit.env (host-safe)
  --noprogbar         Disable persistent bottom progress bar
  -h, --help          Show this help message and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
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
        --expose-kallsyms|--skip-upgrade|--full-upgrade|--with-vendor-repo|--keep-mirrors)
            shift
            ;;
        --debian-suite)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."
            shift 2
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

if [[ -z "$STAGE_DIR" ]]; then
    rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
fi
rvdk_sanitize_locale

if typeset -f rvdk_kit_resolve >/dev/null 2>&1; then
    rvdk_kit_resolve --no-cache --soc "espressif/esp32p4" --board "waveshare/esp32-p4-wifi6" || true
fi

rvdk_prog_init "ESP32-P4 BSP: probing toolchain & converging kit provenance..."

if [[ -n "$STAGE_DIR" ]]; then
    OUT_DIR="${STAGE_DIR%/}/config"
else
    OUT_DIR="/etc/rvdk"
fi
KIT_ENV_FILE="${OUT_DIR}/rvdk-kit.env"

probe_host_toolchains() {
    local esptool_bin="absent" idf_bin="absent" gcc_bin="absent" usb_jtag="absent"

    if command -v esptool.py >/dev/null 2>&1; then
        esptool_bin="$(command -v esptool.py)"
    elif command -v esptool >/dev/null 2>&1; then
        esptool_bin="$(command -v esptool)"
    fi
    if command -v idf.py >/dev/null 2>&1; then
        idf_bin="$(command -v idf.py)"
    fi
    if command -v riscv32-esp-elf-gcc >/dev/null 2>&1; then
        gcc_bin="$(command -v riscv32-esp-elf-gcc)"
    fi

    # Read-only USB-Serial-JTAG probe for Espressif VID:PID 303a:1001
    local usb_dev vid pid
    if [[ -d /sys/bus/usb/devices ]]; then
        for usb_dev in /sys/bus/usb/devices/*; do
            [[ -r "${usb_dev}/idVendor" && -r "${usb_dev}/idProduct" ]] || continue
            vid="$(tr -d '[:space:]' < "${usb_dev}/idVendor" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
            pid="$(tr -d '[:space:]' < "${usb_dev}/idProduct" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
            if [[ "$vid" == "303a" && "$pid" == "1001" ]]; then
                usb_jtag="present (303a:1001 via sysfs)"
                break
            fi
        done
    fi
    if [[ "$usb_jtag" == "absent" ]] && command -v lsusb >/dev/null 2>&1; then
        if lsusb 2>/dev/null | grep -qi '303a:1001'; then
            usb_jtag="present (303a:1001 via lsusb)"
        fi
    fi
    if [[ "$usb_jtag" == "absent" && "$(uname -s)" == "Darwin" ]]; then
        if command -v ioreg >/dev/null 2>&1; then
            if ioreg -p IOUSB -w0 -l 2>/dev/null | awk '
                /"idVendor" = 12346/ { v=1 }
                /"idProduct" = 4097/ { p=1 }
                v && p { found=1; exit }
                END { exit !found }
            '; then
                usb_jtag="present (303a:1001 via IOUSB)"
            fi
        fi
        if [[ "$usb_jtag" == "absent" ]]; then
            local modem_node
            for modem_node in /dev/cu.usbmodem*; do
                if [[ -e "$modem_node" ]]; then
                    usb_jtag="candidate (${modem_node})"
                    break
                fi
            done
        fi
    fi

    log_info "Toolchain Probe    : esptool=${esptool_bin} | idf.py=${idf_bin} | riscv32-esp-elf-gcc=${gcc_bin}"
    log_info "USB-Serial-JTAG    : ${usb_jtag}"
}

rvdk_prog 35 "ESP32-P4 BSP: probing read-only host toolchains & USB-JTAG..."
probe_host_toolchains

rvdk_prog 75 "ESP32-P4 BSP: writing kit provenance (${KIT_ENV_FILE})..."
mkdir -p "$OUT_DIR"

WANT_KIT_ENV="# Managed by RVDK (bsp/espressif/esp32p4/forge.sh)
RVDK_KIT_SCHEMA=\"1\"
RVDK_SOC=\"espressif/esp32p4\"
RVDK_SOC_SLUG=\"espressif-esp32p4\"
RVDK_BOARD=\"waveshare/esp32-p4-wifi6\"
RVDK_BOARD_TAG=\"p4\"
RVDK_ARCH=\"riscv32\"
RVDK_MMU=\"none\"
RVDK_CPU_HARTS=\"2\"
RVDK_STORAGE_MEDIA=\"sd\"
RVDK_SD_LABEL=\"RVDK_P4_SD\""

if [[ -f "$KIT_ENV_FILE" && ! -L "$KIT_ENV_FILE" ]] && printf '%s\n' "$WANT_KIT_ENV" | cmp -s - "$KIT_ENV_FILE" 2>/dev/null; then
    log_skip "ESP32-P4 kit provenance already converged (${KIT_ENV_FILE})"
else
    printf '%s\n' "$WANT_KIT_ENV" | rvdk_atomic_write "$KIT_ENV_FILE" 0644
    log_ok "Wrote ESP32-P4 kit provenance metadata (${KIT_ENV_FILE})"
fi

rvdk_prog 100 "ESP32-P4 BSP staging complete"
log_info "Espressif ESP32-P4 BSP complete (target=${KIT_ENV_FILE})."
