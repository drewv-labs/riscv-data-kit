#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // SpacemiT K1 / M1 (8x X60 RVA22 + RVV 1.0) Silicon BSP
# Path: riscv-data-kit/bsp/spacemit/k1/forge.sh
# Boards: Orange Pi RV2, Orange Pi R2S, Banana Pi BPI-F3, BPI-CM6, Milk-V Jupiter
# OSes:   SpacemiT Bianbu OS, Ubuntu 24.04+, Debian / Armbian, OpenWrt (procd)
# ==============================================================================

set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    else
        echo "[RVDK:FATAL] Pipe into 'sudo bash': curl -fsSL ... | sudo bash" >&2
        exit 1
    fi
fi

if { locale -a 2>/dev/null || true; } | grep -qiE '^en_US\.utf-?8$'; then
    export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
elif { locale -a 2>/dev/null || true; } | grep -qiE '^C\.utf-?8$'; then
    export LANG="C.UTF-8" LC_ALL="C.UTF-8"
else
    export LANG="C" LC_ALL="C"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-apt-update|--skip-apt-update) export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)          export RVDK_NO_PROGBAR="1"; shift ;;
        *)                                 shift ;;
    esac
done

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

_PROGBAR_CANDIDATE="${RVDK_PROGBAR_LIB:-}"
[[ -z "$_PROGBAR_CANDIDATE" && -n "$_SCRIPT_DIR" && -f "${_SCRIPT_DIR}/../../../lib/progbar.sh" ]] && _PROGBAR_CANDIDATE="${_SCRIPT_DIR}/../../../lib/progbar.sh"
if [[ -n "$_PROGBAR_CANDIDATE" && -f "$_PROGBAR_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    source "$_PROGBAR_CANDIDATE"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_prog_init "SpacemiT K1 BSP: inspecting device tree..."

log_info() { printf "\033[1;36m[RVDK:SPACEMIT-K1]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }

DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
log_info "Detected Device-Tree Model: ${DT_MODEL}"

# 1. Bootloader, U-Boot Env & DTB Protection (Bianbu / Ubuntu / Armbian; skipped on OpenWrt)
rvdk_prog 20 "SpacemiT K1 BSP: protecting U-Boot & DTB hooks..."
if [[ -d /etc/apt/apt.conf.d ]]; then
    APT_BSP_CONF="/etc/apt/apt.conf.d/90-spacemit-bsp-protect"
    APT_BSP_CONTENT='Dpkg::Options {
   "--force-confdef";
   "--force-confold";
};'
    if [[ ! -f "$APT_BSP_CONF" ]] || [[ "$(cat "$APT_BSP_CONF")" != "$APT_BSP_CONTENT" ]]; then
        echo "$APT_BSP_CONTENT" > "$APT_BSP_CONF"
        log_ok "Configured dpkg confold protection for SpacemiT U-Boot/DTB hooks ($APT_BSP_CONF)"
    else
        log_skip "SpacemiT U-Boot/DTB dpkg protection already active"
    fi
else
    log_skip "Non-APT rootfs (e.g. OpenWrt); skipping dpkg confold hook"
fi

for boot_cfg in \
    /boot/env_k1-x.txt \
    /boot/spacemit/env_k1-x.txt \
    /boot/extlinux/extlinux.conf \
    /boot/efi/extlinux.conf \
    /boot/armbianEnv.txt \
    /etc/default/u-boot; do
    if [[ -f "$boot_cfg" && ! -f "${boot_cfg}.factory.bak" ]]; then
        cp -a "$boot_cfg" "${boot_cfg}.factory.bak"
        log_ok "Backed up factory boot artifact to ${boot_cfg}.factory.bak"
    fi
done

# 2. Persist Primary Wired NIC (end0 / eth0) when unmanaged (untouched on OpenWrt netifd)
rvdk_prog 45 "SpacemiT K1 BSP: checking primary wired NIC..."
if [[ -f /etc/openwrt_release ]]; then
    log_skip "OpenWrt netifd manages LAN/WAN interfaces (/etc/config/network); leaving untouched"
else
    PRIMARY_WIRED_NIC=""
    for cand_nic in end0 eth0; do
        if ip link show "$cand_nic" >/dev/null 2>&1; then
            PRIMARY_WIRED_NIC="$cand_nic"
            break
        fi
    done

    if [[ -n "$PRIMARY_WIRED_NIC" ]]; then
        if command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]]; then
            if grep -rqE "(${PRIMARY_WIRED_NIC}|NetworkManager)" /etc/netplan/ 2>/dev/null; then
                log_skip "Interface '${PRIMARY_WIRED_NIC}' already managed in /etc/netplan/"
            else
                NETPLAN_FILE="/etc/netplan/01-spacemit-${PRIMARY_WIRED_NIC}.yaml"
                cat <<EOF > "$NETPLAN_FILE"
network:
  version: 2
  ethernets:
    ${PRIMARY_WIRED_NIC}:
      dhcp4: true
      optional: true
