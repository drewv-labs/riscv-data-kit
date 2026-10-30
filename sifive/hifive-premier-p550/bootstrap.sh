#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // SiFive HiFive Premier P550 (ESWIN EIC7700X) BSP Bootstrapper
# Path: riscv-data-kit/sifive/hifive-premier-p550/bootstrap.sh
# Description: Silicon, bootloader, thermal, network (end0), and PMU counter
#              hardening for SiFive HiFive Premier P550 on Ubuntu or Debian.
#
# Usage:
#   sudo ./sifive/hifive-premier-p550/bootstrap.sh
# ==============================================================================

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# --- Logging Helpers ---
log_info() { printf "\033[1;36m[INFO]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn() { printf "\033[1;31m[WARN]\033[0m %s\n" "$1"; }

if [[ $EUID -ne 0 ]]; then
    echo "Escalating privileges via sudo..."
    exec sudo -E bash "$0" "$@"
fi

# ==============================================================================
# 1. VERIFY SIFIVE P550 / ESWIN EIC7700X DEVICE TREE
# ==============================================================================
DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
log_info "Detected Device-Tree Model: ${DT_MODEL}"

# ==============================================================================
# 2. BOOTLOADER & VENDOR DTB PROTECTION (Debian & Ubuntu)
# ==============================================================================
# Prevent unattended apt upgrades from overwriting vendor U-Boot / extlinux hooks
APT_BSP_CONF="/etc/apt/apt.conf.d/90-p550-bsp-protect"
APT_BSP_CONTENT='Dpkg::Options {
   "--force-confdef";
   "--force-confold";
};'

if [[ ! -f "$APT_BSP_CONF" ]] || [[ "$(cat "$APT_BSP_CONF")" != "$APT_BSP_CONTENT" ]]; then
    echo "$APT_BSP_CONTENT" > "$APT_BSP_CONF"
    log_ok "Configured dpkg confold protection for vendor U-Boot/DTB hooks ($APT_BSP_CONF)"
else
    log_skip "Vendor U-Boot/DTB dpkg protection already active"
fi

# Back up factory extlinux.conf if present and not yet backed up
for ext_path in /boot/extlinux/extlinux.conf /boot/efi/extlinux/extlinux.conf; do
    if [[ -f "$ext_path" && ! -f "${ext_path}.factory.bak" ]]; then
        cp -a "$ext_path" "${ext_path}.factory.bak"
        log_ok "Backed up factory bootloader config to ${ext_path}.factory.bak"
    fi
done

# ==============================================================================
# 3. PERSISTENT PRIMARY NIC (end0) CONFIGURATION
# ==============================================================================
if ip link show end0 >/dev/null 2>&1; then
    if command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]]; then
        if grep -rq "end0" /etc/netplan/ 2>/dev/null; then
            log_skip "Interface 'end0' is already persisted in /etc/netplan/"
        else
            cat << 'EOF' > /etc/netplan/01-p550-end0.yaml
network:
  version: 2
  ethernets:
    end0:
      dhcp4: true
      optional: true
EOF
            chmod 0600 /etc/netplan/01-p550-end0.yaml
            netplan apply
            log_ok "Persisted end0 DHCP configuration in /etc/netplan/01-p550-end0.yaml"
        fi
    elif [[ -d /etc/network/interfaces.d ]]; then
        if grep -rq "end0" /etc/network/ 2>/dev/null; then
            log_skip "Interface 'end0' is already persisted in /etc/network/"
        else
            cat << 'EOF' > /etc/network/interfaces.d/end0
allow-hotplug end0
iface end0 inet dhcp
EOF
            log_ok "Persisted end0 DHCP configuration in /etc/network/interfaces.d/end0"
        fi
    fi
fi

# ==============================================================================
# 4. EIC7700X SOC SLEEP / SUSPEND TARGET LOCKOUT
# ==============================================================================
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
NEED_MASK="false"
for tgt in "${SLEEP_TARGETS[@]}"; do
    if [[ "$(systemctl is-enabled "$tgt" 2>/dev/null || true)" != "masked" ]]; then
        NEED_MASK="true"
        break
    fi
done

if [[ "$NEED_MASK" == "true" ]]; then
    systemctl mask "${SLEEP_TARGETS[@]}"
    log_ok "Masked sleep/suspend/hibernate targets (prevents EIC7700X SoC lockups)"
else
    log_skip "Sleep/suspend targets already masked"
fi

# ==============================================================================
# 5. SOM PWM FAN CONTROLLER & HARDWARE PMU COUNTER UNLOCK
# ==============================================================================
if apt-cache show fancontrol-config-p550-premier >/dev/null 2>&1; then
    if ! dpkg -s fancontrol-config-p550-premier >/dev/null 2>&1; then
        apt-get update -q
        apt-get install "${APT_FLAGS[@]}" fancontrol-config-p550-premier
        log_ok "Installed fancontrol-config-p550-premier"
    else
        log_skip "fancontrol-config-p550-premier already installed"
    fi
fi

PMU_SYSCTL="/etc/sysctl.d/90-sifive-p550-pmu.conf"
PMU_CONTENT="# Unlock SiFive P550 L1/PL2/L3 hardware performance counters for CarrierPigeons / perf
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = 0"

if [[ ! -f "$PMU_SYSCTL" ]] || [[ "$(cat "$PMU_SYSCTL")" != "$PMU_CONTENT" ]]; then
    echo "$PMU_CONTENT" > "$PMU_SYSCTL"
    sysctl --system >/dev/null
    log_ok "Unlocked SiFive P550 PMU counters in $PMU_SYSCTL"
else
    log_skip "SiFive P550 PMU sysctls already configured"
fi

log_info "SiFive HiFive Premier P550 BSP bootstrap complete."
