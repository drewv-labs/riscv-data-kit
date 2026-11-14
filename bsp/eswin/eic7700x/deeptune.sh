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
#     • `ml` | `ai` tune:
#       Suppresses unused ALSA audio codec modules while removing `pvrsrvkm` from
#       the blacklist and reloading it live for OpenCL / edge ML compute.
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

log_info()  { printf "\033[1;36m[RVDK:EIC7700X-DEEPTUNE]\033[0m %s\n" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

ACTION="apply"
TUNE_REQUEST="${RVDK_TUNE:-}"
FORCE_SOC="false"
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tune)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument: data | ml | ai"
            TUNE_REQUEST="$2"
            shift 2
            ;;
        --tune=*)
            TUNE_REQUEST="${1#*=}"
            shift
            ;;
        data|ml|ai)
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
            cat <<EOF
Usage: sudo rvdk deeptune [--tune <data|ml|ai>] [status] [--force] [--noprogbar]
Layer 2 SoC script: bsp/eswin/eic7700x/deeptune.sh
EOF
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

if [[ "$ACTION" != "status" && $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "${ORIG_ARGS[@]}"
fi

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

if [[ -n "$REPO_ROOT" && -f "${REPO_ROOT}/lib/kit.sh" ]]; then
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/kit.sh"
    rvdk_kit_resolve
fi

_PROGBAR_CANDIDATE="${RVDK_PROGBAR_LIB:-}"
[[ -z "$_PROGBAR_CANDIDATE" && -n "$REPO_ROOT" && -f "${REPO_ROOT}/lib/progbar.sh" ]] && _PROGBAR_CANDIDATE="${REPO_ROOT}/lib/progbar.sh"
if [[ -n "$_PROGBAR_CANDIDATE" && -f "$_PROGBAR_CANDIDATE" && "$ACTION" != "status" ]]; then
    # shellcheck disable=SC1090
    source "$_PROGBAR_CANDIDATE"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

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

    log_info "Layer 2 SoC (eswin/eic7700x):"
    printf "  • PowerVR GPU/ML    : %s\n" "$gpu_mod"
    printf "  • PLIC IRQ Balancer : %s (%s)\n" "$irq_svc" "$IRQ_UNIT"
}

if [[ "$ACTION" == "status" ]]; then
    print_status
    exit 0
fi

if [[ -z "$TUNE_REQUEST" && -r /etc/rvdk/deeptune.env ]]; then
    TUNE_REQUEST="$(awk -F= '/^RVDK_TUNE=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' /etc/rvdk/deeptune.env 2>/dev/null || true)"
fi
TUNE_REQUEST="$(tr '[:upper:]' '[:lower:]' <<< "${TUNE_REQUEST:-data}")"

case "$TUNE_REQUEST" in
    ml)                 TUNE_MODE="ml";   TUNE_LABEL="ml" ;;
    ai|edge-ai|edge-ml) TUNE_MODE="ml";   TUNE_LABEL="ai" ;;
    data)               TUNE_MODE="data"; TUNE_LABEL="data" ;;
    *)                  log_fatal "Invalid --tune '${TUNE_REQUEST}' (expected: data | ml | ai)" ;;
esac

PRIMARY_NIC="${RVDK_PRIMARY_NIC:-end0}"
[[ -z "$PRIMARY_NIC" ]] && PRIMARY_NIC="end0"

rvdk_prog_init "EIC7700X SoC DeepTune (--tune ${TUNE_LABEL}): converging accelerators & IRQs..."
log_info "Converging ESWIN EIC7700X Silicon DeepTune (--tune ${TUNE_LABEL} | mode=${TUNE_MODE})..."

# ==============================================================================
# 1. EIC7700X ALSA CODEC BLACKLIST & REVERSIBLE POWERVR GPU (`pvrsrvkm`)
# ==============================================================================
rvdk_prog 35 "EIC7700X DeepTune: converging SoC audio & PowerVR GPU modules (--tune ${TUNE_LABEL})..."

# Clean up legacy pre-split modprobe file if present
if [[ -f "$LEGACY_MODPROBE" ]]; then
    rm -f "$LEGACY_MODPROBE"
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
fi

