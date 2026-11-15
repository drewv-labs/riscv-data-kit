#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // StarFive JH7110 / JH7110S (SiFive U74) Ubuntu BSP Bootstrapper
# Path: riscv-data-kit/bsp/starfive/jh7110/bootstrap-ubuntu.sh
# Description: Idempotent Layer 2 BSP hardening for StarFive JH7110 / JH7110S
#              (VisionFive 2, VisionFive 2 Lite, Milk-V Mars, Orange Pi RV) on Ubuntu:
#              - Protects vendor U-Boot, flash-kernel & extlinux DTB hooks
#                (preserving jh7110s-starfive-visionfive-2-lite.dtb vs jh7110 VF2 DTB)
#              - Persists primary wired NIC (end0 / eth0) via netplan
#              - Masks unstable sleep/suspend targets
#              - Locks U74 max OPP performance governor (1.50 GHz JH7110 / 1.25 GHz JH7110S)
#                with Ubuntu power-profiles-daemon guard
#              - Unlocks SiFive U74 hardware PMU counters.
#
# Usage:
#   sudo rvdk bsp [--no-apt-update] [--noprogbar]
#   curl -fsSL https://rvdk.drewv-labs.dev/bsp/starfive/jh7110/bootstrap-ubuntu.sh | sudo bash
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

# Silence SSH-forwarded LC_* warnings (ZedBook / macOS SendEnv)
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

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(
    -y
    -o DPkg::Lock::Timeout=120
    -o Dpkg::Options::="--force-confdef"
    -o Dpkg::Options::="--force-confold"
)

