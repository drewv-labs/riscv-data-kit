#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Layer 2: ESWIN EIC7700X Silicon SoC DeepTune
# Path: riscv-data-kit/bsp/eswin/eic7700x/deeptune.sh
#
# Description:
#   Idempotent, reversible silicon-level deep-tuning shared across all ESWIN
#   EIC7700X RISC-V boards (SiFive HiFive Premier P550, Milk-V Megrez, Pine64
#   StarPro64):
#     • `data` tune (default):
#       Unloads & blacklists the PowerVR BXM-4-64 GPU/compute driver (`pvrsrvkm`,
#       ~2.7 MB) alongside unused EIC7700X I2S/ES8328/HDMI ALSA codec modules.
#     • `ai` tune:
#       Suppresses unused ALSA audio codec modules while removing `pvrsrvkm` from
#       the blacklist and reloading it live for OpenCL / edge AI compute.
#     • `iot` tune:
#       Disables heavy GPU/display modules (`pvrsrvkm`, `es_drm`, `dw_hdmi_eswin`,
#       `dw_hdmi_cec`, ALSA/HDMI codecs) to minimize quiescent power & thermal
#       floor, preserves wireless/SDIO/I2C/SPI/UART kernel modules, and selects
#       `schedutil` cpufreq governor (`ondemand` -> `performance` fallback).
#     • SiFive P550 4-Hart PLIC Interrupt Affinity (`eic7700x-irq-affinity.service`):
#       Spreads high-rate xHCI USB 3.2 and primary GbE interrupts off CPU0 across
#       harts 1..3 (`xhci-hcd:usb3` -> CPU1, primary NIC -> CPU2, `xhci-hcd:usb1` -> CPU3).
#
#   Note:
#     • Universal headless OS daemon/package/THP/sysctl tuning lives in Layer 1:
#       `os/deeptune.sh`
#     • Carrier-specific quirks (e.g. SiFive HF106C `fusb303b` & `hdmi`) live in
#       Layer 3: `boards/sifive/p550/deeptune.sh` & `boards/sifive/p550/quirks/`
# ==============================================================================
set -Eeuo pipefail

LEGACY_MODPROBE="/etc/modprobe.d/90-rvdk-p550-deeptune.conf"
MODPROBE_SOC="/etc/modprobe.d/90-rvdk-eic7700x-deeptune.conf"
IRQ_SCRIPT="/usr/local/sbin/rvdk-eic7700x-irq-tune"
IRQ_UNIT="/etc/systemd/system/eic7700x-irq-affinity.service"
PERF_GOV_UNIT="/etc/systemd/system/eic7700x-cpufreq-performance.service"
IOT_GOV_UNIT="/etc/systemd/system/eic7700x-cpufreq-iot.service"

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
        log_info()  { printf "\033[1;36m[RVDK:EIC7700X-DEEPTUNE]\033[0m %s\n" "$1"; }
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

rvdk_log_init "RVDK:EIC7700X-DEEPTUNE"

ACTION="apply"
TUNE_REQUEST="${RVDK_TUNE:-}"
FORCE_SOC="false"
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
            FORCE_SOC="true"
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
Layer 2 SoC script: bsp/eswin/eic7700x/deeptune.sh
EOF
            exit 0
            ;;
        *)
            log_fatal "Unknown argument: $1 (try --help)"
            ;;
    esac
done

if [[ -n "$TUNE_REQUEST" ]]; then
    _tune_pre="$(tr '[:upper:]' '[:lower:]' <<< "$TUNE_REQUEST")"
    case "$_tune_pre" in
        ai|ml|edge-ai|edge-ml|iot|edge-iot|sensor|mcu|data) ;;
        *) log_fatal "Invalid --tune '${_tune_pre}' (expected: data | ai | iot)" ;;
    esac
fi

_eic_validate_nic() {
    local nic="${1:-}"
    local label="${2:-PRIMARY_NIC}"
    local nic_re='^[a-zA-Z0-9._-]{1,15}$'
    if [[ ! "$nic" =~ $nic_re || "$nic" == "." || "$nic" == ".." ]]; then
        log_fatal "Invalid ${label} '${nic}' (expected Linux interface name matching ^[a-zA-Z0-9._-]{1,15}$)."
    fi
}

