#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Layer 2: SpacemiT K1 / M1 / Ky X1 Silicon SoC DeepTune
# Path: riscv-data-kit/bsp/spacemit/k1/deeptune.sh
#
# Description:
#   Idempotent, reversible silicon-level deep-tuning shared across all SpacemiT
#   K1 / M1 / Ky X1 8-core X60 (RVA22 + RVV 1.0) RISC-V boards (Orange Pi RV2,
#   Orange Pi R2S, Banana Pi BPI-F3, BPI-CM6, Milk-V Jupiter):
#     • `data` tune (default):
#       Unloads & blacklists the IMG BXE-2-32 GPU (`pvrsrvkm`) and M.2 PCIe NPU
#       (`hailo_pci`, `hailo1x_pci`) modules alongside Bluetooth (`hci_uart`,
#       `btbcm`, `btusb`, `btrtl`, `btintel`), ALSA audio codecs, and (when the
#       primary NIC is wired) Broadcom SDIO Wi-Fi (`bcmdhd`, `dhd_static_buf`).
#     • `ai` tune:
#       Suppresses unused Bluetooth/audio/SDIO-Wi-Fi noise while unblocking and
#       reloading IMG BXE-2-32 (`pvrsrvkm`) and M.2 PCIe Hailo NPU (`hailo_pci`,
#       `hailo1x_pci`) drivers for OpenCL / RVV 1.0 / PCIe NPU edge inference.
#     • Dual-Cluster 8-Hart X60 PLIC & RPS Interrupt Balancer
#       (`spacemit-k1-irq-affinity.service`):
#       Isolates high-rate GbE/2.5GbE, xHCI USB 3.0, and MMC/eMMC HS400ES
#       interrupts + `NET_RX` RPS queues inside Cluster 0 (`cpu1..3`, shared
#       512 KB L2_0), keeping `cpu0` free for timer housekeeping and leaving
#       Cluster 1 (`cpu4..7`, shared 512 KB L2_1) undisturbed for PostgreSQL
#       `io_uring` workers (`data`) or RVV 1.0 / PCIe NPU inference (`ai`).
# ==============================================================================
set -Eeuo pipefail

MODPROBE_SOC="/etc/modprobe.d/90-rvdk-spacemit-k1-deeptune.conf"
IRQ_SCRIPT="/usr/local/sbin/rvdk-spacemit-k1-irq-tune"
IRQ_UNIT="/etc/systemd/system/spacemit-k1-irq-affinity.service"

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
        log_info()  { printf "\033[1;36m[RVDK:SPACEMIT-K1-DEEPTUNE]\033[0m %s\n" "$1"; }
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

rvdk_log_init "RVDK:SPACEMIT-K1-DEEPTUNE"

ACTION="apply"
TUNE_REQUEST="${RVDK_TUNE:-}"
FORCE_SOC="false"
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tune)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument: data | ai"
            TUNE_REQUEST="$2"
            shift 2
            ;;
        --tune=*)
            TUNE_REQUEST="${1#*=}"
            shift
            ;;
        data|ai|ml)
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
Usage: sudo rvdk deeptune [--tune <data|ai>] [status] [--force] [--noprogbar]
Layer 2 SoC script: bsp/spacemit/k1/deeptune.sh
EOF
            exit 0
            ;;
        *)
            log_fatal "Unknown argument: $1 (try --help)"
            ;;
    esac
done

if [[ "$ACTION" != "status" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        exec sudo -E bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    else
        log_fatal "Root privileges required. Pipe into 'sudo bash' or run via 'sudo rvdk deeptune'."
    fi
fi

declare -F rvdk_kit_resolve >/dev/null 2>&1 && rvdk_kit_resolve

DT_MODEL="${RVDK_DT_MODEL:-Unknown}"
if [[ "$DT_MODEL" == "Unknown" && -r /proc/device-tree/model ]]; then
    DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
fi
DT_MODEL_LC="$(tr '[:upper:]' '[:lower:]' <<< "$DT_MODEL")"

if [[ "$FORCE_SOC" != "true" && "${RVDK_SOC:-}" != "spacemit/k1" ]]; then
    case "$DT_MODEL_LC" in
        *"spacemit"*|*"ky x1"*|*"orangepi-rv2"*|*"orangepi rv2"*|*"orangepi-r2s"*|*"bpi-f3"*|*"bananapi"*"f3"*|*"cm6"*|*"jupiter"*) ;;
        *) log_fatal "Target '${DT_MODEL}' is not a SpacemiT K1/M1/Ky X1 SoC (pass --force to override)." ;;
    esac
