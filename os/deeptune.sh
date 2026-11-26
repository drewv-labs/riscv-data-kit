#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Layer 1: Universal Headless OS DeepTune (`os/deeptune.sh`)
# Path: riscv-data-kit/os/deeptune.sh
#
# Description:
#   Silicon- and board-agnostic headless Linux OS deep-tuning across Debian,
#   Ubuntu, Bianbu, and OpenWrt RISC-V nodes:
#     • Retires vendor Armbian/OrangePi ephemeral 50M `ramlog` & 50% RAM `zram`
#       swap overlays so all Debian/Ubuntu SBCs share deterministic VM & log parity
#     • Configures persistent bounded `systemd-journald` (`Storage=persistent`,
#       `SystemMaxUse=256M`) BEFORE retiring `rsyslog` so boot/SSH logs survive reboot
#     • Silences periodic background polling (`smartd` & `sysstat` timers) while
#       preserving on-demand diagnostic CLIs (`smartctl`, `iostat`, `mpstat`, `pidstat`)
#     • Masks OS/desktop/filesystem background jitter timers (`fwupd-refresh`,
#       `motd-news`, `update-notifier`, `man-db`, `e2scrub_all`, `apt-daily*`)
#     • Stops, masks & purges workstation, printer, audio, Wi-Fi & SAN bloat
#       (`firefox`, `cups*`, `fwupd`, `multipathd`, `avahi`, `udisks2`, `upower`,
#       `wpa_supplicant`, `rsyslog`, `pipewire*`, `wireplumber`, `network-manager-*-gnome`,
#       plus `NetworkManager` when `systemd-networkd` owns the primary NIC) and
#       runs `apt-get autoremove --purge` so transitive GUI/printer orphans are reaped
#     • Defers unattended `needrestart` auto-bounces of stateful broker daemons
#     • Locks down per-SSH `systemd --user` PipeWire & GNOME Keyring sockets
#     • Unloads & blacklists universal non-server kernel modules (`cfg80211`,
#       `joydev`, `input_leds`, `apple_mfi_fastcharge`, `dm_multipath`, `nvme_fabrics`)
#     • Applies reversible Transparent HugePages policy (`--tune data` / `iot`
#       -> `never`, `--tune ai` -> `madvise`), flash-friendly volatile journald
#       & wireless/sensor preservation (`--tune iot`), and headless sysctls
# ==============================================================================
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/.." && pwd)"
: "$_REPO_ROOT"

# @RVDK_INLINE_LIBS: common kit progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:OS-DEEPTUNE]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_atomic_write() {
            local _dst="$1" _mode="${2:-0644}" _tmp
            mkdir -p "$(dirname "$_dst")"
            _tmp="$(mktemp "$(dirname "$_dst")/.$(basename "$_dst").rvdk.XXXXXX")"
            cat > "$_tmp"
            chmod "$_mode" "$_tmp"
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
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]]; then
        # shellcheck source=lib/progbar.sh
        source "${_REPO_ROOT}/lib/progbar.sh"
    else
        rvdk_prog_init() { :; }
        rvdk_prog()      { :; }
    fi
fi

rvdk_log_init "RVDK:OS-DEEPTUNE"

usage() {
    cat <<EOF
Usage: sudo $0 [--tune <data|ai|iot>] [--force] [--no-apt-update] [--noprogbar]
EOF
}

ORIG_ARGS=("$@")
TUNE_REQUEST="${RVDK_TUNE:-data}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tune)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument: data | ai | iot"
            TUNE_REQUEST="$2"
            shift 2
            ;;
        --tune=*)
            TUNE_REQUEST="${1#*=}"
            shift
            ;;
        data|ai|ml|edge-ai|edge-ml|iot|edge-iot|sensor|mcu)
            TUNE_REQUEST="$1"
            shift
            ;;
        --force)   shift ;;
        --no-apt-update|--skip-apt-update) export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)          export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_fatal "Unknown argument: $1 (try --help)" ;;
    esac
done

TUNE_REQUEST="$(tr '[:upper:]' '[:lower:]' <<< "$TUNE_REQUEST")"
case "$TUNE_REQUEST" in
    data)                    TUNE_MODE="data"; TUNE_LABEL="data" ;;
    ai|ml|edge-ai|edge-ml)   TUNE_MODE="ai";   TUNE_LABEL="ai" ;;
    iot|edge-iot|sensor|mcu) TUNE_MODE="iot";  TUNE_LABEL="iot" ;;
    *) log_fatal "Invalid --tune '${TUNE_REQUEST}' (expected: data | ai | iot)" ;;
esac

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    else
        log_fatal "Run as root."
    fi
fi

if typeset -f rvdk_kit_resolve >/dev/null 2>&1; then
    rvdk_kit_resolve
fi

if [[ -z "${RVDK_PRIMARY_NIC:-}" ]] && command -v ip >/dev/null 2>&1; then
    RVDK_PRIMARY_NIC="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