if [[ "$ACTION" != "status" ]]; then
    [[ -n "${RVDK_PRIMARY_NIC:-}" ]] && _eic_validate_nic "$RVDK_PRIMARY_NIC" "RVDK_PRIMARY_NIC"
    [[ -n "${RVDK_SECONDARY_NIC:-}" ]] && _eic_validate_nic "$RVDK_SECONDARY_NIC" "RVDK_SECONDARY_NIC"
    [[ -n "${SECONDARY_NIC:-}" ]] && _eic_validate_nic "$SECONDARY_NIC" "SECONDARY_NIC"
    if [[ -n "${SECONDARY_NIC:-}" && -z "${RVDK_SECONDARY_NIC:-}" ]]; then
        export RVDK_SECONDARY_NIC="$SECONDARY_NIC"
    fi
fi

if [[ "$ACTION" != "status" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && command -v sudo >/dev/null 2>&1; then
        _sudo_rc=0
        rvdk_sudo_preserve bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} || _sudo_rc=$?
        exit "$_sudo_rc"
    else
        log_fatal "Root privileges required. Pipe into 'sudo bash' or run via 'sudo rvdk deeptune'."
    fi
fi

typeset -f rvdk_kit_resolve >/dev/null 2>&1 && rvdk_kit_resolve

DT_MODEL="${RVDK_DT_MODEL:-Unknown}"
if [[ "$DT_MODEL" == "Unknown" && -r /proc/device-tree/model ]]; then
    DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
fi

if [[ "$FORCE_SOC" != "true" && "${RVDK_SOC:-}" != "eswin/eic7700x" ]]; then
    case "$DT_MODEL" in
        *"Premier P550"*|*"EIC7700"*|*"Megrez"*|*"StarPro64"*) ;;
        *) log_fatal "Target '${DT_MODEL}' is not an ESWIN EIC7700X SoC (pass --force to override)." ;;
    esac
fi

print_status() {
    local gpu_mod="unloaded"
    awk '$1 == "pvrsrvkm" { found=1 } END { exit !found }' /proc/modules 2>/dev/null && gpu_mod="loaded (pvrsrvkm)"
    if grep -qs '^blacklist pvrsrvkm$' "$MODPROBE_SOC" "$LEGACY_MODPROBE" 2>/dev/null; then
        gpu_mod+=" [boot: blacklisted]"
    else
        gpu_mod+=" [boot: enabled]"
    fi

    local irq_svc="inactive"
    systemctl is-enabled --quiet eic7700x-irq-affinity.service 2>/dev/null && irq_svc="enabled"

    local cpufreq_gov="firmware-fixed"
    if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        cpufreq_gov="$(tr -d '[:space:]' < /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")"
    fi

    log_info "Layer 2 SoC (eswin/eic7700x):"
    printf "  • PowerVR GPU/AI    : %s\n" "$gpu_mod"
    printf "  • CPUFreq Governor  : %s\n" "$cpufreq_gov"
    printf "  • PLIC IRQ Balancer : %s (%s)\n" "$irq_svc" "$IRQ_UNIT"
}

if [[ "$ACTION" == "status" ]]; then
    print_status
    exit 0
fi

if [[ -z "$TUNE_REQUEST" && -r /etc/rvdk/deeptune.env ]]; then
    if typeset -f rvdk_kv_load >/dev/null 2>&1; then
        RVDK_TUNE=""
        rvdk_kv_load /etc/rvdk/deeptune.env RVDK_TUNE
        TUNE_REQUEST="$RVDK_TUNE"
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

PRIMARY_NIC="${RVDK_PRIMARY_NIC:-}"
if [[ -z "$PRIMARY_NIC" ]] && typeset -f rvdk_detect_primary_nic >/dev/null 2>&1; then
    PRIMARY_NIC="$(rvdk_detect_primary_nic)"
fi
if [[ -z "$PRIMARY_NIC" ]] && command -v ip >/dev/null 2>&1; then
    PRIMARY_NIC="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
    if [[ -z "$PRIMARY_NIC" ]]; then
        PRIMARY_NIC="$(ip route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' || true)"
    fi
fi
[[ -z "$PRIMARY_NIC" ]] && PRIMARY_NIC="end0"
_eic_validate_nic "$PRIMARY_NIC" "PRIMARY_NIC"

SECONDARY_NIC="${RVDK_SECONDARY_NIC:-${SECONDARY_NIC:-}}"
if [[ -n "$SECONDARY_NIC" ]]; then
    _eic_validate_nic "$SECONDARY_NIC" "SECONDARY_NIC"
fi

rvdk_prog_init "EIC7700X SoC DeepTune (--tune ${TUNE_LABEL}): converging accelerators & IRQs..."
log_info "Converging ESWIN EIC7700X Silicon DeepTune (--tune ${TUNE_LABEL} | mode=${TUNE_MODE})..."