EOF
                chmod 0600 "$NETPLAN_FILE"
                netplan apply
                log_ok "Persisted ${PRIMARY_WIRED_NIC} DHCP configuration in ${NETPLAN_FILE}"
            fi
        elif [[ -d /etc/network/interfaces.d ]]; then
            if grep -rqE "iface ${PRIMARY_WIRED_NIC}\\b" /etc/network/ 2>/dev/null; then
                log_skip "Interface '${PRIMARY_WIRED_NIC}' already persisted in /etc/network/"
            else
                cat <<EOF > "/etc/network/interfaces.d/${PRIMARY_WIRED_NIC}"
allow-hotplug ${PRIMARY_WIRED_NIC}
iface ${PRIMARY_WIRED_NIC} inet dhcp
EOF
                log_ok "Persisted ${PRIMARY_WIRED_NIC} DHCP configuration in /etc/network/interfaces.d/${PRIMARY_WIRED_NIC}"
            fi
        fi
    fi
fi

# 3. Mask Sleep / Suspend Targets (systemd)
rvdk_prog 65 "SpacemiT K1 BSP: masking sleep/suspend targets..."
if command -v systemctl >/dev/null 2>&1; then
    SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
    NEED_MASK="false"
    for tgt in "${SLEEP_TARGETS[@]}"; do
        if [[ "$(systemctl is-enabled "$tgt" 2>/dev/null || true)" != "masked" ]]; then
            NEED_MASK="true"
            break
        fi
    done
    if [[ "$NEED_MASK" == "true" ]]; then
        systemctl mask "${SLEEP_TARGETS[@]}" 2>/dev/null || true
        log_ok "Masked sleep/suspend/hibernate targets"
    else
        log_skip "Sleep/suspend targets already masked"
    fi
else
    log_skip "systemd not present (procd); sleep target mask not required"
fi

# 4. Lock 8x SpacemiT X60 Harts to Performance Governor (systemd or OpenWrt procd)
rvdk_prog 82 "SpacemiT K1 BSP: locking 8x X60 performance governor..."
if command -v systemctl >/dev/null 2>&1; then
    if command -v powerprofilesctl >/dev/null 2>&1; then
        [[ "$(powerprofilesctl get 2>/dev/null || true)" != "performance" ]] && powerprofilesctl set performance 2>/dev/null || true
    fi

    GOV_UNIT="/etc/systemd/system/spacemit-k1-cpufreq-performance.service"
    GOV_UNIT_CONTENT='[Unit]
Description=Lock SpacemiT K1/M1 X60 Harts to Performance Governor
After=multi-user.target power-profiles-daemon.service ondemand.service cpufrequtils.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c "[ -x /usr/bin/powerprofilesctl ] && /usr/bin/powerprofilesctl set performance >/dev/null 2>&1 || true; for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do [ -f \"$g\" ] && echo performance > \"$g\" || true; done"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target'

    if ! printf "%s\n" "$GOV_UNIT_CONTENT" | cmp -s - "$GOV_UNIT" 2>/dev/null; then
        printf "%s\n" "$GOV_UNIT_CONTENT" > "$GOV_UNIT"
        systemctl daemon-reload
        systemctl enable --now spacemit-k1-cpufreq-performance.service >/dev/null
        log_ok "Enabled persistent SpacemiT X60 performance governor service ($GOV_UNIT)"
    else
        systemctl start spacemit-k1-cpufreq-performance.service 2>/dev/null || true
        log_skip "SpacemiT X60 performance governor service already active"
    fi
elif [[ -f /etc/rc.common ]]; then
    PROCD_GOV="/etc/init.d/spacemit-k1-cpufreq"
    for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ -f "$g" ]] && echo performance > "$g" 2>/dev/null || true
    done
    if [[ ! -x "$PROCD_GOV" ]]; then
        cat << 'PROCD_EOF' > "$PROCD_GOV"
#!/bin/sh /etc/rc.common
START=95
start() {
    for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -f "$g" ] && echo performance > "$g" 2>/dev/null || true
    done
}
PROCD_EOF
        chmod +x "$PROCD_GOV"
        "$PROCD_GOV" enable 2>/dev/null || true
        log_ok "Enabled OpenWrt procd SpacemiT X60 performance governor ($PROCD_GOV)"
    else
        log_skip "OpenWrt procd SpacemiT X60 performance governor already enabled"
    fi
fi

# 5. Unlock SpacemiT X60 Hardware PMU Counters
rvdk_prog 92 "SpacemiT K1 BSP: unlocking X60 PMU counters..."
mkdir -p /etc/sysctl.d
PMU_SYSCTL="/etc/sysctl.d/90-spacemit-x60-pmu.conf"
PMU_CONTENT="# Unlock SpacemiT X60 hardware performance counters for Linux perf & PMU telemetry
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = 0"

if [[ ! -f "$PMU_SYSCTL" ]] || [[ "$(cat "$PMU_SYSCTL")" != "$PMU_CONTENT" ]]; then
    echo "$PMU_CONTENT" > "$PMU_SYSCTL"
    sysctl --system >/dev/null 2>&1 || sysctl -p "$PMU_SYSCTL" >/dev/null 2>&1 || true
    log_ok "Unlocked SpacemiT X60 PMU counters in $PMU_SYSCTL"
else
    log_skip "SpacemiT X60 PMU sysctls already configured"
fi

rvdk_prog 100 "SpacemiT K1/M1 BSP hardening complete"
log_info "SpacemiT K1/M1 BSP bootstrap complete."