fi

print_status() {
    local gpu_mod="unloaded"
    awk '$1 == "pvrsrvkm" { found=1 } END { exit !found }' /proc/modules 2>/dev/null && gpu_mod="loaded (pvrsrvkm)"
    if grep -qs '^blacklist pvrsrvkm$' "$MODPROBE_SOC" 2>/dev/null; then
        gpu_mod+=" [boot: blacklisted]"
    else
        gpu_mod+=" [boot: enabled]"
    fi

    local npu_mod="unloaded"
    awk '$1 == "hailo_pci" || $1 == "hailo1x_pci" { found=1 } END { exit !found }' /proc/modules 2>/dev/null && npu_mod="loaded (hailo_pci)"
    if grep -qsE '^blacklist hailo1?x?_pci$' "$MODPROBE_SOC" 2>/dev/null; then
        npu_mod+=" [boot: blacklisted]"
    else
        npu_mod+=" [boot: enabled]"
    fi

    local wifi_mod="unloaded"
    awk '$1 == "bcmdhd" { found=1 } END { exit !found }' /proc/modules 2>/dev/null && wifi_mod="loaded (bcmdhd)"
    if grep -qs '^blacklist bcmdhd$' "$MODPROBE_SOC" 2>/dev/null; then
        wifi_mod+=" [boot: blacklisted]"
    fi

    local irq_svc="inactive"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet spacemit-k1-irq-affinity.service 2>/dev/null; then
        irq_svc="enabled"
    fi

    log_info "Layer 2 SoC (spacemit/k1):"
    printf "  • IMG BXE-2-32 GPU  : %s\n" "$gpu_mod"
    printf "  • PCIe Hailo AI NPU : %s\n" "$npu_mod"
    printf "  • Broadcom SDIO WiFi: %s\n" "$wifi_mod"
    printf "  • 8-Hart X60 IRQs   : %s (%s)\n" "$irq_svc" "$IRQ_UNIT"
}

if [[ "$ACTION" == "status" ]]; then
    print_status
    exit 0
fi

if [[ "${RVDK_OS_ID:-}" == "openwrt" || -f /etc/openwrt_release ]] || ! command -v systemctl >/dev/null 2>&1; then
    log_skip "Non-systemd rootfs (${RVDK_OS_ID:-procd}); skipping systemd SpacemiT K1 DeepTune units"
    exit 0
fi

if [[ -z "$TUNE_REQUEST" && -r /etc/rvdk/deeptune.env ]]; then
    if declare -F rvdk_kv_load >/dev/null 2>&1; then
        RVDK_TUNE=""
        rvdk_kv_load /etc/rvdk/deeptune.env RVDK_TUNE
        TUNE_REQUEST="$RVDK_TUNE"
    else
        TUNE_REQUEST="$(awk -F= '/^RVDK_TUNE=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' /etc/rvdk/deeptune.env 2>/dev/null || true)"
    fi
fi
TUNE_REQUEST="$(tr '[:upper:]' '[:lower:]' <<< "${TUNE_REQUEST:-data}")"

case "$TUNE_REQUEST" in
    ai|ml|edge-ai|edge-ml) TUNE_MODE="ai";   TUNE_LABEL="ai" ;;
    data)                  TUNE_MODE="data"; TUNE_LABEL="data" ;;
    *)                     log_fatal "Invalid --tune '${TUNE_REQUEST}' (expected: data | ai)" ;;
esac

PRIMARY_NIC="${RVDK_PRIMARY_NIC:-}"
if [[ -z "$PRIMARY_NIC" ]] && command -v ip >/dev/null 2>&1; then
    PRIMARY_NIC="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
fi
[[ -z "$PRIMARY_NIC" ]] && PRIMARY_NIC="end0"

PRIMARY_IS_WIFI="false"
if [[ "$PRIMARY_NIC" == wl* || -d "/sys/class/net/${PRIMARY_NIC}/wireless" ]]; then
    PRIMARY_IS_WIFI="true"
    log_warn "Primary NIC '${PRIMARY_NIC}' is wireless; keeping bcmdhd/dhd_static_buf active to protect SSH"
fi