# ==============================================================================
# 1. EIC7700X ALSA CODEC BLACKLIST & REVERSIBLE POWERVR GPU (`pvrsrvkm`)
# ==============================================================================
rvdk_prog 35 "EIC7700X DeepTune: converging SoC audio & PowerVR GPU modules (--tune ${TUNE_LABEL})..."

if [[ -f "$LEGACY_MODPROBE" ]]; then
    rm -f "$LEGACY_MODPROBE"
fi

if [[ -L /etc/systemd/system/eic7700x-thp-tune.service || -f /etc/systemd/system/eic7700x-thp-tune.service ]]; then
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now eic7700x-thp-tune.service >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/eic7700x-thp-tune.service
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    log_ok "Retired legacy eic7700x-thp-tune.service (superseded by rvdk-thp-tune.service)"
fi

SOC_AUDIO_MODS=(
    esw_es8328_codec
    snd_soc_hdmi_codec
    snd_soc_audio_graph_card
    snd_soc_simple_card_utils
    snd_soc_i2s
    snd_pcm_dmaengine
    snd_soc_core
    snd_pcm
    snd_timer
    snd
    soundcore
)

TARGET_MODS=("${SOC_AUDIO_MODS[@]}")
if [[ "$TUNE_MODE" == "data" ]]; then
    TARGET_MODS=(pvrsrvkm "${TARGET_MODS[@]}")
elif [[ "$TUNE_MODE" == "iot" ]]; then
    TARGET_MODS=(pvrsrvkm es_drm dw_hdmi_eswin dw_hdmi_cec "${TARGET_MODS[@]}")
fi

_eic_modprobe_desc=""
if [[ "$TUNE_MODE" == "data" ]]; then
    _eic_modprobe_desc=" and PowerVR BXM-4-64 GPU (pvrsrvkm)"
elif [[ "$TUNE_MODE" == "iot" ]]; then
    _eic_modprobe_desc=", PowerVR GPU (pvrsrvkm), and HDMI/DRM"
fi
WANT_MODPROBE="$(printf '# Managed by RVDK (bsp/eswin/eic7700x/deeptune.sh | tune=%s)\n# Suppresses EIC7700X ALSA codec%s modules.' "$TUNE_LABEL" "$_eic_modprobe_desc")"
for m in "${TARGET_MODS[@]}"; do
    WANT_MODPROBE+=$'\n'"blacklist ${m}"
done

if ! printf "%s\n" "$WANT_MODPROBE" | cmp -s - "$MODPROBE_SOC" 2>/dev/null; then
    printf "%s\n" "$WANT_MODPROBE" | rvdk_atomic_write "$MODPROBE_SOC" 0644
    log_ok "Updated EIC7700X kernel module policy (--tune ${TUNE_LABEL}) in ${MODPROBE_SOC}"
else
    log_skip "EIC7700X kernel module policy (${MODPROBE_SOC}) already converged for '${TUNE_LABEL}'"
fi

UNLOADED_MODS=()
for m in "${TARGET_MODS[@]}"; do
    if awk -v mod="$m" '$1 == mod { found=1 } END { exit !found }' /proc/modules 2>/dev/null; then
        if modprobe -r "$m" 2>/dev/null || rmmod "$m" 2>/dev/null; then
            UNLOADED_MODS+=("$m")
        fi
    fi
