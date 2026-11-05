#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // StarFive VisionFive 2 (JH7110 / SiFive U74) BSP Bootstrapper
# Path: drewv-labs/riscv-data-kit/starfive/visionfive2/bootstrap.sh
# Description: Idempotent Layer 2 BSP hardening for StarFive VisionFive 2:
#              - Protects vendor U-Boot hooks (/etc/kernel/postinst.d/zz-u-boot-menu)
#              - Migrates dead 2023 debian-ports snapshot to official Debian sid
#              - Purges Wayland/Weston/X11/GTK & unblocks t64 prior to full-upgrade
#              - Persists eth0 DHCP, masks sleep targets, locks 1500 MHz governor,
#                and unlocks SiFive U74 PMU counters.
#
# Usage:
#   sudo ./starfive/visionfive2/bootstrap.sh [--skip-upgrade]
# ==============================================================================

set -Eeuo pipefail

SKIP_UPGRADE="false"
for arg in "$@"; do
    case "$arg" in
        --skip-upgrade) SKIP_UPGRADE="true" ;;
    esac
done

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(
    -y
    -o DPkg::Lock::Timeout=120
    -o Dpkg::Options::="--force-overwrite"
    -o Dpkg::Options::="--force-confdef"
    -o Dpkg::Options::="--force-confold"
)

