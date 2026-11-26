#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Layer 3: Orange Pi RV2 (SpacemiT K1 / Ky X1) DeepTune
# Path: riscv-data-kit/boards/orangepi/rv2/deeptune.sh
#
# Description:
#   Board-specific Layer 3 DeepTune adapter for Orange Pi RV2:
#     • Suppresses forced SDIO Wi-Fi module autoload (`bcmdhd`,
#       `dhd_static_buf`) in `/etc/modules-load.d/orangepirv2.conf` when the
#       primary NIC is wired (`data` / `ai`), with first-touch backup via
#       `rvdk_backup_file` and symmetric restoration in `--tune iot`.
#     • Orders SpacemiT K1 Layer 2 systemd units (`spacemit-k1-irq-affinity`
#       and `spacemit-k1-cpufreq-iot`) after `orangepi-hardware-optimize.service`
#       via systemd drop-ins under `/etc/systemd/system/*.service.d/`.
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
elif [[ -d "/usr/local/share/rvdk/engine/boards/orangepi/rv2" ]]; then
    _SCRIPT_DIR="/usr/local/share/rvdk/engine/boards/orangepi/rv2"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

# @RVDK_INLINE_LIBS: common kit progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:RV2-DEEPTUNE]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_kv_load() { :; }
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

rvdk_log_init "RVDK:RV2-DEEPTUNE"

ACTION="apply"
TUNE_REQUEST="${RVDK_TUNE:-}"
FORCE_BOARD="false"
ORIG_ARGS=("$@")

usage() {
    cat <<'EOF'
Usage: sudo rvdk deeptune [--tune <data|ai|iot>] [status] [--force] [--noprogbar]
Layer 3 Board script: boards/orangepi/rv2/deeptune.sh
EOF
}

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
            FORCE_BOARD="true"
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

OPI_MOD_LOAD="/etc/modules-load.d/orangepirv2.conf"
IRQ_DROPIN_DIR="/etc/systemd/system/spacemit-k1-irq-affinity.service.d"
IRQ_DROPIN="${IRQ_DROPIN_DIR}/90-rvdk-orangepi-rv2.conf"
IOT_DROPIN_DIR="/etc/systemd/system/spacemit-k1-cpufreq-iot.service.d"
IOT_DROPIN="${IOT_DROPIN_DIR}/90-rvdk-orangepi-rv2.conf"

_rv2_validate_nic() {
    local nic="${1:-}"
    local label="${2:-PRIMARY_NIC}"
    local nic_re='^[a-zA-Z0-9._-]{1,15}$'
    if [[ ! "$nic" =~ $nic_re || "$nic" == "." || "$nic" == ".." ]]; then
        log_fatal "Invalid ${label} '${nic}' (expected Linux interface name matching ^[a-zA-Z0-9._-]{1,15}$)."
    fi
}