done
[[ ${#UNLOADED_MODS[@]} -gt 0 ]] && log_ok "Unloaded live EIC7700X kernel modules: ${UNLOADED_MODS[*]}"

if [[ "$TUNE_MODE" == "ai" ]]; then
    if ! awk '$1 == "pvrsrvkm" { found=1 } END { exit !found }' /proc/modules 2>/dev/null; then
        if modinfo pvrsrvkm >/dev/null 2>&1 && modprobe pvrsrvkm 2>/dev/null; then
            log_ok "Reloaded PowerVR compute/GPU module (pvrsrvkm) live for '${TUNE_LABEL}' tune"
        fi
    else
        log_skip "PowerVR compute/GPU module (pvrsrvkm) already loaded for '${TUNE_LABEL}' tune"
    fi
fi

# ==============================================================================
# 1b. EIC7700X CPUFREQ GOVERNOR POLICY (`iot`: schedutil -> ondemand -> performance)
# ==============================================================================
_eic_select_iot_governor() {
    local avail_file="" cand_gov="" avail_list=""
    for avail_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_available_governors; do
        [[ -r "$avail_file" ]] || continue
        avail_list="$(cat "$avail_file" 2>/dev/null || true)"
        for cand_gov in schedutil ondemand performance; do
            if [[ " ${avail_list} " == *" ${cand_gov} "* ]]; then
                printf '%s\n' "$cand_gov"
                return 0
            fi
        done
    done
    printf 'schedutil\n'
}

_eic_apply_governor_live() {
    local target_gov="$1"
    local changed="false" g cur_g
    for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ -w "$g" ]] || continue
        cur_g="$(tr -d '[:space:]' < "$g" 2>/dev/null || true)"
        if [[ "$cur_g" != "$target_gov" ]]; then
            if printf '%s\n' "$target_gov" > "$g" 2>/dev/null; then
                changed="true"
            fi
        fi
    done
    [[ "$changed" == "true" ]]
}

if [[ "$TUNE_MODE" == "iot" ]]; then
    rvdk_prog 55 "EIC7700X DeepTune: configuring low-power cpufreq governor..."
    IOT_GOV="$(_eic_select_iot_governor)"
    GOV_CHANGED="false"
    if [[ -f /etc/default/cpufrequtils ]] && ! grep -Eq "^GOVERNOR=\"?${IOT_GOV}\"?\$" /etc/default/cpufrequtils 2>/dev/null; then
        if grep -Eq '^GOVERNOR=' /etc/default/cpufrequtils 2>/dev/null; then
            sed "s/^GOVERNOR=.*/GOVERNOR=\"${IOT_GOV}\"/" /etc/default/cpufrequtils | rvdk_atomic_write /etc/default/cpufrequtils 0644
        else
            {
                cat /etc/default/cpufrequtils
                printf '\nGOVERNOR="%s"\n' "$IOT_GOV"
            } | rvdk_atomic_write /etc/default/cpufrequtils 0644
        fi
        GOV_CHANGED="true"
    fi

    if _eic_apply_governor_live "$IOT_GOV"; then
        GOV_CHANGED="true"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-enabled --quiet eic7700x-cpufreq-performance.service 2>/dev/null; then
            systemctl disable --now eic7700x-cpufreq-performance.service >/dev/null 2>&1 || true
            GOV_CHANGED="true"
        fi
        WANT_IOT_GOV_UNIT="[Unit]
Description=RVDK ESWIN EIC7700X IoT CPUFreq Governor (schedutil -> ondemand -> performance)
After=multi-user.target power-profiles-daemon.service ondemand.service cpufrequtils.service eic7700x-cpufreq-performance.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do [ -d \"\$c\" ] || continue; avail=\$(cat \"\$c/scaling_available_governors\" 2>/dev/null || true); for gov in schedutil ondemand performance; do case \" \$avail \" in *\" \$gov \"*) echo \"\$gov\" > \"\$c/scaling_governor\" 2>/dev/null || true; break ;; esac; done; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"
        if ! printf '%s\n' "$WANT_IOT_GOV_UNIT" | cmp -s - "$IOT_GOV_UNIT" 2>/dev/null; then
            printf '%s\n' "$WANT_IOT_GOV_UNIT" | rvdk_atomic_write "$IOT_GOV_UNIT" 0644
            systemctl daemon-reload
            systemctl enable --now eic7700x-cpufreq-iot.service >/dev/null 2>&1 || true
            GOV_CHANGED="true"
        elif ! systemctl is-enabled --quiet eic7700x-cpufreq-iot.service 2>/dev/null; then
            systemctl enable --now eic7700x-cpufreq-iot.service >/dev/null 2>&1 || true
            GOV_CHANGED="true"
        fi
    fi

    if [[ "$GOV_CHANGED" == "true" ]]; then
        log_ok "Configured EIC7700X cpufreq governor -> '${IOT_GOV}' (--tune iot)"
    else
        log_skip "EIC7700X cpufreq governor already converged ('${IOT_GOV}')"
    fi
elif [[ -f "$IOT_GOV_UNIT" ]]; then
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now eic7700x-cpufreq-iot.service >/dev/null 2>&1 || true
        rm -f "$IOT_GOV_UNIT"
        systemctl daemon-reload >/dev/null 2>&1 || true
        if [[ -f "$PERF_GOV_UNIT" ]]; then
            systemctl enable --now eic7700x-cpufreq-performance.service >/dev/null 2>&1 || true
        fi
    else
        rm -f "$IOT_GOV_UNIT"
    fi
    if [[ -f /etc/default/cpufrequtils ]] && ! grep -Eq '^GOVERNOR="?performance"?$' /etc/default/cpufrequtils 2>/dev/null; then
        sed 's/^GOVERNOR=.*/GOVERNOR="performance"/' /etc/default/cpufrequtils | rvdk_atomic_write /etc/default/cpufrequtils 0644
    fi
    _eic_apply_governor_live "performance" || true
    log_ok "Restored EIC7700X cpufreq performance governor (--tune ${TUNE_LABEL})"
fi

# ==============================================================================
# 2. EIC7700X 4-HART SIFIVE PLIC INTERRUPT AFFINITY BALANCER
# ==============================================================================
rvdk_prog 80 "EIC7700X DeepTune: pinning PLIC xHCI & GbE (${PRIMARY_NIC}) interrupts..."

printf -v _q_primary_nic '%q' "$PRIMARY_NIC"
_eic_irq_header="$(cat <<'EOF'
#!/usr/bin/env bash
# Managed by RVDK (bsp/eswin/eic7700x/deeptune.sh)
# Spread high-rate EIC7700X peripheral IRQs off CPU0 across the 4 SiFive P550 harts:
#   • nvme0q1..q4 : striped 0,1,2,3 by PCI-MSI
#   • xhci-hcd:usb3 -> CPU1
#   • primary GbE   -> CPU2
#   • xhci-hcd:usb1 -> CPU3
set -Eeuo pipefail
EOF
)"
_eic_irq_body="$(cat <<'EOF'
pin_irq() {
    local pattern="$1"
    local cpu_list="$2"
    local irq
    while IFS= read -r irq; do
        [[ -n "$irq" && -w "/proc/irq/${irq}/smp_affinity_list" ]] || continue
        printf "%s" "$cpu_list" > "/proc/irq/${irq}/smp_affinity_list" 2>/dev/null || true
    done < <(awk -v pat="$pattern" '$0 ~ pat { sub(/:/, "", $1); print $1 }' /proc/interrupts 2>/dev/null)
}
pin_irq "xhci-hcd:usb3" "1"
pin_irq "$PRIMARY_NIC" "2"
if [[ -n "${SECONDARY_NIC:-}" ]]; then
    pin_irq "$SECONDARY_NIC" "2"
fi
pin_irq "xhci-hcd:usb1" "3"
EOF
)"
if [[ -n "$SECONDARY_NIC" ]]; then
    printf -v _q_secondary_nic '%q' "$SECONDARY_NIC"
    _eic_irq_sec_line=$'\n'"SECONDARY_NIC=${_q_secondary_nic}"