rvdk_prog_init "SpacemiT K1 DeepTune (--tune ${TUNE_LABEL}): converging accelerators & 8-hart X60 IRQs..."
log_info "Converging SpacemiT K1 / Ky X1 Silicon DeepTune (--tune ${TUNE_LABEL} | NIC=${PRIMARY_NIC})..."

# ==============================================================================
# 1. BLUETOOTH / SDIO WI-FI / AUDIO SUPPRESSION & REVERSIBLE GPU/NPU POLICY
# ==============================================================================
rvdk_prog 35 "SpacemiT K1 DeepTune: converging wireless, audio & GPU/Hailo modules (--tune ${TUNE_LABEL})..."

if pgrep -f "brcm_patchram_plus" >/dev/null 2>&1; then
    pkill -TERM -f "brcm_patchram_plus" 2>/dev/null || true
    log_ok "Stopped background brcm_patchram_plus UART Bluetooth daemon"
fi

if [[ "$PRIMARY_IS_WIFI" == "false" ]]; then
    for mod_load_cfg in /etc/modules /etc/modules-load.d/orangepirv2.conf; do
        if [[ -f "$mod_load_cfg" ]] && grep -Eq '^[[:space:]]*(bcmdhd|dhd_static_buf)([[:space:]]|$)' "$mod_load_cfg" 2>/dev/null; then
            sed -E 's/^[[:space:]]*(bcmdhd|dhd_static_buf)([[:space:]].*)?$/# \1 # disabled by RVDK spacemit\/k1 deeptune/' "$mod_load_cfg" \
                | rvdk_atomic_write "$mod_load_cfg" 0644
            log_ok "Disabled forced SDIO Wi-Fi module autoload in ${mod_load_cfg}"
        fi
    done
fi

SOC_BASE_BLACKLIST=(
    hci_uart
    btbcm
    btusb
    btrtl
    btintel
    bluetooth
    snd_soc_hdmi_codec
    snd_soc_simple_card
    snd_soc_simple_card_utils
    snd_soc_audio_graph_card
)

if [[ "$PRIMARY_IS_WIFI" == "false" ]]; then
    SOC_BASE_BLACKLIST=(bcmdhd dhd_static_buf "${SOC_BASE_BLACKLIST[@]}")
fi

TARGET_MODS=("${SOC_BASE_BLACKLIST[@]}")
if [[ "$TUNE_MODE" == "data" ]]; then
    TARGET_MODS=(pvrsrvkm hailo_pci hailo1x_pci radeon "${TARGET_MODS[@]}")
fi

mkdir -p /etc/modprobe.d
WANT_MODPROBE="# Managed by RVDK (bsp/spacemit/k1/deeptune.sh | tune=${TUNE_LABEL})
# Suppresses SpacemiT K1/Ky X1 Bluetooth/ALSA$( [[ "$PRIMARY_IS_WIFI" == "false" ]] && printf "/SDIO-WiFi" )$( [[ "$TUNE_MODE" == "data" ]] && printf " and IMG GPU / Hailo PCIe NPU" ) modules."
for m in "${TARGET_MODS[@]}"; do
    WANT_MODPROBE+=$'\n'"blacklist ${m}"
done

if ! printf "%s\n" "$WANT_MODPROBE" | cmp -s - "$MODPROBE_SOC" 2>/dev/null; then
    printf "%s\n" "$WANT_MODPROBE" | rvdk_atomic_write "$MODPROBE_SOC" 0644
    log_ok "Updated SpacemiT K1 kernel module policy (--tune ${TUNE_LABEL}) in ${MODPROBE_SOC}"
else
    log_skip "SpacemiT K1 kernel module policy (${MODPROBE_SOC}) already converged for '${TUNE_LABEL}'"
fi

UNLOADED_MODS=()
for m in "${TARGET_MODS[@]}"; do
    if awk -v mod="$m" '$1 == mod { found=1 } END { exit !found }' /proc/modules 2>/dev/null; then
        if modprobe -r "$m" 2>/dev/null || rmmod "$m" 2>/dev/null; then
            UNLOADED_MODS+=("$m")
        fi
    fi
