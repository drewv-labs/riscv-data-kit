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

# @RVDK_INLINE_LIBS: common apt progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:P550-DEEPTUNE]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_atomic_write() {
            local _dst="$1" _mode="${2:-0644}" _own="${3:-}" _tmp
            mkdir -p "$(dirname "$_dst")"
            _tmp="$(mktemp "$(dirname "$_dst")/.$(basename "$_dst").rvdk.XXXXXX")"
            cat > "$_tmp"
            chmod "$_mode" "$_tmp"
            [[ -n "$_own" ]] && chown "$_own" "$_tmp"
            mv -f "$_tmp" "$_dst"
        }
        rvdk_sudo_preserve() {
            [[ $# -gt 0 ]] || return 1
            local -a _allow=(
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
if [[ -z "${_RVDK_APT_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/apt.sh" ]]; then
        # shellcheck source=lib/apt.sh
        source "${_REPO_ROOT}/lib/apt.sh"
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
TUNE_REQUEST="${RVDK_TUNE:-}"
FORCE_ARG=()
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tune)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument: data | ai | iot"
            TUNE_REQUEST="$2"
            shift 2
            ;;
        --tune=*)
            TUNE_REQUEST="${1#*=}"
            shift
            ;;
        data|ai|ml|edge-ai|edge-ml|iot|edge-iot|sensor|mcu)
            TUNE_REQUEST="$1"
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
Usage: sudo rvdk deeptune [--tune <data|ai|iot>] [status] [--force] [--noprogbar]
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
HDMI_STATE_FILE="${RVDK_P550_HDMI_STATE_FILE:-/run/rvdk-p550-hdmi.state}"
PLAT_DRV_BASE="${RVDK_P550_PLAT_DRV_BASE:-/sys/bus/platform/drivers}"

_p550_hdmi_active() {
    [[ -e "${PLAT_DRV_BASE}/dw-hdmi-eswin/502a0000.hdmi" ]] \
        || [[ -e "${PLAT_DRV_BASE}/es-dc/502c0000.display_control" ]] \
        || [[ -e "${PLAT_DRV_BASE}/es_drm/soc:display-subsystem" ]]
}

if [[ "$ACTION" == "status" ]]; then
    log_info "Layer 3 Board (sifive/p550):"
    [[ -n "$FUSB_QUIRK" && -f "$FUSB_QUIRK" ]] && bash "$FUSB_QUIRK" status
    [[ -n "$HDMI_QUIRK" && -f "$HDMI_QUIRK" ]] && bash "$HDMI_QUIRK" status
    exit 0
fi

if [[ -n "$TUNE_REQUEST" ]]; then
    _tune_pre="$(tr '[:upper:]' '[:lower:]' <<< "$TUNE_REQUEST")"
    case "$_tune_pre" in
        ai|ml|edge-ai|edge-ml|iot|edge-iot|sensor|mcu|data) ;;
        *) log_fatal "Invalid --tune '${_tune_pre}' (expected: data | ai | iot)" ;;
    esac
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && command -v sudo >/dev/null 2>&1; then
        _sudo_rc=0
        rvdk_sudo_preserve bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} || _sudo_rc=$?
        exit "$_sudo_rc"
    else
        log_fatal "Root privileges required. Run via 'sudo rvdk deeptune'."
    fi
fi

PREV_TUNE_RAW=""
if [[ -r /etc/rvdk/deeptune.env ]]; then
    if typeset -f rvdk_kv_load >/dev/null 2>&1; then
        RVDK_TUNE=""
        rvdk_kv_load /etc/rvdk/deeptune.env RVDK_TUNE || true
        PREV_TUNE_RAW="${RVDK_TUNE:-}"
    else
        PREV_TUNE_RAW="$(awk -F= '/^RVDK_TUNE=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' /etc/rvdk/deeptune.env 2>/dev/null || true)"
    fi
fi
if [[ -z "$TUNE_REQUEST" ]]; then
    TUNE_REQUEST="$PREV_TUNE_RAW"
