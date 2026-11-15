#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // SiFive Freedom U740 (4x U74 — HiFive Unmatched) Silicon BSP
# Path: riscv-data-kit/bsp/sifive/fu740/forge.sh
# ==============================================================================

set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    echo "[RVDK:FATAL] Run as root." >&2; exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-apt-update|--skip-apt-update) export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)          export RVDK_NO_PROGBAR="1"; shift ;;
        *)                                 shift ;;
    esac
done

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROGBAR_CANDIDATE="${RVDK_PROGBAR_LIB:-${_SCRIPT_DIR}/../../../lib/progbar.sh}"
if [[ -f "$_PROGBAR_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    source "$_PROGBAR_CANDIDATE"
else
    rvdk_prog_init() { :; }; rvdk_prog() { :; }
fi

rvdk_prog_init "SiFive FU740 BSP: inspecting device tree..."
log_info() { printf "\033[1;36m[RVDK:FU740]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }

DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
log_info "Detected Device-Tree Model: ${DT_MODEL}"

rvdk_prog 30 "SiFive FU740 BSP: protecting U-Boot & extlinux hooks..."
APT_BSP_CONF="/etc/apt/apt.conf.d/90-sifive-fu740-bsp-protect"
APT_BSP_CONTENT='Dpkg::Options {
   "--force-confdef";
   "--force-confold";
};'
if [[ ! -f "$APT_BSP_CONF" ]] || [[ "$(cat "$APT_BSP_CONF")" != "$APT_BSP_CONTENT" ]]; then
    echo "$APT_BSP_CONTENT" > "$APT_BSP_CONF"
    log_ok "Configured dpkg confold protection ($APT_BSP_CONF)"
else
    log_skip "SiFive FU740 dpkg protection already active"
fi

rvdk_prog 65 "SiFive FU740 BSP: masking sleep/suspend targets..."
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
NEED_MASK="false"
for tgt in "${SLEEP_TARGETS[@]}"; do
    [[ "$(systemctl is-enabled "$tgt" 2>/dev/null || true)" != "masked" ]] && NEED_MASK="true" && break
done
if [[ "$NEED_MASK" == "true" ]]; then
    systemctl mask "${SLEEP_TARGETS[@]}" 2>/dev/null || true
    log_ok "Masked sleep/suspend/hibernate targets"
else
    log_skip "Sleep/suspend targets already masked"
fi

rvdk_prog 85 "SiFive FU740 BSP: locking U74 governor & unlocking PMU..."
GOV_UNIT="/etc/systemd/system/fu740-cpufreq-performance.service"
GOV_UNIT_CONTENT='[Unit]
Description=Lock SiFive Freedom U740 U74 Harts to Performance Governor
After=multi-user.target power-profiles-daemon.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c "[ -x /usr/bin/powerprofilesctl ] && /usr/bin/powerprofilesctl set performance >/dev/null 2>&1 || true; for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do [ -f \"$g\" ] && echo performance > \"$g\" || true; done"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target'

if ! printf "%s\n" "$GOV_UNIT_CONTENT" | cmp -s - "$GOV_UNIT" 2>/dev/null; then
    printf "%s\n" "$GOV_UNIT_CONTENT" > "$GOV_UNIT"
    systemctl daemon-reload
    systemctl enable --now fu740-cpufreq-performance.service >/dev/null
    log_ok "Enabled persistent FU740 U74 performance governor service ($GOV_UNIT)"
else
    systemctl start fu740-cpufreq-performance.service 2>/dev/null || true
    log_skip "FU740 U74 performance governor service already active"
fi

PMU_SYSCTL="/etc/sysctl.d/90-sifive-u74-pmu.conf"
PMU_CONTENT="# Unlock SiFive U74 hardware performance counters
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = 0"
if [[ ! -f "$PMU_SYSCTL" ]] || [[ "$(cat "$PMU_SYSCTL")" != "$PMU_CONTENT" ]]; then
    echo "$PMU_CONTENT" > "$PMU_SYSCTL"
    sysctl --system >/dev/null 2>&1 || sysctl -p "$PMU_SYSCTL" >/dev/null 2>&1 || true
    log_ok "Unlocked SiFive U74 PMU counters in $PMU_SYSCTL"
else
    log_skip "SiFive U74 PMU sysctls already configured"
fi

rvdk_prog 100 "SiFive FU740 BSP hardening complete"
log_info "SiFive FU740 BSP bootstrap complete."