done
[[ ${#UNLOADED_MODS[@]} -gt 0 ]] && log_ok "Unloaded live SpacemiT K1 kernel modules: ${UNLOADED_MODS[*]}"

if [[ "$TUNE_MODE" == "ai" ]]; then
    for ai_mod in pvrsrvkm hailo_pci hailo1x_pci; do
        if ! awk -v mod="$ai_mod" '$1 == mod { found=1 } END { exit !found }' /proc/modules 2>/dev/null; then
            if modinfo "$ai_mod" >/dev/null 2>&1 && modprobe "$ai_mod" 2>/dev/null; then
                log_ok "Loaded accelerator module (${ai_mod}) live for '${TUNE_LABEL}' tune"
            fi
        else
            log_skip "Accelerator module (${ai_mod}) already loaded for '${TUNE_LABEL}' tune"
        fi
    done
fi

# ==============================================================================
# 2. DUAL-CLUSTER 8-HART SPACEMIT X60 PLIC & RPS INTERRUPT BALANCER
# ==============================================================================
rvdk_prog 80 "SpacemiT K1 DeepTune: pinning Cluster 0 (cpu1..3) I/O IRQs & isolating Cluster 1 (cpu4..7)..."

WANT_IRQ_SCRIPT="#!/usr/bin/env bash
# Managed by RVDK (bsp/spacemit/k1/deeptune.sh)
# SpacemiT K1 / Ky X1 cache-topology-aware IRQ & RPS affinity across 2x4 X60 clusters:
#   • cpu0            : Timer & kernel housekeeping
#   • Cluster 0 (1..3): GbE/2.5GbE (${PRIMARY_NIC}, end1/eth1) + RPS (0x0e), xHCI USB3, MMC/eMMC
#   • Cluster 1 (4..7): Isolated shared-L2 compute/database/RVV 1.0/NPU harts
set -Eeuo pipefail

pin_irq() {
    local pattern=\"\$1\"
    local cpu_list=\"\$2\"
    local irq
    while IFS= read -r irq; do
        [[ -n \"\$irq\" && -w \"/proc/irq/\${irq}/smp_affinity_list\" ]] || continue
        printf \"%s\" \"\$cpu_list\" > \"/proc/irq/\${irq}/smp_affinity_list\" 2>/dev/null || true
    done < <(awk -v pat=\"\$pattern\" \"\\\$0 ~ pat { sub(/:/, \\\"\\\", \\\$1); print \\\$1 }\" /proc/interrupts 2>/dev/null)
}

pin_irq \"${PRIMARY_NIC}\" \"1\"
pin_irq \"end1|eth1|enP1p1s0\" \"2\"
pin_irq \"xhci-hcd\" \"3\"
pin_irq \"mmc0|mmc2|sdhci\" \"3\"

for nic_dir in /sys/class/net/end* /sys/class/net/eth* /sys/class/net/enP*; do
    [[ -d \"\$nic_dir\" ]] || continue
    for rps_f in \"\${nic_dir}\"/queues/rx-*/rps_cpus; do
        [[ -w \"\$rps_f\" ]] && printf \"0e\" > \"\$rps_f\" 2>/dev/null || true
    done
done
"

WANT_IRQ_UNIT="[Unit]
Description=RVDK SpacemiT K1 Dual-Cluster X60 Interrupt & RPS Affinity (${PRIMARY_NIC} + xHCI + MMC)
After=network-online.target multi-user.target orangepi-hardware-optimize.service armbian-hardware-optimize.service
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
    printf "%s" "$WANT_IRQ_SCRIPT" | rvdk_atomic_write "$IRQ_SCRIPT" 0755
    IRQ_CHANGED="true"
fi
if ! printf "%s\n" "$WANT_IRQ_UNIT" | cmp -s - "$IRQ_UNIT" 2>/dev/null; then
    printf "%s\n" "$WANT_IRQ_UNIT" | rvdk_atomic_write "$IRQ_UNIT" 0644
    systemctl daemon-reload
    systemctl enable spacemit-k1-irq-affinity.service >/dev/null
    IRQ_CHANGED="true"
fi
"$IRQ_SCRIPT"
if [[ "$IRQ_CHANGED" == "true" ]]; then
    log_ok "Pinned SpacemiT K1 Cluster 0 IRQ/RPS affinity (${PRIMARY_NIC}->CPU1, NIC2->CPU2, xHCI/MMC->CPU3; Cluster 1 CPU4..7 isolated)"
else
    log_skip "SpacemiT K1 8-hart X60 IRQ/RPS affinity balancer already converged"
fi

rvdk_prog 100 "SpacemiT K1 Silicon DeepTune (--tune ${TUNE_LABEL}) complete"
