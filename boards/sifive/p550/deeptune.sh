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

log_info() { printf "\033[1;36m[RVDK:P550-DEEPTUNE]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }

ACTION="apply"
for arg in "$@"; do
    case "$arg" in
        status|--status) ACTION="status" ;;
        --noprogbar|--no-progbar) export RVDK_NO_PROGBAR="1" ;;
    esac
done

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"
FUSB_QUIRK="${_SCRIPT_DIR}/quirks/fusb.sh"
HDMI_QUIRK="${_SCRIPT_DIR}/quirks/hdmi.sh"

if [[ "$ACTION" == "status" ]]; then
    log_info "Layer 3 Board (sifive/p550):"
    [[ -f "$FUSB_QUIRK" ]] && bash "$FUSB_QUIRK" status
    [[ -f "$HDMI_QUIRK" ]] && bash "$HDMI_QUIRK" status
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

_PROGBAR_CANDIDATE="${RVDK_PROGBAR_LIB:-${REPO_ROOT}/lib/progbar.sh}"
if [[ -f "$_PROGBAR_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    source "$_PROGBAR_CANDIDATE"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_prog_init "P550 Carrier DeepTune: suppressing HF106C front-panel USB-C IRQ..."
log_info "Converging SiFive Premier P550 Carrier DeepTune (HDMI crashcart preserved)..."

if [[ -f "$FUSB_QUIRK" ]]; then
    bash "$FUSB_QUIRK" off --quiet
    log_ok "Disabled & blacklisted HF106C front-panel Type-C controller (fusb303b; restore via 'sudo rvdk quirk fusb on')"
fi

rvdk_prog 100 "P550 Carrier DeepTune complete"
