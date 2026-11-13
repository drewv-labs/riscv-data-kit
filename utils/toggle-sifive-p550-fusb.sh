#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Utility: Toggle SiFive Premier P550 FUSB303B Type-C IRQ
# Path: riscv-data-kit/utils/toggle-sifive-p550-fusb.sh
#
# Description:
#   On the SiFive HiFive Premier P550 (HF106C carrier), the out-of-tree
#   `fusb303b` driver controls ONLY the front-panel USB 3.2 Type-E / Type-C
#   port (not the rear teal USB-A 3.2 ports and not the rear FT4232HL debug
#   UART/JTAG port). When left unconnected, its threaded I2C/GPIO handler
#   (`irq/84-fusb303b_`) can burn ~1% CPU continuously and inject IRQ jitter.
#
#   This opt-in utility toggles `fusb303b` off/on at runtime (unbinding the I2C
#   client + unloading `fusb303b.ko`) and persists the choice across reboots via
#   /etc/modprobe.d/90-rvdk-p550-fusb303b.conf (unless --ephemeral is passed).
#
# Usage:
#   sudo rvdk utils/toggle-sifive-p550-fusb.sh            # Toggle current state (on <-> off)
#   sudo rvdk utils/toggle-sifive-p550-fusb.sh off        # Disable live IRQ + blacklist on boot
#   sudo rvdk utils/toggle-sifive-p550-fusb.sh off --ephemeral
#   sudo rvdk utils/toggle-sifive-p550-fusb.sh on         # Re-enable module + remove blacklist
#   sudo rvdk utils/toggle-sifive-p550-fusb.sh status     # Inspect IRQ, I2C, and boot state
# ==============================================================================
set -Eeuo pipefail

MODPROBE_CONF="/etc/modprobe.d/90-rvdk-p550-fusb303b.conf"
STATE_CACHE="/run/rvdk-fusb303b.bound"
I2C_DRV_DIR="/sys/bus/i2c/drivers/fusb303b"

ACTION="toggle"
EPHEMERAL="false"
FORCE_BOARD="false"

