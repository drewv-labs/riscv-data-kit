#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Board Quirk: SiFive Premier P550 HDMI & Display Engine
# Path: riscv-data-kit/boards/sifive/p550/quirks/hdmi.sh
# Summary: Runtime toggle for HDMI & Display Controller (crashcart-safe default)
#
# Description:
#   Runtime toggle for the SiFive HiFive Premier P550 (EIC7700X) display
#   subsystem (`es-dc` 502c0000.display_control + `dw-hdmi-eswin` 502a0000.hdmi
#   + `dw-hdmi-cec` + `es_drm`).
#
#   Designed for headless benchmark prehooks/posthooks or on-demand suppression:
#     • Prehook : `sudo rvdk quirk hdmi off`
#       Detaches fbcon (`vtcon1`) cleanly, then unbinds HDMI CEC/audio, DRM,
#       HDMI PHY, and Display Controller—eliminating HDMI hotplug/VSYNC IRQs
#       (PLIC IRQs 18 & 19) during latency-sensitive runs.
#     • Posthook: `sudo rvdk quirk hdmi on`
#       Rebinds Display Controller, HDMI PHY, and DRM, then reattaches `vtcon1`
#       so plugging in a physical crashcart shows a live TTY console again.
#
#   Crashcart Safety:
#     Ephemeral (runtime-only) by default. If a node panics or power-cycles
#     mid-run while HDMI is toggled off, the HDMI console automatically comes
#     back online on the next boot unless `--persist` was explicitly requested.
#
# Usage:
#   sudo rvdk quirk hdmi                # Toggle current state (on <-> off)
#   sudo rvdk quirk hdmi off            # Disable live HDMI/DC (ephemeral)
#   sudo rvdk quirk hdmi off --persist
#   sudo rvdk quirk hdmi on             # Re-enable live HDMI/DC + crashcart TTY
#   rvdk quirk hdmi status              # Inspect DRM, fbcon, and IRQ state
# ==============================================================================
set -Eeuo pipefail

PERSIST_UNIT="/etc/systemd/system/rvdk-p550-hdmi-off.service"
PLAT_DRV_BASE="/sys/bus/platform/drivers"

ACTION="toggle"
PERSIST="false"
FORCE_BOARD="false"

usage() {
    cat <<EOF
Usage: sudo rvdk quirk hdmi [toggle|off|on|status] [--persist] [--force]

Actions:
  toggle        Flip P550 HDMI/Display subsystem active -> off, or off -> on (default)
  off|disable   Detach fbcon and unbind HDMI + Display Controller (runtime-only by default)
  on|enable     Rebind Display Controller + HDMI + DRM and reattach fbcon crashcart TTY
  status        Show DRM connector, bound platform drivers, vtcon1, and IRQ counters

Flags:
  --persist     Also install/enable ${PERSIST_UNIT} so 'off' survives reboots
  --force       Bypass SiFive HiFive Premier P550 / EIC7700X device-tree guard
EOF
}

ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        toggle)                 ACTION="toggle"; shift ;;
        off|disable|stop|0)     ACTION="off"; shift ;;
        on|enable|start|1)      ACTION="on"; shift ;;
        status|stat|check|--status) ACTION="status"; shift ;;
        --persist|--persistent) PERSIST="true"; shift ;;
        --ephemeral|--runtime)  PERSIST="false"; shift ;;
        --force)                FORCE_BOARD="true"; shift ;;
        --noprogbar|--no-progbar|--no-apt-update|--skip-apt-update)
                                shift ;;
        -h|--help)              usage; exit 0 ;;
        *)
            echo "[RVDK:FATAL] Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$ACTION" != "status" && $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        exec sudo -E bash "${BASH_SOURCE[0]}" "${ORIG_ARGS[@]}"
    else
        echo "[RVDK:FATAL] Root privileges required for '${ACTION}'." >&2
        exit 1
    fi
fi

log_info()  { printf "\033[1;36m[RVDK:QUIRK:HDMI]\033[0m %s\n" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

DT_MODEL="${RVDK_DT_MODEL:-Unknown}"
if [[ "$DT_MODEL" == "Unknown" && -r /proc/device-tree/model ]]; then
    DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
fi

if [[ "$FORCE_BOARD" != "true" && "${RVDK_SOC:-}" != "eswin/eic7700x" ]]; then
    case "$DT_MODEL" in
        *"Premier P550"*|*"EIC7700"*|*"Megrez"*|*"StarPro64"*) ;;
        *)
            log_fatal "Board '${DT_MODEL}' is not an ESWIN EIC7700X / SiFive Premier P550 (pass --force to override)."
            ;;
    esac
fi

find_fb_vtcon() {
    local v name
    for v in /sys/class/vtconsole/vtcon*; do
        [[ -d "$v" ]] || continue
        name="$(cat "${v}/name" 2>/dev/null || true)"
        if [[ "$name" == *"frame buffer"* ]]; then
            echo "$v"
            return 0
        fi
    done
    return 1
}

is_hdmi_active() {
    [[ -e "${PLAT_DRV_BASE}/dw-hdmi-eswin/502a0000.hdmi" ]] \
        || [[ -e "${PLAT_DRV_BASE}/es-dc/502c0000.display_control" ]] \
        || [[ -e "${PLAT_DRV_BASE}/es_drm/soc:display-subsystem" ]]
}