log_info() { printf "\033[1;36m[INFO]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn() { printf "\033[1;31m[WARN]\033[0m %s\n" "$1"; }

if [[ $EUID -ne 0 ]]; then
    echo "Escalating privileges via sudo..."
    exec sudo -E bash "$0" "$@"
fi

# ==============================================================================
# 1. VERIFY STARFIVE JH7110 DEVICE TREE
# ==============================================================================
DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
log_info "Detected Device-Tree Model: ${DT_MODEL}"

# ==============================================================================
# 2. BOOTLOADER, FIT & VENDOR U-BOOT HOOK PROTECTION (zz-u-boot-menu)
# ==============================================================================
APT_BSP_CONF="/etc/apt/apt.conf.d/90-starfive-bsp-protect"
APT_BSP_CONTENT='Dpkg::Options {
   "--force-overwrite";
   "--force-confdef";
   "--force-confold";
};'

if [[ ! -f "$APT_BSP_CONF" ]] || [[ "$(cat "$APT_BSP_CONF")" != "$APT_BSP_CONTENT" ]]; then
    echo "$APT_BSP_CONTENT" > "$APT_BSP_CONF"
    log_ok "Configured dpkg confold protection for StarFive U-Boot/DTB hooks ($APT_BSP_CONF)"
else
    log_skip "StarFive U-Boot/DTB dpkg protection already active"
fi

for boot_cfg in /boot/extlinux/extlinux.conf /boot/boot/extlinux/extlinux.conf /etc/default/u-boot /etc/kernel/postinst.d/zz-u-boot-menu; do
    if [[ -f "$boot_cfg" && ! -f "${boot_cfg}.factory.bak" ]]; then
        cp -a "$boot_cfg" "${boot_cfg}.factory.bak"
        log_ok "Backed up factory boot artifact to ${boot_cfg}.factory.bak"
    fi
done

# ==============================================================================
# 3. MIGRATE 2023 SNAPSHOT REPOS, PURGE GUI & UNBLOCK T64 UPGRADE
# ==============================================================================
DESIRED_SOURCES="deb http://deb.debian.org/debian unstable main
deb https://debianrepo-t.starfivetech.com starfive-debian main"

if grep -qE "snapshot\.debian\.org|debian-ports|VF2-Lite" /etc/apt/sources.list 2>/dev/null || \
   ! grep -q "http://deb.debian.org/debian" /etc/apt/sources.list 2>/dev/null; then
    log_info "Migrating /etc/apt/sources.list from factory snapshot to official Debian unstable..."
    rm -f /etc/apt/trusted.gpg.d/debian-ports* 2>/dev/null || true

    cat << 'EOF' > /etc/apt/sources.list
deb [trusted=yes] http://deb.debian.org/debian unstable main
deb https://debianrepo-t.starfivetech.com starfive-debian main
EOF

    rm -rf /var/lib/apt/lists/*
    apt-get clean
    apt-get -o Acquire::Check-Valid-Until=false update -y
    apt-get install "${APT_FLAGS[@]}" --allow-unauthenticated debian-archive-keyring

    echo "$DESIRED_SOURCES" > /etc/apt/sources.list
    apt-get update -y
    log_ok "Migrated APT sources to official Debian unstable + StarFive BSP repo"
else
    log_skip "APT sources (/etc/apt/sources.list) already pointing to official Debian unstable"
fi

if [[ "$(systemctl get-default)" != "multi-user.target" ]]; then
    systemctl set-default multi-user.target
    log_ok "Boot target set to headless multi-user.target"
else
    log_skip "Boot target is already multi-user.target"
fi

# Strip frozen 2023 Wayland/Weston/X11/GTK packages BEFORE full-upgrade to prevent t64 collisions
VF2_GUI_PKGS=(
    "weston*" "wayland*" "x11-common" "libx11-*" "libgtk*"
    "lightdm*" "task-desktop" "plymouth"
)
NEED_GUI_PURGE="false"
for pattern in weston x11-common lightdm task-desktop plymouth; do
    if dpkg -l "$pattern" 2>/dev/null | grep -q "^ii"; then
        NEED_GUI_PURGE="true"
        break
    fi
done

if [[ "$NEED_GUI_PURGE" == "true" ]]; then
    log_info "Purging StarFive desktop GUI packages prior to t64 upgrade..."
    apt-get purge "${APT_FLAGS[@]}" "${VF2_GUI_PKGS[@]}" || true
    apt-get autoremove "${APT_FLAGS[@]}" --purge
    apt-get clean
    log_ok "Purged Wayland, Weston, X11, GTK, and LightDM desktop bloat"
else
    log_skip "Desktop GUI packages already purged"
fi

# Unblock libcurl3-gnutls t64 transition dependency if present
if dpkg -l 2>/dev/null | grep -q "^ii.*libcurl3-gnutls"; then
    dpkg --remove --force-depends libcurl3-gnutls:riscv64 2>/dev/null || true
    log_ok "Removed legacy libcurl3-gnutls:riscv64 t64 blocker"
fi

if [[ "$SKIP_UPGRADE" == "false" ]]; then
    log_info "Running non-interactive full-upgrade and installing core JH7110 packages..."
    apt-get update -q
    apt-get full-upgrade "${APT_FLAGS[@]}"
    apt-get install "${APT_FLAGS[@]}" \
        build-essential dkms pciutils nvme-cli lvm2 parted git curl wget \
        htop jq tmux bc rsync time sysstat linux-perf
    apt-get install "${APT_FLAGS[@]}" "linux-headers-$(uname -r)" 2>/dev/null || true
    log_ok "System packages and JH7110 utilities converged"
else
    log_skip "Skipped apt-get full-upgrade (--skip-upgrade)"
fi

# ==============================================================================
# 4. PERSISTENT PRIMARY NIC (eth0) CONFIGURATION
# ==============================================================================
if ip link show eth0 >/dev/null 2>&1; then
    if [[ -d /etc/network/interfaces.d ]]; then
        if grep -rqE "iface (eth0|end0)" /etc/network/ 2>/dev/null; then
            log_skip "Interface 'eth0' is already persisted in /etc/network/"
        else
            cat << 'EOF' > /etc/network/interfaces.d/eth0
allow-hotplug eth0
iface eth0 inet dhcp
EOF
            log_ok "Persisted eth0 DHCP configuration in /etc/network/interfaces.d/eth0"
        fi
    fi
fi

# ==============================================================================
# 5. JH7110 SLEEP TARGET LOCKOUT & BACKGROUND APT TIMER MASK
# ==============================================================================
MASK_UNITS=(
    sleep.target suspend.target hibernate.target hybrid-sleep.target
    apt-daily.timer apt-daily-upgrade.timer
)
NEED_MASK="false"
for unit in "${MASK_UNITS[@]}"; do
    if [[ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" != "masked" ]]; then
        NEED_MASK="true"
        break
    fi
done

if [[ "$NEED_MASK" == "true" ]]; then
    systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl mask "${MASK_UNITS[@]}" 2>/dev/null || true
    log_ok "Masked sleep/suspend targets and background apt-daily timers"
else
    log_skip "Sleep/suspend targets and apt-daily timers already masked"
fi

# ==============================================================================
# 6. LOCK 1500 MHz CPUFREQ PERFORMANCE GOVERNOR & UNLOCK U74 PMU COUNTERS
# ==============================================================================
GOV_UNIT="/etc/systemd/system/jh7110-cpufreq-performance.service"
GOV_UNIT_CONTENT='[Unit]
Description=Lock StarFive JH7110 SiFive U74 Harts to 1500 MHz Performance Governor
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do [ -f \"$g\" ] && echo performance > \"$g\" || true; done"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target'

if [[ ! -f "$GOV_UNIT" ]] || [[ "$(cat "$GOV_UNIT")" != "$GOV_UNIT_CONTENT" ]]; then
    echo "$GOV_UNIT_CONTENT" > "$GOV_UNIT"
    systemctl daemon-reload
    systemctl enable --now jh7110-cpufreq-performance.service >/dev/null
    log_ok "Enabled persistent 1500 MHz performance governor service ($GOV_UNIT)"
else
    systemctl start jh7110-cpufreq-performance.service 2>/dev/null || true
    log_skip "1500 MHz performance governor service already active"
fi

PMU_SYSCTL="/etc/sysctl.d/90-starfive-u74-pmu.conf"
PMU_CONTENT="# Unlock SiFive U74 hardware performance counters for CarrierPigeons / perf
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = 0"

if [[ ! -f "$PMU_SYSCTL" ]] || [[ "$(cat "$PMU_SYSCTL")" != "$PMU_CONTENT" ]]; then
    echo "$PMU_CONTENT" > "$PMU_SYSCTL"
    sysctl -p "$PMU_SYSCTL" >/dev/null 2>&1 || true
    log_ok "Unlocked SiFive U74 PMU counters in $PMU_SYSCTL"
else
    log_skip "SiFive U74 PMU sysctls already configured"
fi

log_info "StarFive VisionFive 2 (JH7110) BSP bootstrap complete."