_APT_CANDIDATE="${RVDK_APT_LIB:-}"
[[ -z "$_APT_CANDIDATE" && -n "$_SCRIPT_DIR" && -f "${_SCRIPT_DIR}/../../../lib/apt.sh" ]] && _APT_CANDIDATE="${_SCRIPT_DIR}/../../../lib/apt.sh"
if [[ -n "$_APT_CANDIDATE" && -f "$_APT_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    source "$_APT_CANDIDATE"
else
    rvdk_apt_ensure() {
        local m=() p
        for p in "$@"; do dpkg-query -W -f='${Status}\n' "$p" 2>/dev/null | grep -qx "install ok installed" || m+=("$p"); done
        [[ ${#m[@]} -eq 0 ]] && return 0
        if [[ "${RVDK_NO_APT_UPDATE:-0}" != "1" ]] || ! compgen -G "/var/lib/apt/lists/*Packages*" >/dev/null 2>&1; then
            apt-get update -q
            export RVDK_NO_APT_UPDATE="1"
            [[ -n "${RVDK_APT_STAMP_FILE:-}" ]] && touch "$RVDK_APT_STAMP_FILE" 2>/dev/null || true
        fi
        apt-get install "${APT_FLAGS[@]}" "${m[@]}"
    }
fi

rvdk_prog_init "JH7110 Ubuntu BSP: inspecting device tree..."

log_info() { printf "\033[1;36m[RVDK:JH7110]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }

# ==============================================================================
# 1. VERIFY STARFIVE JH7110 / JH7110S DEVICE TREE
# ==============================================================================
DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
log_info "Detected Device-Tree Model: ${DT_MODEL}"

# ==============================================================================
# 2. BOOTLOADER, EXT-LINUX & FLASH-KERNEL DTB PROTECTION (VF2 & VF2 Lite)
# ==============================================================================
rvdk_prog 20 "JH7110 BSP: protecting U-Boot & DTB hooks..."
APT_BSP_CONF="/etc/apt/apt.conf.d/90-starfive-bsp-protect"
APT_BSP_CONTENT='Dpkg::Options {
   "--force-confdef";
   "--force-confold";
};'

if [[ ! -f "$APT_BSP_CONF" ]] || [[ "$(cat "$APT_BSP_CONF")" != "$APT_BSP_CONTENT" ]]; then
    echo "$APT_BSP_CONTENT" > "$APT_BSP_CONF"
    log_ok "Configured dpkg confold protection for StarFive U-Boot/DTB hooks ($APT_BSP_CONF)"
else
    log_skip "StarFive U-Boot/DTB dpkg protection already active"
fi

for boot_cfg in \
    /boot/extlinux/extlinux.conf \
    /boot/boot/extlinux/extlinux.conf \
    /boot/efi/extlinux.conf \
    /etc/default/u-boot \
    /etc/kernel/postinst.d/zz-u-boot-menu \
    /etc/flash-kernel/machine; do
    if [[ -f "$boot_cfg" && ! -f "${boot_cfg}.factory.bak" ]]; then
        cp -a "$boot_cfg" "${boot_cfg}.factory.bak"
        log_ok "Backed up factory boot artifact to ${boot_cfg}.factory.bak"
    fi
done

# ==============================================================================
# 3. PERSISTENT PRIMARY WIRED NIC (end0 / eth0) CONFIGURATION
# ==============================================================================
rvdk_prog 45 "JH7110 BSP: persisting primary wired NIC..."
PRIMARY_WIRED_NIC=""
for cand_nic in end0 eth0; do
    if ip link show "$cand_nic" >/dev/null 2>&1; then
        PRIMARY_WIRED_NIC="$cand_nic"
        break
    fi
done

if [[ -n "$PRIMARY_WIRED_NIC" ]]; then
    if command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]]; then
        if grep -rq "$PRIMARY_WIRED_NIC" /etc/netplan/ 2>/dev/null; then
            log_skip "Interface '${PRIMARY_WIRED_NIC}' is already persisted in /etc/netplan/"
        else
            NETPLAN_FILE="/etc/netplan/01-jh7110-${PRIMARY_WIRED_NIC}.yaml"
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
            log_skip "Interface '${PRIMARY_WIRED_NIC}' is already persisted in /etc/network/"
        else
            cat <<EOF > "/etc/network/interfaces.d/${PRIMARY_WIRED_NIC}"
allow-hotplug ${PRIMARY_WIRED_NIC}
iface ${PRIMARY_WIRED_NIC} inet dhcp
EOF
            log_ok "Persisted ${PRIMARY_WIRED_NIC} DHCP configuration in /etc/network/interfaces.d/${PRIMARY_WIRED_NIC}"
        fi
    fi
fi

# ==============================================================================
# 4. JH7110 / JH7110S SLEEP / SUSPEND TARGET LOCKOUT
# ==============================================================================
rvdk_prog 65 "JH7110 BSP: masking sleep/suspend targets..."
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

# ==============================================================================
# 5. LOCK CPUFREQ PERFORMANCE GOVERNOR (+ POWERPROFILESCTL GUARD)
#    (1500 MHz on JH7110 VF2/Mars/OPi-RV; 1250 MHz on JH7110S VF2 Lite)
# ==============================================================================
MAX_KHZ="$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "")"
if [[ "$MAX_KHZ" =~ ^[0-9]+$ ]] && (( MAX_KHZ > 0 )); then
    MAX_MHZ_LABEL="$(( MAX_KHZ / 1000 )) MHz"
else
    MAX_MHZ_LABEL="max OPP"
fi

rvdk_prog 82 "JH7110 BSP: locking ${MAX_MHZ_LABEL} U74 governor..."
if command -v powerprofilesctl >/dev/null 2>&1; then
    CUR_PPD="$(powerprofilesctl get 2>/dev/null || true)"
    if [[ "$CUR_PPD" != "performance" ]]; then
        if powerprofilesctl set performance 2>/dev/null; then
            log_ok "Pinned Ubuntu power-profiles-daemon to 'performance'"
        fi
    else
        log_skip "power-profiles-daemon already set to 'performance'"
    fi
fi

GOV_UNIT="/etc/systemd/system/jh7110-cpufreq-performance.service"
GOV_UNIT_CONTENT='[Unit]
Description=Lock StarFive JH7110/JH7110S SiFive U74 Harts to Performance Governor
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
    systemctl enable --now jh7110-cpufreq-performance.service >/dev/null
    log_ok "Enabled persistent ${MAX_MHZ_LABEL} performance governor service ($GOV_UNIT)"
else
    systemctl start jh7110-cpufreq-performance.service 2>/dev/null || true
    log_skip "U74 performance governor service (${MAX_MHZ_LABEL}) already active"
fi

# ==============================================================================
# 6. HARDWARE PMU COUNTER UNLOCK (SiFive U74)
# ==============================================================================
rvdk_prog 92 "JH7110 BSP: unlocking SiFive U74 PMU counters..."
PMU_SYSCTL="/etc/sysctl.d/90-starfive-u74-pmu.conf"
PMU_CONTENT="# Unlock SiFive U74 hardware performance counters for Linux perf & PMU telemetry
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = 0"

if [[ ! -f "$PMU_SYSCTL" ]] || [[ "$(cat "$PMU_SYSCTL")" != "$PMU_CONTENT" ]]; then
    echo "$PMU_CONTENT" > "$PMU_SYSCTL"
    sysctl --system >/dev/null 2>&1 || sysctl -p "$PMU_SYSCTL" >/dev/null 2>&1 || true
    log_ok "Unlocked SiFive U74 PMU counters in $PMU_SYSCTL"
else
    log_skip "SiFive U74 PMU sysctls already configured"
fi

rvdk_prog 100 "StarFive JH7110/JH7110S Ubuntu BSP hardening complete"
log_info "StarFive JH7110/JH7110S (Ubuntu) BSP bootstrap complete."