unbind_drv_matching() {
    local drv="$1"
    local d base
    local drv_dir="${PLAT_DRV_BASE}/${drv}"
    [[ -d "$drv_dir" && -w "${drv_dir}/unbind" ]] || return 0
    for d in "${drv_dir}"/*; do
        [[ -L "$d" ]] || continue
        base="$(basename "$d")"
        [[ "$base" == "module" ]] && continue
        if printf '%s' "$base" > "${drv_dir}/unbind" 2>/dev/null; then
            log_ok "Unbound ${base} from ${drv}"
        fi
    done
}

bind_drv_dev() {
    local drv="$1"
    local dev="$2"
    local drv_dir="${PLAT_DRV_BASE}/${drv}"
    [[ -d "$drv_dir" && -w "${drv_dir}/bind" ]] || return 0
    [[ -e "/sys/bus/platform/devices/${dev}" ]] || return 0
    if [[ ! -e "${drv_dir}/${dev}" ]]; then
        if printf '%s' "$dev" > "${drv_dir}/bind" 2>/dev/null; then
            log_ok "Bound ${dev} to ${drv}"
        fi
    fi
}

print_status() {
    local active_str="disabled (unbound)"
    is_hdmi_active && active_str="enabled (crashcart-ready)"

    local drm_conn="absent"
    if [[ -r /sys/class/drm/card0-HDMI-A-1/status ]]; then
        drm_conn="HDMI-A-1=$(cat /sys/class/drm/card0-HDMI-A-1/status 2>/dev/null || echo ?)"
    fi

    local fb_vt="none"
    local vt_path
    if vt_path="$(find_fb_vtcon)"; then
        fb_vt="$(basename "$vt_path") (bind=$(cat "${vt_path}/bind" 2>/dev/null || echo 0))"
    fi

    local boot_policy="crashcart-safe (auto-restores on reboot)"
    if systemctl is-enabled --quiet rvdk-p550-hdmi-off.service 2>/dev/null; then
        boot_policy="persistent off (${PERSIST_UNIT})"
    fi

    local irq_summary=""
    irq_summary="$(grep -E 'display_control|502a0000\.hdmi' /proc/interrupts 2>/dev/null | sed 's/^[[:space:]]*//' | paste -sd ' | ' - || true)"
    [[ -z "$irq_summary" ]] && irq_summary="none registered (0 IRQs)"

    log_info "Board: ${DT_MODEL}"
    printf "  • Display Subsystem : %s\n" "$active_str"
    printf "  • DRM Connector     : %s\n" "$drm_conn"
    printf "  • Framebuffer VT    : %s\n" "$fb_vt"
    printf "  • Boot Policy       : %s\n" "$boot_policy"
    printf "  • Display IRQs      : %s\n" "$irq_summary"
}

disable_hdmi() {
    log_info "Disabling SiFive P550 HDMI & Display Controller for noise-free execution..."

    local vt_path
    if vt_path="$(find_fb_vtcon)"; then
        if [[ "$(cat "${vt_path}/bind" 2>/dev/null || echo 0)" == "1" ]]; then
            printf '0' > "${vt_path}/bind" 2>/dev/null || true
            log_ok "Detached framebuffer VT console ($(basename "$vt_path"))"
        fi
    fi

    unbind_drv_matching "dw-hdmi-cec"
    unbind_drv_matching "dw-hdmi-i2s-audio"
    unbind_drv_matching "hdmi-audio-codec"
    unbind_drv_matching "es_drm"
    unbind_drv_matching "dw-hdmi-eswin"
    unbind_drv_matching "es-dc"

    if [[ "$PERSIST" == "true" ]]; then
        local self_path
        self_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "/usr/local/bin/rvdk quirk hdmi")"
        cat <<EOF > "$PERSIST_UNIT"
[Unit]
Description=RVDK SiFive P550 Headless Display/HDMI Suppression
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${self_path} off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable rvdk-p550-hdmi-off.service >/dev/null
        log_ok "Persisted HDMI suppression across reboots (${PERSIST_UNIT})"
    fi

    print_status
}

enable_hdmi() {
    log_info "Re-enabling SiFive P550 HDMI & Display Controller (crashcart TTY)..."

    if [[ -f "$PERSIST_UNIT" ]]; then
        systemctl disable rvdk-p550-hdmi-off.service >/dev/null 2>&1 || true
        rm -f "$PERSIST_UNIT"
        systemctl daemon-reload
        log_ok "Removed persistent boot suppression (${PERSIST_UNIT})"
    fi

    bind_drv_dev "es-dc" "502c0000.display_control"
    bind_drv_dev "dw-hdmi-eswin" "502a0000.hdmi"
    bind_drv_dev "es_drm" "soc:display-subsystem"

    local vt_path
    if vt_path="$(find_fb_vtcon)"; then
        if [[ "$(cat "${vt_path}/bind" 2>/dev/null || echo 0)" == "0" ]]; then
            printf '1' > "${vt_path}/bind" 2>/dev/null || true
            log_ok "Reattached framebuffer VT console ($(basename "$vt_path"))"
        fi
    fi

    print_status
}

case "$ACTION" in
    status)
        print_status
        ;;
    off)
        disable_hdmi
        ;;
    on)
        enable_hdmi
        ;;
    toggle)
        if is_hdmi_active; then
            disable_hdmi
        else
            enable_hdmi
        fi
        ;;
esac