fi

rvdk_prog_init "OS DeepTune (--tune ${TUNE_LABEL}): inspecting services & timers..."
log_info "Converging headless OS DeepTune (--tune ${TUNE_LABEL} | NIC=${RVDK_PRIMARY_NIC:-auto})..."

# Guard against severing SSH when primary default-route NIC is wireless (e.g. wlan0 on bench/field SBC)
PRIMARY_NIC="${RVDK_PRIMARY_NIC:-}"
PRIMARY_IS_WIFI="false"
if [[ -n "$PRIMARY_NIC" ]] && [[ "$PRIMARY_NIC" == wl* || -d "/sys/class/net/${PRIMARY_NIC}/wireless" ]]; then
    PRIMARY_IS_WIFI="true"
    if [[ "$TUNE_MODE" != "iot" ]]; then
        log_warn "Primary NIC '${PRIMARY_NIC}' is wireless; preserving wpa_supplicant & cfg80211 to protect active SSH link"
    fi
fi

# OpenWrt / non-systemd / riscv32 nommu fast-path: apply THP + BusyBox-compatible sysctls without systemd/APT calls
if [[ "${RVDK_OS_ID:-}" == "openwrt" || "${RVDK_OS_ID:-}" == "buildroot" || "${RVDK_OS_ID:-}" == "linux-nommu" || "${RVDK_OS_ID:-}" == "esp-idf" || "${RVDK_OS_ID:-}" == "nuttx" || "${RVDK_MMU:-}" == "none" || "${RVDK_ARCH:-}" == "riscv32" || -f /etc/openwrt_release ]] || ! command -v systemctl >/dev/null 2>&1; then
    if [[ "${RVDK_OS_ID:-}" == "esp-idf" || "${RVDK_OS_ID:-}" == "nuttx" || ! -d /proc/sys ]]; then
        log_skip "Non-Linux / RTOS rootfs (${RVDK_OS_ID:-rtos}); skipping Linux OS THP & sysctl DeepTune"
        rvdk_prog 100 "OS DeepTune (--tune ${TUNE_LABEL}) complete"
        exit 0
    fi

    log_skip "Non-systemd/nommu rootfs (${RVDK_OS_ID:-procd}); skipping systemd timer & Debian/Ubuntu desktop package purges"

    if [[ "$TUNE_MODE" == "data" || "$TUNE_MODE" == "iot" ]]; then
        THP_MODE="never"
    else
        THP_MODE="madvise"
    fi
    if [[ -d /sys/kernel/mm/transparent_hugepage ]]; then
        for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
            [[ -w "$f" ]] && echo "$THP_MODE" > "$f" 2>/dev/null || true
        done
        if [[ -f /etc/rc.common ]]; then
            PROCD_THP="/etc/init.d/rvdk-thp-tune"
            WANT_PROCD_THP="#!/bin/sh /etc/rc.common