WANT_MODPROBE="# Managed by RVDK (bsp/eswin/eic7700x/deeptune.sh | tune=${TUNE_LABEL})
# Suppresses EIC7700X ALSA codec$( [[ "$TUNE_MODE" == "data" ]] && printf " and PowerVR BXM-4-64 GPU (pvrsrvkm)" ) modules."
for m in "${TARGET_MODS[@]}"; do
    WANT_MODPROBE+=$'\n'"blacklist ${m}"
done

if ! printf "%s\n" "$WANT_MODPROBE" | cmp -s - "$MODPROBE_SOC" 2>/dev/null; then
    printf "%s\n" "$WANT_MODPROBE" > "$MODPROBE_SOC"
    chmod 0644 "$MODPROBE_SOC"
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

if [[ "$TUNE_MODE" == "ml" ]]; then
    if ! awk '$1 == "pvrsrvkm" { found=1 } END { exit !found }' /proc/modules 2>/dev/null; then
        if modinfo pvrsrvkm >/dev/null 2>&1 && modprobe pvrsrvkm 2>/dev/null; then
            log_ok "Reloaded PowerVR compute/GPU module (pvrsrvkm) live for '${TUNE_LABEL}' tune"
        fi
    else
        log_skip "PowerVR compute/GPU module (pvrsrvkm) already loaded for '${TUNE_LABEL}' tune"
    fi
fi

# ==============================================================================
# 2. EIC7700X 4-HART SIFIVE PLIC INTERRUPT AFFINITY BALANCER
# ==============================================================================
rvdk_prog 80 "EIC7700X DeepTune: pinning PLIC xHCI & GbE (${PRIMARY_NIC}) interrupts..."

WANT_IRQ_SCRIPT="#!/usr/bin/env bash
# Managed by RVDK (bsp/eswin/eic7700x/deeptune.sh)
# Spread high-rate EIC7700X peripheral IRQs off CPU0 across the 4 SiFive P550 harts:
#   • nvme0q1..q4 : striped 0,1,2,3 by PCI-MSI
#   • xhci-hcd:usb3 -> CPU1
#   • ${PRIMARY_NIC} (GbE)    -> CPU2
#   • xhci-hcd:usb1 -> CPU3
set -euo pipefail
pin_irq() {
    local pattern=\"\$1\"
    local cpu_list=\"\$2\"
    local irq
    while IFS= read -r irq; do
        [[ -n \"\$irq\" && -w \"/proc/irq/\${irq}/smp_affinity_list\" ]] || continue
        printf \"%s\" \"\$cpu_list\" > \"/proc/irq/\${irq}/smp_affinity_list\" 2>/dev/null || true
    done < <(awk -v pat=\"\$pattern\" \"\\\$0 ~ pat { sub(/:/, \\\"\\\", \\\$1); print \\\$1 }\" /proc/interrupts 2>/dev/null)
}
pin_irq \"xhci-hcd:usb3\" \"1\"
pin_irq \"${PRIMARY_NIC}\" \"2\"
pin_irq \"xhci-hcd:usb1\" \"3\"
"

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
if ! printf "%s" "$WANT_IRQ_SCRIPT" | cmp -s - "$IRQ_SCRIPT" 2>/dev/null; then
    printf "%s" "$WANT_IRQ_SCRIPT" > "$IRQ_SCRIPT"
    chmod 0755 "$IRQ_SCRIPT"
    IRQ_CHANGED="true"
fi
if ! printf "%s\n" "$WANT_IRQ_UNIT" | cmp -s - "$IRQ_UNIT" 2>/dev/null; then
    printf "%s\n" "$WANT_IRQ_UNIT" > "$IRQ_UNIT"
    systemctl daemon-reload
    systemctl enable eic7700x-irq-affinity.service >/dev/null
    IRQ_CHANGED="true"
fi
"$IRQ_SCRIPT"
if [[ "$IRQ_CHANGED" == "true" ]]; then
    log_ok "Pinned EIC7700X PLIC IRQ affinity (xhci:usb3->CPU1, ${PRIMARY_NIC}->CPU2, xhci:usb1->CPU3)"
else
    log_skip "EIC7700X PLIC IRQ affinity balancer already converged"
fi

rvdk_prog 100 "EIC7700X Silicon DeepTune (--tune ${TUNE_LABEL}) complete"