_rv2_backup_file() {
    local src_path="${1:-}"
    local category="${2:-deeptune}"
    if typeset -f rvdk_backup_file >/dev/null 2>&1; then
        rvdk_backup_file "$src_path" "$category"
        return $?
    fi
    [[ "$src_path" == /* && -f "$src_path" && ! -L "$src_path" ]] || return 1
    [[ "$src_path" != *$'\n'* && "$src_path" != *$'\r'* && "$src_path" != *".."* ]] || return 1
    [[ "$category" =~ ^[a-z0-9_-]+$ ]] || return 1

    local backup_root="${RVDK_BACKUP_ROOT:-${RVDK_STATE_DIR:-/var/lib/rvdk}/backups}"
    local encoded="${src_path#/}"
    while [[ "$encoded" == /* ]]; do
        encoded="${encoded#/}"
    done
    encoded="${encoded//\//__}"
    local cat_dir="${backup_root}/${category}"
    local orig_path="${cat_dir}/${encoded}.orig"
    local sidecar_path="${cat_dir}/${encoded}.path"

    if [[ -L "$backup_root" || -L "$cat_dir" ]]; then
        log_fatal "Refusing symlink backup directory: ${cat_dir}"
    fi
    install -d -m 0755 "$cat_dir"
    if [[ ! -f "$orig_path" && ! -L "$orig_path" ]]; then
        cp -a "$src_path" "$orig_path"
    fi
    if [[ ! -f "$sidecar_path" && ! -L "$sidecar_path" ]]; then
        printf '%s\n' "$src_path" | rvdk_atomic_write "$sidecar_path" 0644
    fi
}

print_status() {
    local mod_state="absent"
    if [[ -L "$OPI_MOD_LOAD" ]]; then
        mod_state="symlink (skipped)"
    elif [[ -f "$OPI_MOD_LOAD" ]]; then
        if grep -Eq '^[[:space:]]*#[[:space:]]*(bcmdhd|dhd_static_buf)([[:space:]].*)?[[:space:]]+#[[:space:]]*disabled by RVDK (orangepi/rv2|spacemit/k1) deeptune[[:space:]]*$' "$OPI_MOD_LOAD" 2>/dev/null; then
            mod_state="suppressed (${OPI_MOD_LOAD})"
        elif grep -Eq '^[[:space:]]*(bcmdhd|dhd_static_buf)([[:space:]]|$)' "$OPI_MOD_LOAD" 2>/dev/null; then
            mod_state="enabled (${OPI_MOD_LOAD})"
        else
            mod_state="present (${OPI_MOD_LOAD})"
        fi
    fi

    local irq_dropin_state="absent"
    [[ -f "$IRQ_DROPIN" && ! -L "$IRQ_DROPIN" ]] && irq_dropin_state="installed (${IRQ_DROPIN})"
    local iot_dropin_state="absent"
    [[ -f "$IOT_DROPIN" && ! -L "$IOT_DROPIN" ]] && iot_dropin_state="installed (${IOT_DROPIN})"

    log_info "Layer 3 Board (orangepi/rv2):"
    printf "  • SDIO Wi-Fi Autoload: %s\n" "$mod_state"
    printf "  • IRQ Ordering Drop-in: %s\n" "$irq_dropin_state"
    printf "  • IoT Ordering Drop-in: %s\n" "$iot_dropin_state"
}

if [[ "$ACTION" == "status" ]]; then
    print_status
    exit 0
fi

if [[ -n "$TUNE_REQUEST" ]]; then
    _tune_pre="$(tr '[:upper:]' '[:lower:]' <<< "$TUNE_REQUEST")"
    case "$_tune_pre" in
        ai|ml|edge-ai|edge-ml|iot|edge-iot|sensor|mcu|data) ;;
        *) log_fatal "Invalid --tune '${_tune_pre}' (expected: data | ai | iot)" ;;
    esac
fi

[[ -n "${RVDK_PRIMARY_NIC:-}" ]] && _rv2_validate_nic "$RVDK_PRIMARY_NIC" "RVDK_PRIMARY_NIC"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && command -v sudo >/dev/null 2>&1; then
        _sudo_rc=0
        rvdk_sudo_preserve bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} || _sudo_rc=$?
        exit "$_sudo_rc"
    else
        log_fatal "Root privileges required. Run via 'sudo rvdk deeptune'."
    fi
fi

typeset -f rvdk_kit_resolve >/dev/null 2>&1 && rvdk_kit_resolve

DT_MODEL="${RVDK_DT_MODEL:-Unknown}"
if [[ "$DT_MODEL" == "Unknown" && -r /proc/device-tree/model ]]; then
    DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
fi
DT_MODEL_LC="$(tr '[:upper:]' '[:lower:]' <<< "$DT_MODEL")"

if [[ "$FORCE_BOARD" != "true" && "${RVDK_BOARD:-}" != "orangepi/rv2" ]]; then
    case "$DT_MODEL_LC" in
        *"orangepi-rv2"*|*"orangepi rv2"*|*"orange pi rv2"*) ;;
        *) log_fatal "Target '${DT_MODEL}' is not an Orange Pi RV2 (pass --force to override)." ;;
    esac
fi

if [[ -z "$TUNE_REQUEST" && -r /etc/rvdk/deeptune.env ]]; then
    if typeset -f rvdk_kv_load >/dev/null 2>&1; then
        RVDK_TUNE=""
        rvdk_kv_load /etc/rvdk/deeptune.env RVDK_TUNE || true
        TUNE_REQUEST="${RVDK_TUNE:-}"
    else
        TUNE_REQUEST="$(awk -F= '/^RVDK_TUNE=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' /etc/rvdk/deeptune.env 2>/dev/null || true)"
    fi
fi
TUNE_REQUEST="$(tr '[:upper:]' '[:lower:]' <<< "${TUNE_REQUEST:-data}")"

case "$TUNE_REQUEST" in
    ai|ml|edge-ai|edge-ml)   TUNE_MODE="ai";   TUNE_LABEL="ai" ;;
    iot|edge-iot|sensor|mcu) TUNE_MODE="iot";  TUNE_LABEL="iot" ;;
    data)                    TUNE_MODE="data"; TUNE_LABEL="data" ;;
    *)                       log_fatal "Invalid --tune '${TUNE_REQUEST}' (expected: data | ai | iot)" ;;
esac

if [[ "${RVDK_OS_ID:-}" == "openwrt" || -f /etc/openwrt_release ]]; then
    log_skip "Non-systemd rootfs (${RVDK_OS_ID:-openwrt}); skipping Orange Pi RV2 board DeepTune"
    exit 0
fi

PRIMARY_NIC="${RVDK_PRIMARY_NIC:-}"
if [[ -z "$PRIMARY_NIC" ]] && typeset -f rvdk_detect_primary_nic >/dev/null 2>&1; then
    PRIMARY_NIC="$(rvdk_detect_primary_nic)"
fi
if [[ -z "$PRIMARY_NIC" ]] && command -v ip >/dev/null 2>&1; then
    PRIMARY_NIC="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
fi
[[ -z "$PRIMARY_NIC" ]] && PRIMARY_NIC="end0"
_rv2_validate_nic "$PRIMARY_NIC" "PRIMARY_NIC"

PRIMARY_IS_WIFI="false"
if [[ "$PRIMARY_NIC" == wl* || -d "/sys/class/net/${PRIMARY_NIC}/wireless" ]]; then
    PRIMARY_IS_WIFI="true"
fi

rvdk_prog_init "Orange Pi RV2 DeepTune (--tune ${TUNE_LABEL}): converging board modules & systemd order..."
log_info "Converging Orange Pi RV2 Board DeepTune (--tune ${TUNE_LABEL} | NIC=${PRIMARY_NIC})..."

# 1. Manage Orange Pi RV2 SDIO Wi-Fi autoload (/etc/modules-load.d/orangepirv2.conf)
rvdk_prog 40 "Orange Pi RV2 DeepTune: checking ${OPI_MOD_LOAD}..."
if [[ -L "$OPI_MOD_LOAD" ]]; then
    log_fatal "Refusing symlink module autoload config: ${OPI_MOD_LOAD}"
fi

RESTORED_WIFI_AUTOLOAD="false"
if [[ "$TUNE_MODE" != "iot" ]]; then
    if [[ "$PRIMARY_IS_WIFI" == "true" ]]; then
        log_skip "Primary NIC '${PRIMARY_NIC}' is wireless; preserving ${OPI_MOD_LOAD}"
    elif [[ -f "$OPI_MOD_LOAD" ]] && grep -Eq '^[[:space:]]*(bcmdhd|dhd_static_buf)([[:space:]]|$)' "$OPI_MOD_LOAD" 2>/dev/null; then
        _rv2_backup_file "$OPI_MOD_LOAD" "deeptune"
        sed -E 's/^[[:space:]]*(bcmdhd|dhd_static_buf)([[:space:]].*)?$/# \1\2 # disabled by RVDK orangepi\/rv2 deeptune/' "$OPI_MOD_LOAD" \
            | rvdk_atomic_write "$OPI_MOD_LOAD" 0644
        log_ok "Disabled forced SDIO Wi-Fi module autoload in ${OPI_MOD_LOAD}"
    else
        log_skip "Orange Pi RV2 SDIO Wi-Fi autoload (${OPI_MOD_LOAD}) already converged"
    fi
else
    if [[ -f "$OPI_MOD_LOAD" ]] && grep -Eq '^[[:space:]]*#[[:space:]]*(bcmdhd|dhd_static_buf)([[:space:]].*)?[[:space:]]+#[[:space:]]*disabled by RVDK (orangepi/rv2|spacemit/k1) deeptune[[:space:]]*$' "$OPI_MOD_LOAD" 2>/dev/null; then
        _rv2_backup_file "$OPI_MOD_LOAD" "deeptune"
        awk '
            /^[[:space:]]*#[[:space:]]*(bcmdhd|dhd_static_buf)([[:space:]].*)?[[:space:]]+#[[:space:]]*disabled by RVDK (orangepi\/rv2|spacemit\/k1) deeptune[[:space:]]*$/ {
                sub(/^[[:space:]]*#[[:space:]]*/, "")
                sub(/[[:space:]]+#[[:space:]]*disabled by RVDK (orangepi\/rv2|spacemit\/k1) deeptune[[:space:]]*$/, "")
            }
            { print }
        ' "$OPI_MOD_LOAD" | rvdk_atomic_write "$OPI_MOD_LOAD" 0644
        RESTORED_WIFI_AUTOLOAD="true"
        log_ok "Restored SDIO Wi-Fi module autoload in ${OPI_MOD_LOAD} (--tune iot)"
    else
        log_skip "Orange Pi RV2 SDIO Wi-Fi autoload (${OPI_MOD_LOAD}) already converged"
    fi
fi

if [[ "$TUNE_MODE" == "iot" && "$RESTORED_WIFI_AUTOLOAD" == "true" ]]; then
    for wifi_mod in dhd_static_buf bcmdhd; do
        if ! awk -v mod="$wifi_mod" '$1 == mod { found=1 } END { exit !found }' /proc/modules 2>/dev/null; then
            if ! grep -Eqs "^blacklist ${wifi_mod}\$" /etc/modprobe.d/*.conf 2>/dev/null; then
                if modinfo "$wifi_mod" >/dev/null 2>&1 && modprobe "$wifi_mod" 2>/dev/null; then
                    log_ok "Reloaded SDIO Wi-Fi module (${wifi_mod}) live for '${TUNE_LABEL}' tune"
                fi
            fi
        fi
    done
fi

# 2. Order K1 SoC systemd units after vendor orangepi-hardware-optimize.service
rvdk_prog 80 "Orange Pi RV2 DeepTune: converging orangepi-hardware-optimize.service ordering..."
if ! command -v systemctl >/dev/null 2>&1; then
    log_skip "systemd absent; skipping orangepi-hardware-optimize.service ordering drop-ins"
    rvdk_prog 100 "Orange Pi RV2 DeepTune (--tune ${TUNE_LABEL}) complete"
    exit 0
fi

for _dpath in "$IRQ_DROPIN_DIR" "$IRQ_DROPIN" "$IOT_DROPIN_DIR" "$IOT_DROPIN"; do
    [[ -L "$_dpath" ]] && log_fatal "Refusing symlink systemd drop-in path: ${_dpath}"
done

WANT_OPI_IRQ_DROPIN="# Managed by RVDK (boards/orangepi/rv2/deeptune.sh)
[Unit]
After=orangepi-hardware-optimize.service"

WANT_OPI_IOT_DROPIN="# Managed by RVDK (boards/orangepi/rv2/deeptune.sh | tune=iot)
[Unit]
After=orangepi-hardware-optimize.service"

SYSTEMD_CHANGED="false"
if ! printf '%s\n' "$WANT_OPI_IRQ_DROPIN" | cmp -s - "$IRQ_DROPIN" 2>/dev/null; then
    printf '%s\n' "$WANT_OPI_IRQ_DROPIN" | rvdk_atomic_write "$IRQ_DROPIN" 0644
    SYSTEMD_CHANGED="true"
    log_ok "Ordered spacemit-k1-irq-affinity.service after orangepi-hardware-optimize.service (${IRQ_DROPIN})"
fi

if [[ "$TUNE_MODE" == "iot" ]]; then
    if ! printf '%s\n' "$WANT_OPI_IOT_DROPIN" | cmp -s - "$IOT_DROPIN" 2>/dev/null; then
        printf '%s\n' "$WANT_OPI_IOT_DROPIN" | rvdk_atomic_write "$IOT_DROPIN" 0644
        SYSTEMD_CHANGED="true"
        log_ok "Ordered spacemit-k1-cpufreq-iot.service after orangepi-hardware-optimize.service (${IOT_DROPIN})"
    fi
elif [[ -f "$IOT_DROPIN" ]]; then
    rm -f "$IOT_DROPIN"
    rmdir "$IOT_DROPIN_DIR" 2>/dev/null || true
    SYSTEMD_CHANGED="true"
    log_ok "Removed IoT cpufreq drop-in (${IOT_DROPIN}) for '--tune ${TUNE_LABEL}'"
fi

if [[ "$SYSTEMD_CHANGED" == "true" ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
else
    log_skip "Orange Pi RV2 systemd ordering drop-ins already converged"
fi

rvdk_prog 100 "Orange Pi RV2 DeepTune (--tune ${TUNE_LABEL}) complete"