usage() {
    cat <<EOF
Usage: sudo rvdk utils/toggle-sifive-p550-fusb.sh [toggle|off|on|status] [--ephemeral] [--force]

Actions:
  toggle        Flip fusb303b from active -> off, or off -> on (default)
  off|disable   Unbind & unload fusb303b (stops irq/*-fusb303b_) and blacklist at boot
  on|enable     Remove blacklist, reload fusb303b, and bind I2C controller
  status        Show live module, I2C binding, IRQ thread, and boot blacklist status

Flags:
  --ephemeral   Apply 'off' for current boot only (do not write ${MODPROBE_CONF})
  --force       Bypass SiFive HiFive Premier P550 / EIC7700X device-tree guard
EOF
}

ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        toggle)                 ACTION="toggle"; shift ;;
        off|disable|stop|0)     ACTION="off"; shift ;;
        on|enable|start|1)      ACTION="on"; shift ;;
        status|stat|check)      ACTION="status"; shift ;;
        --ephemeral|--runtime)  EPHEMERAL="true"; shift ;;
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

log_info()  { printf "\033[1;36m[RVDK:FUSB303B]\033[0m %s\n" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

DT_MODEL="Unknown"
if [[ -r /proc/device-tree/model ]]; then
    DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
fi

if [[ "$FORCE_BOARD" != "true" ]]; then
    case "$DT_MODEL" in
        *"Premier P550"*|*"EIC7700"*|*"Megrez"*|*"StarPro64"*) ;;
        *)
            log_fatal "Board '${DT_MODEL}' is not an ESWIN EIC7700X / SiFive Premier P550 (pass --force to override)."
            ;;
    esac
fi

is_mod_loaded() {
    awk '$1 == "fusb303b" { found=1 } END { exit !found }' /proc/modules 2>/dev/null
}

bound_i2c_devs() {
    local d
    if [[ -d "$I2C_DRV_DIR" ]]; then
        for d in "${I2C_DRV_DIR}"/[0-9]*-*; do
            [[ -e "$d" ]] && basename "$d"
        done
    fi
}

has_fusb_kthread() {
    ps -eo comm 2>/dev/null | awk '$1 ~ /^irq\/[0-9]+-fusb303/ { found=1 } END { exit !found }'
}

is_fusb_active() {
    if is_mod_loaded; then
        return 0
    fi
    if [[ -n "$(bound_i2c_devs)" ]]; then
        return 0
    fi
    has_fusb_kthread
}

print_status() {
    local mod_state="unloaded"
    is_mod_loaded && mod_state="loaded (fusb303b.ko)"

    local bound
    bound="$(bound_i2c_devs | paste -sd, -)"
    [[ -z "$bound" ]] && bound="none"

    local kthreads
    kthreads="$(ps -eo pid,comm,pcpu 2>/dev/null | awk '$2 ~ /^irq\/[0-9]+-fusb303/ {printf "%s (PID %s, %s%% CPU) ", $2, $1, $3}' || true)"
    [[ -z "$kthreads" ]] && kthreads="none (0.0% CPU)"

    local boot_policy="enabled (default)"
    [[ -f "$MODPROBE_CONF" ]] && boot_policy="blacklisted (${MODPROBE_CONF})"

    local irq_line=""
    irq_line="$(grep -E 'fusb303' /proc/interrupts 2>/dev/null | sed 's/^[[:space:]]*//' || true)"

    log_info "Board: ${DT_MODEL}"
    printf "  • Kernel Module   : %s\n" "$mod_state"
    printf "  • Bound I2C Dev   : %s\n" "$bound"
    printf "  • IRQ Kthread     : %s\n" "$kthreads"
    printf "  • Boot Policy     : %s\n" "$boot_policy"
    if [[ -n "$irq_line" ]]; then
        printf "  • /proc/interrupts: %s\n" "$irq_line"
    fi
}

disable_fusb() {
    log_info "Disabling SiFive P550 front-panel USB-C controller (fusb303b)..."

    local bound_list=()
    local dev_id
    while IFS= read -r dev_id; do
        [[ -n "$dev_id" ]] && bound_list+=("$dev_id")
    done < <(bound_i2c_devs)

    if [[ ${#bound_list[@]} -gt 0 ]]; then
        printf '%s\n' "${bound_list[@]}" > "$STATE_CACHE" 2>/dev/null || true
        for dev_id in "${bound_list[@]}"; do
            if [[ -w "${I2C_DRV_DIR}/unbind" ]]; then
                printf '%s' "$dev_id" > "${I2C_DRV_DIR}/unbind" 2>/dev/null || true
                log_ok "Unbound I2C client ${dev_id} from fusb303b driver"
            fi
        done
    fi

    if is_mod_loaded; then
        if modprobe -r fusb303b 2>/dev/null || rmmod fusb303b 2>/dev/null; then
            log_ok "Unloaded kernel module fusb303b"
        else
            log_warn "fusb303b module still referenced, but I2C client is unbound"
        fi
    fi

    if [[ "$EPHEMERAL" == "false" ]]; then
        cat <<'EOF' > "$MODPROBE_CONF"
# Managed by RVDK (utils/toggle-sifive-p550-fusb.sh)
# Suppresses out-of-tree front-panel Type-C controller IRQ chatter (irq/*-fusb303b_).
# Re-enable anytime with: sudo rvdk utils/toggle-sifive-p550-fusb.sh on
blacklist fusb303b
EOF
        chmod 0644 "$MODPROBE_CONF"
        log_ok "Persisted boot blacklist in ${MODPROBE_CONF}"
    else
        log_info "Ephemeral mode (--ephemeral): skipped writing ${MODPROBE_CONF}"
    fi

    print_status
}

enable_fusb() {
    log_info "Enabling SiFive P550 front-panel USB-C controller (fusb303b)..."

    if [[ -f "$MODPROBE_CONF" ]]; then
        rm -f "$MODPROBE_CONF"
        log_ok "Removed boot blacklist ${MODPROBE_CONF}"
    fi

    if modprobe fusb303b 2>/dev/null; then
        log_ok "Loaded kernel module fusb303b"
    fi

    # If driver is present (modular or built-in) and not yet bound, bind matching I2C device(s)
    if [[ -d "$I2C_DRV_DIR" && -z "$(bound_i2c_devs)" ]]; then
        local candidates=()
        local d name compat
        if [[ -f "$STATE_CACHE" ]]; then
            while IFS= read -r d; do
                [[ -n "$d" ]] && candidates+=("$d")
            done < "$STATE_CACHE"
        fi
        for d in /sys/bus/i2c/devices/[0-9]*-*; do
            [[ -d "$d" ]] || continue
            name="$(cat "${d}/name" 2>/dev/null || true)"
            compat="$(tr '\0' ' ' < "${d}/of_node/compatible" 2>/dev/null || true)"
            if [[ "$name" == *fusb303* || "$compat" == *fusb303* ]]; then
                candidates+=("$(basename "$d")")
            fi
        done
        for dev_id in ${candidates[@]+"${candidates[@]}"}; do
            if [[ ! -e "${I2C_DRV_DIR}/${dev_id}" && -w "${I2C_DRV_DIR}/bind" ]]; then
                printf '%s' "$dev_id" > "${I2C_DRV_DIR}/bind" 2>/dev/null || true
                log_ok "Bound I2C client ${dev_id} to fusb303b driver"
            fi
        done
    fi

    print_status
}

case "$ACTION" in
    status)
        print_status
        ;;
    off)
        disable_fusb
        ;;
    on)
        enable_fusb
        ;;
    toggle)
        if is_fusb_active; then
            disable_fusb
        else
            enable_fusb
        fi
        ;;
esac
