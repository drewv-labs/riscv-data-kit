#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Layer 1: Universal Headless OS DeepTune (`os/deeptune.sh`)
# Path: riscv-data-kit/os/deeptune.sh
#
# Description:
#   Silicon- and board-agnostic headless Linux OS deep-tuning across Debian,
#   Ubuntu, and Bianbu RISC-V nodes:
#     • Silences periodic background polling (`smartd` & `sysstat` timers) while
#       preserving on-demand diagnostic CLIs (`smartctl`, `iostat`, `mpstat`, `pidstat`)
#     • Masks OS/desktop/filesystem background jitter timers (`fwupd-refresh`,
#       `motd-news`, `update-notifier`, `man-db`, `e2scrub_all`, `apt-daily*`)
#     • Stops, masks & purges workstation, printer, audio, Wi-Fi & SAN bloat
#       (`firefox`, `cups*`, `fwupd`, `multipathd`, `avahi`, `udisks2`, `upower`,
#       `wpa_supplicant`, `rsyslog`, `pipewire*`, `wireplumber`, plus `NetworkManager`
#       when `systemd-networkd` already owns the dynamically detected primary NIC)
#     • Locks down per-SSH `systemd --user` PipeWire & GNOME Keyring sockets
#     • Unloads & blacklists universal non-server kernel modules (`cfg80211`,
#       `joydev`, `input_leds`, `apple_mfi_fastcharge`, `dm_multipath`, `nvme_fabrics`)
#     • Applies reversible Transparent HugePages policy (`--tune data` -> `never`,
#       `--tune ml|ai` -> `madvise`), bounded `journald` cap (`256M`), and
#       headless scheduler/VM sysctls (`kernel.sched_autogroup_enabled = 0`)
# ==============================================================================
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

log_info() { printf "\033[1;36m[RVDK:OS-DEEPTUNE]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

TUNE_REQUEST="${RVDK_TUNE:-data}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tune) TUNE_REQUEST="${2:-data}"; shift 2 ;;
        --tune=*)  TUNE_REQUEST="${1#*=}"; shift ;;
        data|ml|ai) TUNE_REQUEST="$1"; shift ;;
        --no-apt-update|--skip-apt-update) export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)          export RVDK_NO_PROGBAR="1"; shift ;;
        *) shift ;;
    esac
done

TUNE_REQUEST="$(tr '[:upper:]' '[:lower:]' <<< "$TUNE_REQUEST")"
case "$TUNE_REQUEST" in
    ml)              TUNE_MODE="ml"; TUNE_LABEL="ml" ;;
    ai|edge-ai|edge-ml) TUNE_MODE="ml"; TUNE_LABEL="ai" ;;
    *)               TUNE_MODE="data"; TUNE_LABEL="data" ;;
esac

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && REPO_ROOT="$(cd "${_SCRIPT_DIR}/.." && pwd)"

if [[ -n "$REPO_ROOT" && -f "${REPO_ROOT}/lib/kit.sh" ]]; then
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/kit.sh"
    rvdk_kit_resolve
fi

_PROGBAR_CANDIDATE="${RVDK_PROGBAR_LIB:-}"
[[ -z "$_PROGBAR_CANDIDATE" && -n "$REPO_ROOT" && -f "${REPO_ROOT}/lib/progbar.sh" ]] && _PROGBAR_CANDIDATE="${REPO_ROOT}/lib/progbar.sh"
if [[ -n "$_PROGBAR_CANDIDATE" && -f "$_PROGBAR_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    source "$_PROGBAR_CANDIDATE"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_prog_init "OS DeepTune (--tune ${TUNE_LABEL}): inspecting services & timers..."
log_info "Converging headless OS DeepTune (--tune ${TUNE_LABEL} | NIC=${RVDK_PRIMARY_NIC:-auto})..."

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
rvdk_prog 15 "OS DeepTune: masking background jitter timers & bloat daemons..."

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
    wpa_supplicant.service
    rsyslog.service
    syslog.socket
    nfs-blkmap.service
)
if mask_units_quiet "${BLOAT_DAEMONS[@]}"; then
    log_ok "Stopped & masked non-essential system daemons (fwupd, multipathd, cups, avahi, udisks2, upower, wpa_supplicant, rsyslog)"
else
    log_skip "Non-essential system daemons already masked"
fi

# Dynamic Primary NIC SSH-safe NetworkManager removal guard
PRIMARY_NIC="${RVDK_PRIMARY_NIC:-}"
NM_SAFE_TO_PURGE="false"
if [[ -n "$PRIMARY_NIC" ]] && systemctl is-active --quiet systemd-networkd.service 2>/dev/null; then
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
rvdk_prog 35 "OS DeepTune: masking user-session PipeWire & GNOME Keyring units..."
install -d -m 0755 /etc/systemd/user
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
# 3. PURGE WORKSTATION, PRINTER, AUDIO & SAN BLOAT PACKAGES
# ==============================================================================
rvdk_prog 55 "OS DeepTune: purging workstation, printer & SAN bloat packages..."
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
    wpasupplicant
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
    pipewire
    pipewire-pulse
    pipewire-alsa
    pipewire-audio
    wireplumber
)

