#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Layer 3: SiFive HiFive Premier P550 Carrier DeepTune
# Path: riscv-data-kit/boards/sifive/p550/deeptune.sh
#
# Description:
#   Carrier-board specific DeepTune layer for the SiFive HiFive Premier P550
#   (HF106C Mini-DTX carrier):
#     • Suppresses the unpopulated internal J2 front-panel Type-E USB-C
#       controller (`fusb303b`, `i2c-3/3-0021`) so `irq/*-fusb303b_` never
#       burns CPU0 cycles or injects IRQ jitter.
#     • Preserves HDMI crashcart TTY (`rvdk quirk hdmi off` for runtime toggle),
#       STM32 carrier BMC (`es-bmcd`), PWM heatsink fan (`fancontrol`), and
#       onboard carrier telemetry (`pac1934`, `ina2xx`).
# ==============================================================================
set -Eeuo pipefail

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [[ -d "/usr/local/share/rvdk/engine/boards/sifive/p550" ]]; then
    _SCRIPT_DIR="/usr/local/share/rvdk/engine/boards/sifive/p550"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

# @RVDK_INLINE_LIBS: common progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:P550-DEEPTUNE]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
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

rvdk_log_init "RVDK:P550-DEEPTUNE"

ACTION="apply"
FORCE_ARG=()
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tune)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument: data | ai"
            shift 2
            ;;
        --tune=*|data|ai|ml)
            shift
            ;;
        status|--status)
            ACTION="status"
            shift
            ;;
        --force)
            FORCE_ARG=("--force")
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
            cat <<'EOF'
Usage: sudo rvdk deeptune [--tune <data|ai>] [status] [--force] [--noprogbar]
Layer 3 Board script: boards/sifive/p550/deeptune.sh
EOF
            exit 0
            ;;
        *)
            log_fatal "Unknown argument: $1 (try --help)"
            ;;
    esac
done

FUSB_QUIRK="${_SCRIPT_DIR:+$_SCRIPT_DIR/quirks/fusb.sh}"
HDMI_QUIRK="${_SCRIPT_DIR:+$_SCRIPT_DIR/quirks/hdmi.sh}"

if [[ "$ACTION" == "status" ]]; then
    log_info "Layer 3 Board (sifive/p550):"
    [[ -n "$FUSB_QUIRK" && -f "$FUSB_QUIRK" ]] && bash "$FUSB_QUIRK" status
    [[ -n "$HDMI_QUIRK" && -f "$HDMI_QUIRK" ]] && bash "$HDMI_QUIRK" status
    exit 0
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        exec sudo -E bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    else
        log_fatal "Root privileges required. Run via 'sudo rvdk deeptune'."
    fi
fi

_p550_fusb_converged() {
    local modprobe_conf="/etc/modprobe.d/90-rvdk-p550-fusb303b.conf"
    local d
    [[ -f "$modprobe_conf" && ! -L "$modprobe_conf" ]] || return 1
    grep -qs '^blacklist fusb303b$' "$modprobe_conf" 2>/dev/null || return 1
    if awk '$1 == "fusb303b" { found=1 } END { exit !found }' /proc/modules 2>/dev/null; then
        return 1
    fi
    if [[ -d /sys/bus/i2c/drivers/fusb303b ]]; then
        for d in /sys/bus/i2c/drivers/fusb303b/[0-9]*-*; do
            [[ -e "$d" ]] && return 1
        done
    fi
    if ps -eo comm 2>/dev/null | awk '$1 ~ /^irq\/[0-9]+-fusb303/ { found=1 } END { exit !found }'; then
        return 1
    fi
    return 0
}

rvdk_prog_init "P550 Carrier DeepTune: suppressing HF106C front-panel USB-C IRQ..."
log_info "Converging SiFive Premier P550 Carrier DeepTune (HDMI crashcart preserved)..."

if [[ -n "$FUSB_QUIRK" && -f "$FUSB_QUIRK" ]]; then
    FUSB_WAS_CONVERGED="false"
    if _p550_fusb_converged; then
        FUSB_WAS_CONVERGED="true"
    fi
    bash "$FUSB_QUIRK" off --quiet ${FORCE_ARG[@]+"${FORCE_ARG[@]}"}
    if [[ "$FUSB_WAS_CONVERGED" == "true" ]]; then
        log_skip "HF106C front-panel Type-C controller (fusb303b) already disabled & blacklisted"
    else
        log_ok "Disabled & blacklisted HF106C front-panel Type-C controller (fusb303b; restore via 'sudo rvdk quirk fusb on')"
    fi
fi

rvdk_prog 100 "P550 Carrier DeepTune complete"