START=96
start() {
    for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
        [ -w \"\$f\" ] && echo ${THP_MODE} > \"\$f\" 2>/dev/null || true
    done
}"
            if ! printf '%s\n' "$WANT_PROCD_THP" | cmp -s - "$PROCD_THP" 2>/dev/null; then
                printf '%s\n' "$WANT_PROCD_THP" | rvdk_atomic_write "$PROCD_THP" 0755
                "$PROCD_THP" enable 2>/dev/null || true
            fi
        fi
        log_ok "Set Transparent HugePages -> '${THP_MODE}' (--tune ${TUNE_LABEL})"
    else
        log_skip "Transparent HugePages sysfs absent (nommu/stripped kernel); skipping THP tuning"
    fi

    mkdir -p /etc/sysctl.d
    DEEPTUNE_SYSCTL="/etc/sysctl.d/95-rvdk-deeptune.conf"
    OWRT_SYSCTLS=("# Managed by RVDK (os/deeptune.sh | tune=${TUNE_LABEL})")
    if [[ "$TUNE_MODE" == "iot" ]]; then
        [[ -e /proc/sys/vm/swappiness ]]                  && OWRT_SYSCTLS+=("vm.swappiness = 1")
        [[ -e /proc/sys/vm/dirty_background_ratio ]]      && OWRT_SYSCTLS+=("vm.dirty_background_ratio = 3")
        [[ -e /proc/sys/vm/dirty_ratio ]]                 && OWRT_SYSCTLS+=("vm.dirty_ratio = 8")
        [[ -e /proc/sys/vm/dirty_writeback_centisecs ]]   && OWRT_SYSCTLS+=("vm.dirty_writeback_centisecs = 1500")
        [[ -e /proc/sys/vm/vfs_cache_pressure ]]          && OWRT_SYSCTLS+=("vm.vfs_cache_pressure = 120")
        [[ -e /proc/sys/kernel/sched_autogroup_enabled ]] && OWRT_SYSCTLS+=("kernel.sched_autogroup_enabled = 0")
        [[ -e /proc/sys/net/core/rmem_max ]]              && OWRT_SYSCTLS+=("net.core.rmem_max = 1048576")
        [[ -e /proc/sys/net/core/wmem_max ]]              && OWRT_SYSCTLS+=("net.core.wmem_max = 1048576")
        [[ -e /proc/sys/net/ipv4/tcp_keepalive_time ]]    && OWRT_SYSCTLS+=("net.ipv4.tcp_keepalive_time = 60")
        [[ -e /proc/sys/net/ipv4/tcp_keepalive_intvl ]]   && OWRT_SYSCTLS+=("net.ipv4.tcp_keepalive_intvl = 15")
        [[ -e /proc/sys/net/ipv4/tcp_keepalive_probes ]]  && OWRT_SYSCTLS+=("net.ipv4.tcp_keepalive_probes = 4")
    else
        [[ -e /proc/sys/kernel/sched_autogroup_enabled ]] && OWRT_SYSCTLS+=("kernel.sched_autogroup_enabled = 0")
        [[ -e /proc/sys/vm/swappiness ]]                  && OWRT_SYSCTLS+=("vm.swappiness = 1")
        [[ -e /proc/sys/kernel/printk ]]                  && OWRT_SYSCTLS+=("kernel.printk = 3 4 1 3")
        [[ -e /proc/sys/kernel/nmi_watchdog ]]            && OWRT_SYSCTLS+=("kernel.nmi_watchdog = 0")
    fi
    WANT_OWRT_DT_SYSCTL="$(printf '%s\n' "${OWRT_SYSCTLS[@]}")"
    if ! printf '%s\n' "$WANT_OWRT_DT_SYSCTL" | cmp -s - "$DEEPTUNE_SYSCTL" 2>/dev/null; then
        printf '%s\n' "$WANT_OWRT_DT_SYSCTL" | rvdk_atomic_write "$DEEPTUNE_SYSCTL" 0644
        sysctl -p "$DEEPTUNE_SYSCTL" >/dev/null 2>&1 || true
        log_ok "Applied non-systemd/IoT scheduler & VM sysctls (${DEEPTUNE_SYSCTL})"
    else
        log_skip "Non-systemd/IoT scheduler & VM sysctls already converged"
    fi
    rvdk_prog 100 "OS DeepTune (--tune ${TUNE_LABEL}) complete"
    exit 0
fi

# ==============================================================================
# 0. RETIRE ARMBIAN/ORANGEPI ZRAM SWAP & 50M RAMLOG BEFORE PERSISTENT JOURNALD
# ==============================================================================
rvdk_prog 5 "OS DeepTune: normalizing vendor ramlog/zram overlays..."
VENDOR_ZRAM_CHANGED="false"

for rl_svc in orangepi-ramlog.service armbian-ramlog.service; do
    if systemctl is-active --quiet "$rl_svc" 2>/dev/null; then
        systemctl stop "$rl_svc" 2>/dev/null || true
        VENDOR_ZRAM_CHANGED="true"
    fi
done

_RVDK_SYSLOG_SOCKET_SUSPENDED="false"
_RVDK_RSYSLOG_SUSPENDED="false"
_RVDK_JOURNALD_SUSPENDED="false"
_rvdk_restore_logging_services() {
    if [[ "${_RVDK_JOURNALD_SUSPENDED:-false}" == "true" ]]; then
        _RVDK_JOURNALD_SUSPENDED="false"
        systemctl restart systemd-journald.service 2>/dev/null || systemctl start systemd-journald.service 2>/dev/null || true
    fi
    if [[ "${_RVDK_SYSLOG_SOCKET_SUSPENDED:-false}" == "true" ]]; then
        _RVDK_SYSLOG_SOCKET_SUSPENDED="false"
        systemctl restart syslog.socket 2>/dev/null || systemctl start syslog.socket 2>/dev/null || true
    fi
    if [[ "${_RVDK_RSYSLOG_SUSPENDED:-false}" == "true" ]]; then
        _RVDK_RSYSLOG_SUSPENDED="false"
        systemctl restart rsyslog.service 2>/dev/null || systemctl start rsyslog.service 2>/dev/null || true
    fi
}

if command -v findmnt >/dev/null 2>&1; then
    VARLOG_SRC="$(findmnt -n -o SOURCE /var/log 2>/dev/null || true)"
    VARLOG_HDD_SRC="$(findmnt -n -o SOURCE /var/log.hdd 2>/dev/null || true)"
    if [[ "$VARLOG_SRC" == *zram* || "$VARLOG_SRC" == *ramlog* || -n "$VARLOG_HDD_SRC" ]]; then
        if typeset -f rvdk_register_cleanup >/dev/null 2>&1; then
            rvdk_register_cleanup _rvdk_restore_logging_services
        elif [[ -z "$(trap -p EXIT 2>/dev/null || true)" ]]; then
            trap '_rvdk_restore_logging_services' EXIT
        fi

        if systemctl is-active --quiet syslog.socket 2>/dev/null; then
            _RVDK_SYSLOG_SOCKET_SUSPENDED="true"
            systemctl stop syslog.socket 2>/dev/null || true
        fi
        if systemctl is-active --quiet rsyslog.service 2>/dev/null; then
            _RVDK_RSYSLOG_SUSPENDED="true"
            systemctl stop rsyslog.service 2>/dev/null || true
        fi
        if systemctl is-active --quiet systemd-journald.service 2>/dev/null; then
            journalctl --flush >/dev/null 2>&1 || true
            _RVDK_JOURNALD_SUSPENDED="true"
            systemctl stop systemd-journald.service 2>/dev/null || true
        fi

        if [[ "$VARLOG_SRC" == *zram* || "$VARLOG_SRC" == *ramlog* ]]; then
            umount /var/log 2>/dev/null || umount -l /var/log 2>/dev/null || true
            VENDOR_ZRAM_CHANGED="true"
        fi
        if [[ -n "$VARLOG_HDD_SRC" ]]; then
            umount /var/log.hdd 2>/dev/null || umount -l /var/log.hdd 2>/dev/null || true
            VENDOR_ZRAM_CHANGED="true"
        fi

        _rvdk_restore_logging_services
    fi
fi

if [[ -f /etc/logrotate.conf ]] && grep -qF "/var/log.hdd/" /etc/logrotate.conf 2>/dev/null; then
    _new_lr="$(sed 's|/var/log\.hdd/|/var/log/|g' /etc/logrotate.conf)"
    printf '%s\n' "$_new_lr" | rvdk_atomic_write /etc/logrotate.conf 0644
    for lr_cfg in /etc/logrotate.d/*; do
        if [[ -f "$lr_cfg" ]] && grep -qF "/var/log.hdd/" "$lr_cfg" 2>/dev/null; then
            _new_lr_sub="$(sed 's|/var/log\.hdd/|/var/log/|g' "$lr_cfg")"
            printf '%s\n' "$_new_lr_sub" | rvdk_atomic_write "$lr_cfg" 0644
        fi
    done
    VENDOR_ZRAM_CHANGED="true"
fi

for vz_cfg in \
    /etc/default/orangepi-ramlog \
    /etc/default/armbian-ramlog \
    /etc/default/orangepi-zram-config \
    /etc/default/armbian-zram-config; do
    if [[ -f "$vz_cfg" ]] && grep -Eq '^ENABLED=true' "$vz_cfg" 2>/dev/null; then
        _new_vz="$(sed 's/^ENABLED=true/ENABLED=false/' "$vz_cfg")"
        printf '%s\n' "$_new_vz" | rvdk_atomic_write "$vz_cfg" 0644
        VENDOR_ZRAM_CHANGED="true"
    fi
done

if [[ -r /proc/swaps ]] && command -v swapoff >/dev/null 2>&1; then
    while IFS= read -r zswap_dev; do
        [[ -n "$zswap_dev" ]] || continue
        swapoff "$zswap_dev" 2>/dev/null || true
        VENDOR_ZRAM_CHANGED="true"
    done < <(awk 'NR>1 && $1 ~ /^\/dev\/zram/ {print $1}' /proc/swaps 2>/dev/null || true)
fi

for vz_unit in \
    orangepi-ramlog.service \
    armbian-ramlog.service \
    orangepi-zram-config.service \
    armbian-zram-config.service; do
    if [[ -f "/lib/systemd/system/${vz_unit}" || -f "/usr/lib/systemd/system/${vz_unit}" ]]; then
        vz_state="$(systemctl is-enabled "$vz_unit" 2>/dev/null || true)"
        if [[ "$vz_state" != "masked" && "$vz_state" != "masked-runtime" ]]; then
            systemctl disable --now "$vz_unit" >/dev/null 2>&1 || true
            systemctl mask "$vz_unit" >/dev/null 2>&1 || true
            VENDOR_ZRAM_CHANGED="true"
        fi
    fi
done

if [[ "$VENDOR_ZRAM_CHANGED" == "true" ]]; then
    log_ok "Retired vendor ramlog/zram swap overlays for deterministic Debian/Ubuntu VM & journald parity"
fi

# ==============================================================================
# 0b. CONFIGURE BOUNDED SYSTEMD-JOURNALD (PERSISTENT OR IOT VOLATILE)
# ==============================================================================
JOURNALD_DROPIN="/etc/systemd/journald.conf.d/90-rvdk-deeptune.conf"
if [[ "$TUNE_MODE" == "iot" ]]; then
    rvdk_prog 10 "OS DeepTune: configuring flash-friendly volatile systemd-journald (16M)..."
    mkdir -p /etc/systemd/journald.conf.d
    chmod 0755 /etc/systemd/journald.conf.d
    WANT_JOURNALD="[Journal]
Storage=volatile
RuntimeMaxUse=16M
RateLimitIntervalSec=30s
RateLimitBurst=200
ForwardToSyslog=no
ForwardToWall=no"
    if ! printf "%s\n" "$WANT_JOURNALD" | cmp -s - "$JOURNALD_DROPIN" 2>/dev/null; then
        printf "%s\n" "$WANT_JOURNALD" | rvdk_atomic_write "$JOURNALD_DROPIN" 0644
        systemctl restart systemd-journald.service 2>/dev/null || true
        log_ok "Configured volatile flash-friendly systemd-journald (Storage=volatile, RuntimeMaxUse=16M)"
    else
        log_skip "Volatile systemd-journald policy already converged"
    fi
else
    rvdk_prog 10 "OS DeepTune: persisting bounded systemd-journald (256M)..."
    mkdir -p /etc/systemd/journald.conf.d /var/log/journal
    chmod 0755 /etc/systemd/journald.conf.d
    systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null || true

    # Clear Armbian/OrangePi 20M SystemMaxUse override in /etc/systemd/journald.conf if present
    if [[ -f /etc/systemd/journald.conf ]] && grep -qx 'SystemMaxUse=20M' /etc/systemd/journald.conf 2>/dev/null; then
        _new_jconf="$(sed 's/^SystemMaxUse=20M$/#SystemMaxUse=/' /etc/systemd/journald.conf)"
        printf '%s\n' "$_new_jconf" | rvdk_atomic_write /etc/systemd/journald.conf 0644
    fi

    WANT_JOURNALD="[Journal]
Storage=persistent
SystemMaxUse=256M
RuntimeMaxUse=64M
ForwardToSyslog=no
ForwardToWall=no"

    if ! printf "%s\n" "$WANT_JOURNALD" | cmp -s - "$JOURNALD_DROPIN" 2>/dev/null; then
        printf "%s\n" "$WANT_JOURNALD" | rvdk_atomic_write "$JOURNALD_DROPIN" 0644
        systemctl restart systemd-journald.service 2>/dev/null || true
        journalctl --flush >/dev/null 2>&1 || true
        journalctl --vacuum-size=256M >/dev/null 2>&1 || true
        log_ok "Configured persistent bounded systemd-journald (Storage=persistent, 256M max)"
    else
        log_skip "Persistent systemd-journald cap already configured"
    fi
fi

mask_units_quiet() {
    local units=("$@")
    local to_stop=()
    local to_mask=()
    local u state
    for u in "${units[@]}"; do
        if systemctl is-active --quiet "$u" 2>/dev/null; then
            to_stop+=("$u")
        fi
        state="$(systemctl is-enabled "$u" 2>/dev/null || true)"
        if [[ "$state" != "masked" && "$state" != "masked-runtime" ]]; then
            to_mask+=("$u")
        fi
    done
    if [[ ${#to_stop[@]} -gt 0 ]]; then
        systemctl stop "${to_stop[@]}" 2>/dev/null || true
    fi
    if [[ ${#to_mask[@]} -gt 0 ]]; then
        systemctl disable "${to_mask[@]}" >/dev/null 2>&1 || true
        systemctl mask "${to_mask[@]}" >/dev/null 2>&1 || true
        return 0
    fi
    return 1
}

# ==============================================================================
# 1. SILENCE BACKGROUND POLLING DAEMONS & JITTER TIMERS (KEEPING CLI TOOLS)
# ==============================================================================
rvdk_prog 20 "OS DeepTune: masking background jitter timers & bloat daemons..."

CLI_BG_UNITS=(
    smartmontools.service
    smartd.service
    sysstat.service
    sysstat-collect.timer
    sysstat-collect.service
    sysstat-summary.timer
    sysstat-summary.service
)
if mask_units_quiet "${CLI_BG_UNITS[@]}"; then
    rm -f /var/log/sysstat/sa* /var/log/sysstat/sar* 2>/dev/null || true
    log_ok "Masked background smartd & sysstat timers (preserved smartctl, iostat, mpstat, pidstat CLIs)"
else
    log_skip "Background smartd & sysstat timers already masked (CLI tools intact)"
fi

JITTER_TIMERS=(
    fwupd-refresh.timer
    fwupd-refresh.service
    motd-news.timer
    motd-news.service
    update-notifier-download.timer
    update-notifier-download.service
    update-notifier-motd.timer
    update-notifier-motd.service
    ua-timer.timer
    ua-timer.service
    man-db.timer
    man-db.service
    e2scrub_all.timer
    e2scrub_all.service
    e2scrub_reap.service
    apt-daily.timer
    apt-daily.service
    apt-daily-upgrade.timer
    apt-daily-upgrade.service
)
if mask_units_quiet "${JITTER_TIMERS[@]}"; then
    log_ok "Masked periodic background jitter timers (fwupd, motd-news, update-notifier, man-db, e2scrub)"
else
    log_skip "Periodic background jitter timers already masked"
fi

BLOAT_DAEMONS=(
    fwupd.service
    multipathd.service
    multipathd.socket
    cups.service
    cups.socket
    cups.path
    cups-browsed.service
    avahi-daemon.service
    avahi-daemon.socket
    udisks2.service
    upower.service
    power-profiles-daemon.service
    rtkit-daemon.service
    rsyslog.service
    syslog.socket
    nfs-blkmap.service
)
if [[ "$TUNE_MODE" == "iot" ]]; then
    BLOAT_DAEMONS+=(
        packagekit.service
        ModemManager.service
        apport.service
        apport-autoreport.service
        whoopsie.service
    )
    if [[ "$(readlink /etc/systemd/system/wpa_supplicant.service 2>/dev/null || true)" == "/dev/null" ]]; then
        systemctl unmask wpa_supplicant.service >/dev/null 2>&1 || true
        log_ok "Unmasked wpa_supplicant.service for IoT wireless transport (--tune iot)"
    fi
elif [[ "$PRIMARY_IS_WIFI" == "false" ]]; then
    BLOAT_DAEMONS+=(wpa_supplicant.service)
fi

if mask_units_quiet "${BLOAT_DAEMONS[@]}"; then
    log_ok "Stopped & masked non-essential system daemons (fwupd, multipathd, cups, avahi, udisks2, upower, rsyslog)"
else
    log_skip "Non-essential system daemons already masked"
fi

# Dynamic Primary NIC SSH-safe NetworkManager removal guard
NM_SAFE_TO_PURGE="false"
if [[ -n "$PRIMARY_NIC" && "$PRIMARY_IS_WIFI" == "false" ]] && systemctl is-active --quiet systemd-networkd.service 2>/dev/null; then
    if command -v networkctl >/dev/null 2>&1 && networkctl list 2>/dev/null | awk -v nic="$PRIMARY_NIC" '$2 == nic && $4 == "configured" {found=1} END {exit !found}'; then
        NM_SAFE_TO_PURGE="true"
    fi
fi

if [[ "$NM_SAFE_TO_PURGE" == "true" ]]; then
    if mask_units_quiet NetworkManager.service NetworkManager-wait-online.service NetworkManager-dispatcher.service; then
        log_ok "Disabled redundant NetworkManager (${PRIMARY_NIC} confirmed configured under systemd-networkd)"
    fi
elif systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
    log_warn "Keeping NetworkManager active (${PRIMARY_NIC:-primary NIC} is managed by NetworkManager, not systemd-networkd)"
fi

# ==============================================================================
# 2. LOCK DOWN PER-SSH `systemd --user` AUDIO & KEYRING SPAWNERS
# ==============================================================================
rvdk_prog 40 "OS DeepTune: masking user-session PipeWire & GNOME Keyring units..."
mkdir -p /etc/systemd/user && chmod 0755 /etc/systemd/user
USER_MASK_UNITS=(
    pipewire.service
    pipewire.socket
    pipewire-pulse.service
    pipewire-pulse.socket
    filter-chain.service
    wireplumber.service
    gnome-keyring-daemon.service
    gnome-keyring-daemon.socket
    gcr-ssh-agent.service
    gcr-ssh-agent.socket
    gpg-agent-browser.socket
)
USER_MASK_CHANGED="false"
for uu in "${USER_MASK_UNITS[@]}"; do
    if [[ "$(readlink "/etc/systemd/user/${uu}" 2>/dev/null || true)" != "/dev/null" ]]; then
        ln -sf /dev/null "/etc/systemd/user/${uu}"
        USER_MASK_CHANGED="true"
    fi
done

if pgrep -x "wireplumber|pipewire|pipewire-pulse" >/dev/null 2>&1 || pgrep -f "/usr/bin/pipewire" >/dev/null 2>&1; then
    pkill -TERM -x wireplumber 2>/dev/null || true
    pkill -TERM -x pipewire-pulse 2>/dev/null || true
    pkill -TERM -x pipewire 2>/dev/null || true
    USER_MASK_CHANGED="true"
fi

if [[ "$USER_MASK_CHANGED" == "true" ]]; then
    log_ok "Masked PipeWire/WirePlumber/GNOME-Keyring in /etc/systemd/user and reaped live audio daemons"
else
    log_skip "User-session audio & keyring units already masked"
fi

# ==============================================================================
# 3. PURGE WORKSTATION, PRINTER, AUDIO & SAN BLOAT PACKAGES (+ AUTOREMOVE)
# ==============================================================================
rvdk_prog 60 "OS DeepTune: purging workstation, printer & SAN bloat packages..."
# Note: `network-manager-*-gnome` are GTK/WebKit desktop applets (`nm-applet`,
# `nm-connection-editor`), NOT the headless `NetworkManager` daemon or `nmcli`,
# so they are safe to purge even when `NetworkManager.service` owns the NIC.
CANDIDATE_PURGE_PKGS=(
    firefox
    firefox-esr
    cups
    cups-browsed
    cups-daemon
    cups-core-drivers
    hplip
    printer-driver-hpcups
    ipp-usb
    fwupd
    multipath-tools
    udisks2
    upower
    power-profiles-daemon
    avahi-daemon
    rtkit
    ubuntu-advantage-tools
    update-notifier-common
    motd-news-config
    rsyslog
    ibus
    ibus-data
    fonts-noto-core
    gvfs
    gvfs-daemons
    gvfs-backends
    gnome-remote-desktop
    gnome-online-accounts
    gnome-control-center
    yelp
    zenity
    network-manager-gnome
    network-manager-openvpn-gnome
    network-manager-pptp-gnome
    network-manager-openconnect-gnome
    pipewire
    pipewire-pulse
    pipewire-alsa
    pipewire-audio
    wireplumber
)
if [[ "$TUNE_MODE" == "iot" ]]; then
    CANDIDATE_PURGE_PKGS+=(
        packagekit
        modemmanager
        apport
        whoopsie
    )
elif [[ "$PRIMARY_IS_WIFI" == "false" ]]; then
    CANDIDATE_PURGE_PKGS+=(wpasupplicant)
fi

if [[ "$NM_SAFE_TO_PURGE" == "true" ]]; then
    CANDIDATE_PURGE_PKGS+=(
        network-manager
        network-manager-openvpn
        network-manager-pptp
    )
fi

INSTALLED_BLOAT=()
for pkg in "${CANDIDATE_PURGE_PKGS[@]}"; do
    if dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -qx "install ok installed"; then
        INSTALLED_BLOAT+=("$pkg")
    fi
done

if [[ ${#INSTALLED_BLOAT[@]} -gt 0 ]]; then
    log_info "Purging ${#INSTALLED_BLOAT[@]} workstation/printer/SAN bloat packages + orphaned dependencies..."
    apt-get purge "${APT_FLAGS[@]}" "${INSTALLED_BLOAT[@]}"
    apt-get autoremove "${APT_FLAGS[@]}" --purge
    apt-get clean
    rm -rf /var/log/cups /var/log/syslog* /var/log/kern.log* /var/log/auth.log* /var/cache/fwupd 2>/dev/null || true
    log_ok "Purged bloat packages & orphaned dependencies: ${INSTALLED_BLOAT[*]}"
elif apt-get -s autoremove 2>/dev/null | grep -q '^Remv '; then
    log_info "Purging orphaned auto-installed packages left by prior bloat removal..."
    apt-get autoremove "${APT_FLAGS[@]}" --purge
    apt-get clean
    log_ok "Purged orphaned auto-installed dependency packages"
else
    log_skip "Workstation, printer, audio & SAN bloat packages (and orphans) already purged"
fi

# ==============================================================================
# 3b. DEFER UNATTENDED `needrestart` BOUNCES FOR STATEFUL BROKER DAEMONS
# ==============================================================================
if [[ -d /etc/needrestart ]] || dpkg-query -W -f='${Status}\n' needrestart 2>/dev/null | grep -qx "install ok installed"; then
    NEEDRESTART_DROPIN="/etc/needrestart/conf.d/90-rvdk-stateful.conf"
    WANT_NEEDRESTART="# Managed by RVDK — defer automatic restarts of stateful data/storage/broker services
# during APT library upgrades so active PostgreSQL io_uring clusters, NFSv4 grace
# leases, and MQTT/ntfy sessions are only restarted during controlled windows.
\$nrconf{override_rc}{qr(^(?:postgresql|nfs-ganesha|nfs-server|nfs-kernel-server|rpcbind|mosquitto|ntfy)(?:@|\\.|\$))} = 0;"
    if ! printf '%s\n' "$WANT_NEEDRESTART" | cmp -s - "$NEEDRESTART_DROPIN" 2>/dev/null; then
        printf '%s\n' "$WANT_NEEDRESTART" | rvdk_atomic_write "$NEEDRESTART_DROPIN" 0644
        log_ok "Deferred automatic needrestart bounces for stateful services (${NEEDRESTART_DROPIN})"
    else
        log_skip "Stateful service needrestart guard (${NEEDRESTART_DROPIN}) already converged"
    fi
fi

# ==============================================================================
# 4. BLACKLIST & UNLOAD UNIVERSAL NON-SERVER KERNEL MODULES
# ==============================================================================
rvdk_prog 78 "OS DeepTune: blacklisting universal non-server kernel modules..."
OS_BLACKLIST_MODS=(
    joydev
    input_leds
    apple_mfi_fastcharge
    dm_multipath
    nvme_fabrics
)
[[ "$PRIMARY_IS_WIFI" == "false" && "$TUNE_MODE" != "iot" ]] && OS_BLACKLIST_MODS=(cfg80211 "${OS_BLACKLIST_MODS[@]}")

MODPROBE_OS="/etc/modprobe.d/85-rvdk-os-deeptune.conf"
WANT_OS_MODPROBE="# Managed by RVDK (os/deeptune.sh)
# Suppresses non-server modules on headless nodes."
for m in "${OS_BLACKLIST_MODS[@]}"; do
    WANT_OS_MODPROBE+=$'\n'"blacklist ${m}"
done

if ! printf "%s\n" "$WANT_OS_MODPROBE" | cmp -s - "$MODPROBE_OS" 2>/dev/null; then
    printf "%s\n" "$WANT_OS_MODPROBE" | rvdk_atomic_write "$MODPROBE_OS" 0644
    log_ok "Wrote OS kernel module blacklist to ${MODPROBE_OS}"
else
    log_skip "OS kernel module blacklist (${MODPROBE_OS}) already converged"
fi

UNLOADED_OS_MODS=()
for m in "${OS_BLACKLIST_MODS[@]}"; do
    if awk -v mod="$m" '$1 == mod { found=1 } END { exit !found }' /proc/modules 2>/dev/null; then
        if modprobe -r "$m" 2>/dev/null || rmmod "$m" 2>/dev/null; then
            UNLOADED_OS_MODS+=("$m")
        fi
    fi
done
[[ ${#UNLOADED_OS_MODS[@]} -gt 0 ]] && log_ok "Unloaded live OS kernel modules: ${UNLOADED_OS_MODS[*]}"

# ==============================================================================
# 5. REVERSIBLE TRANSPARENT HUGEPAGES & HEADLESS SYSCTLS
# ==============================================================================
rvdk_prog 92 "OS DeepTune: applying THP (${TUNE_LABEL}) & scheduler sysctls..."

if [[ "$TUNE_MODE" == "data" || "$TUNE_MODE" == "iot" ]]; then
    THP_MODE="never"
else
    THP_MODE="madvise"
fi

THP_UNIT="/etc/systemd/system/rvdk-thp-tune.service"
WANT_THP_UNIT="[Unit]
Description=RVDK Transparent HugePages Policy (${THP_MODE} for --tune ${TUNE_LABEL})
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do [ -w \"\$f\" ] && echo ${THP_MODE} > \"\$f\" || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"

if [[ -d /sys/kernel/mm/transparent_hugepage ]]; then
    if ! printf "%s\n" "$WANT_THP_UNIT" | cmp -s - "$THP_UNIT" 2>/dev/null; then
        printf "%s\n" "$WANT_THP_UNIT" | rvdk_atomic_write "$THP_UNIT" 0644
        systemctl daemon-reload
        systemctl enable rvdk-thp-tune.service >/dev/null
        systemctl restart rvdk-thp-tune.service
        log_ok "Set Transparent HugePages enabled/defrag -> '${THP_MODE}' (--tune ${TUNE_LABEL})"
    else
        for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
            [[ -w "$f" ]] && echo "$THP_MODE" > "$f" 2>/dev/null || true
        done
        log_skip "Transparent HugePages policy already converged at '${THP_MODE}'"
    fi
else
    log_skip "Transparent HugePages sysfs absent; skipping THP unit"
fi

DEEPTUNE_SYSCTL="/etc/sysctl.d/95-rvdk-deeptune.conf"
if [[ "$TUNE_MODE" == "iot" ]]; then
    WANT_SYSCTL="# Managed by RVDK (os/deeptune.sh | tune=iot)
vm.swappiness = 1
vm.dirty_background_ratio = 3
vm.dirty_ratio = 8
vm.dirty_writeback_centisecs = 1500
vm.vfs_cache_pressure = 120
kernel.sched_autogroup_enabled = 0
net.core.rmem_max = 1048576
net.core.wmem_max = 1048576
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 4"
else
    WANT_SYSCTL="# Managed by RVDK (os/deeptune.sh | tune=${TUNE_LABEL})
# Disable desktop session TTY autogrouping so database & compute workers get pure scheduler fairness
kernel.sched_autogroup_enabled = 0
# Minimize swap inclination & console printk stalls
vm.swappiness = 1
kernel.printk = 3 4 1 3
-kernel.nmi_watchdog = 0"
fi

if ! printf "%s\n" "$WANT_SYSCTL" | cmp -s - "$DEEPTUNE_SYSCTL" 2>/dev/null; then
    printf "%s\n" "$WANT_SYSCTL" | rvdk_atomic_write "$DEEPTUNE_SYSCTL" 0644
    sysctl -e -p "$DEEPTUNE_SYSCTL" >/dev/null 2>&1 || sysctl -p "$DEEPTUNE_SYSCTL" >/dev/null 2>&1 || true
    log_ok "Applied headless scheduler & VM sysctls (${DEEPTUNE_SYSCTL})"
else
    log_skip "Headless scheduler & VM sysctls already converged"
fi

rvdk_prog 100 "OS DeepTune (--tune ${TUNE_LABEL}) complete"