if [[ "$NM_SAFE_TO_PURGE" == "true" ]]; then
    CANDIDATE_PURGE_PKGS+=(
        network-manager
        network-manager-gnome
        network-manager-openvpn
        network-manager-openvpn-gnome
        network-manager-pptp
        network-manager-pptp-gnome
    )
fi

INSTALLED_BLOAT=()
for pkg in "${CANDIDATE_PURGE_PKGS[@]}"; do
    if dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -qx "install ok installed"; then
        INSTALLED_BLOAT+=("$pkg")
    fi
done

if [[ ${#INSTALLED_BLOAT[@]} -gt 0 ]]; then
    log_info "Purging ${#INSTALLED_BLOAT[@]} workstation/printer/SAN bloat packages..."
    apt-get purge "${APT_FLAGS[@]}" "${INSTALLED_BLOAT[@]}"
    apt-get clean
    rm -rf /var/log/cups /var/log/syslog* /var/log/kern.log* /var/log/auth.log* /var/cache/fwupd 2>/dev/null || true
    log_ok "Purged bloat packages: ${INSTALLED_BLOAT[*]}"
else
    log_skip "Workstation, printer, audio & SAN bloat packages already purged"
fi

# ==============================================================================
# 4. BLACKLIST & UNLOAD UNIVERSAL NON-SERVER KERNEL MODULES
# ==============================================================================
rvdk_prog 75 "OS DeepTune: blacklisting universal non-server kernel modules..."
OS_BLACKLIST_MODS=(
    cfg80211
    joydev
    input_leds
    apple_mfi_fastcharge
    dm_multipath
    nvme_fabrics
)
MODPROBE_OS="/etc/modprobe.d/85-rvdk-os-deeptune.conf"
WANT_OS_MODPROBE="# Managed by RVDK (os/deeptune.sh)
# Suppresses Wi-Fi, gamepad, USB phone fast-charge, and SAN multipath modules on headless nodes."
for m in "${OS_BLACKLIST_MODS[@]}"; do
    WANT_OS_MODPROBE+=$'\n'"blacklist ${m}"
done

if ! printf "%s\n" "$WANT_OS_MODPROBE" | cmp -s - "$MODPROBE_OS" 2>/dev/null; then
    printf "%s\n" "$WANT_OS_MODPROBE" > "$MODPROBE_OS"
    chmod 0644 "$MODPROBE_OS"
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
# 5. REVERSIBLE TRANSPARENT HUGEPAGES, JOURNALD CAP & HEADLESS SYSCTLS
# ==============================================================================
rvdk_prog 90 "OS DeepTune: applying THP (${TUNE_LABEL}), journald cap & scheduler sysctls..."

if [[ "$TUNE_MODE" == "data" ]]; then
    THP_MODE="never"
else
    THP_MODE="madvise"
fi

# Migrate legacy unit name if present
if [[ -f /etc/systemd/system/eic7700x-thp-tune.service ]]; then
    systemctl disable eic7700x-thp-tune.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/eic7700x-thp-tune.service
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
        printf "%s\n" "$WANT_THP_UNIT" > "$THP_UNIT"
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
fi

install -d -m 0755 /etc/systemd/journald.conf.d
JOURNALD_DROPIN="/etc/systemd/journald.conf.d/90-rvdk-deeptune.conf"
WANT_JOURNALD="[Journal]
SystemMaxUse=256M
RuntimeMaxUse=64M
ForwardToSyslog=no
ForwardToWall=no"

if ! printf "%s\n" "$WANT_JOURNALD" | cmp -s - "$JOURNALD_DROPIN" 2>/dev/null; then
    printf "%s\n" "$WANT_JOURNALD" > "$JOURNALD_DROPIN"
    systemctl restart systemd-journald.service 2>/dev/null || true
    journalctl --vacuum-size=256M >/dev/null 2>&1 || true
    log_ok "Configured bounded systemd-journald cap (256M max, ForwardToSyslog=no)"
else
    log_skip "systemd-journald cap already configured"
fi

DEEPTUNE_SYSCTL="/etc/sysctl.d/95-rvdk-deeptune.conf"
WANT_SYSCTL="# Managed by RVDK (os/deeptune.sh | tune=${TUNE_LABEL})
# Disable desktop session TTY autogrouping so database & compute workers get pure scheduler fairness
kernel.sched_autogroup_enabled = 0
# Minimize swap inclination & console printk stalls
vm.swappiness = 1
kernel.printk = 3 4 1 3
-kernel.nmi_watchdog = 0"

if ! printf "%s\n" "$WANT_SYSCTL" | cmp -s - "$DEEPTUNE_SYSCTL" 2>/dev/null; then
    printf "%s\n" "$WANT_SYSCTL" > "$DEEPTUNE_SYSCTL"
    sysctl --system >/dev/null
    log_ok "Applied headless scheduler & VM sysctls (${DEEPTUNE_SYSCTL})"
else
    log_skip "Headless scheduler & VM sysctls already converged"
fi

rvdk_prog 100 "OS DeepTune (--tune ${TUNE_LABEL}) complete"