fi
TUNE_REQUEST="$(tr '[:upper:]' '[:lower:]' <<< "${TUNE_REQUEST:-data}")"
PREV_TUNE_NORM="$(tr '[:upper:]' '[:lower:]' <<< "${PREV_TUNE_RAW:-}")"
case "$PREV_TUNE_NORM" in
    iot|edge-iot|sensor|mcu) PREV_TUNE_NORM="iot" ;;
esac

case "$TUNE_REQUEST" in
    ai|ml|edge-ai|edge-ml)   TUNE_MODE="ai";   TUNE_LABEL="ai" ;;
    iot|edge-iot|sensor|mcu) TUNE_MODE="iot";  TUNE_LABEL="iot" ;;
    data)                    TUNE_MODE="data"; TUNE_LABEL="data" ;;
    *)                       log_fatal "Invalid --tune '${TUNE_REQUEST}' (expected: data | ai | iot)" ;;
esac

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

if [[ "$TUNE_MODE" == "iot" ]]; then
    rvdk_prog_init "P550 Carrier DeepTune (--tune iot): suppressing fusb303b & HDMI..."
    log_info "Converging SiFive Premier P550 Carrier DeepTune (--tune iot | low-power headless)..."
else
    rvdk_prog_init "P550 Carrier DeepTune: suppressing HF106C front-panel USB-C IRQ..."
    log_info "Converging SiFive Premier P550 Carrier DeepTune (HDMI crashcart preserved)..."
fi

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

if [[ -n "$HDMI_QUIRK" && -f "$HDMI_QUIRK" ]]; then
    if [[ -L "$HDMI_STATE_FILE" ]]; then
        log_fatal "Refusing symlink HDMI state file: ${HDMI_STATE_FILE}"
    fi
    _hdmi_state=""
    if [[ -f "$HDMI_STATE_FILE" ]]; then
        _hdmi_state="$(tr -d '[:space:]' < "$HDMI_STATE_FILE" 2>/dev/null || true)"
    fi

    if [[ "$TUNE_MODE" == "iot" ]]; then
        if [[ "$_hdmi_state" == "off" ]] && ! _p550_hdmi_active; then
            log_skip "SiFive P550 HDMI/Display subsystem already disabled (--tune iot)"
        else
            bash "$HDMI_QUIRK" off ${FORCE_ARG[@]+"${FORCE_ARG[@]}"}
            printf 'off\n' | rvdk_atomic_write "$HDMI_STATE_FILE" 0644
            log_ok "Disabled SiFive P550 HDMI/Display subsystem (--tune iot; restore via '--tune data' or 'sudo rvdk quirk hdmi on')"
        fi
    else
        if [[ "$_hdmi_state" == "off" ]] || [[ -z "$_hdmi_state" && "$PREV_TUNE_NORM" == "iot" ]]; then
            bash "$HDMI_QUIRK" on ${FORCE_ARG[@]+"${FORCE_ARG[@]}"}
            printf 'on\n' | rvdk_atomic_write "$HDMI_STATE_FILE" 0644
            log_ok "Restored SiFive P550 HDMI/Display subsystem (crashcart TTY; --tune ${TUNE_LABEL})"
        else
            log_skip "SiFive P550 HDMI crashcart state already preserved (--tune ${TUNE_LABEL})"
        fi
    fi
fi

rvdk_prog 85 "P550 Carrier DeepTune: checking PWM fancontrol config..."
export DEBIAN_FRONTEND=noninteractive
if command -v apt-cache >/dev/null 2>&1 && apt-cache show fancontrol-config-p550-premier >/dev/null 2>&1; then
    if ! dpkg -s fancontrol-config-p550-premier >/dev/null 2>&1; then
        if typeset -f rvdk_apt_ensure >/dev/null 2>&1; then
            rvdk_apt_ensure fancontrol-config-p550-premier
        else
            apt-get install -y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" fancontrol-config-p550-premier
        fi
        log_ok "Installed fancontrol-config-p550-premier"
    else
        log_skip "fancontrol-config-p550-premier already installed"
    fi
fi

rvdk_prog 100 "P550 Carrier DeepTune (--tune ${TUNE_LABEL}) complete"