else
    _eic_irq_sec_line=""
fi
WANT_IRQ_SCRIPT="${_eic_irq_header}"$'\n'"PRIMARY_NIC=${_q_primary_nic}${_eic_irq_sec_line}"$'\n'"${_eic_irq_body}"

WANT_IRQ_UNIT="[Unit]
Description=RVDK ESWIN EIC7700X PLIC Interrupt Affinity Balancer (${PRIMARY_NIC} + xHCI)
After=network-online.target multi-user.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${IRQ_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"

install -d -m 0755 /usr/local/sbin
IRQ_CHANGED="false"
if ! printf '%s\n' "$WANT_IRQ_SCRIPT" | cmp -s - "$IRQ_SCRIPT" 2>/dev/null; then
    printf '%s\n' "$WANT_IRQ_SCRIPT" | rvdk_atomic_write "$IRQ_SCRIPT" 0755
    IRQ_CHANGED="true"
fi
if command -v systemctl >/dev/null 2>&1; then
    if ! printf "%s\n" "$WANT_IRQ_UNIT" | cmp -s - "$IRQ_UNIT" 2>/dev/null; then
        printf "%s\n" "$WANT_IRQ_UNIT" | rvdk_atomic_write "$IRQ_UNIT" 0644
        systemctl daemon-reload
        systemctl enable eic7700x-irq-affinity.service >/dev/null
        IRQ_CHANGED="true"
    fi
fi
[[ -f "$IRQ_SCRIPT" && ! -L "$IRQ_SCRIPT" ]] || log_fatal "Refusing non-regular or symlink IRQ helper: ${IRQ_SCRIPT}"
"$IRQ_SCRIPT"
if [[ "$IRQ_CHANGED" == "true" ]]; then
    log_ok "Pinned EIC7700X PLIC IRQ affinity (xhci:usb3->CPU1, ${PRIMARY_NIC}->CPU2, xhci:usb1->CPU3)"
else
    log_skip "EIC7700X PLIC IRQ affinity balancer already converged"
fi

rvdk_prog 100 "EIC7700X Silicon DeepTune (--tune ${TUNE_LABEL}) complete"
