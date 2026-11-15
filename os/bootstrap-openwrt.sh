#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Day-0 OpenWrt RISC-V Router Node Bootstrap Script
# Path: riscv-data-kit/os/bootstrap-openwrt.sh
# Description: Idempotent Layer 1D UCI hostname, optional operator SSH/sudo
#              account, and fw4/nftables + MPTCP hardening for OpenWrt RISC-V
#              gateway/router nodes (e.g., Orange Pi R2S).
#
# Usage:
#   ./bootstrap-openwrt.sh [--hostname r2s-gw] [--user drew] [--nopasswd] [--noprogbar]
# ==============================================================================

set -Eeuo pipefail

TARGET_USER=""
TARGET_HOSTNAME=""
NOPASSWD_SUDO="false"
ORIG_ARGS=("$@")

log_info() { printf "\033[1;36m[INFO]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
log_err()  { printf "\033[1;31m[ERR!]\033[0m %s\n" "$1" >&2; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -H, --hostname <hostname>   System hostname to persist via OpenWrt UCI
  -u, --user <username>       Optional non-root operator account (requires shadow-useradd)
  -n, --nopasswd              Enable passwordless sudo if sudo is installed
      --no-apt-update         Ignored on OpenWrt (compatibility flag)
      --noprogbar             Suppress persistent bottom progress bar
  -h, --help                  Show this help message and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)
            TARGET_USER="${2:-}"; shift 2 ;;
        -H|--hostname)
            TARGET_HOSTNAME="${2:-}"; shift 2 ;;
        -n|--nopasswd|--passwordless-sudo)
            NOPASSWD_SUDO="true"; shift ;;
        --debloat-only|--keep-gui|--skip-locale|--no-apt-update|--skip-apt-update)
            shift ;;
        --noprogbar|--no-progbar)
            export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            log_err "Unknown argument: $1"
            usage; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    else
        log_err "This script must be run as root."
        exit 1
    fi
fi

export LANG="C" LC_ALL="C"

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

_PROGBAR_CANDIDATE="${RVDK_PROGBAR_LIB:-}"
[[ -z "$_PROGBAR_CANDIDATE" && -n "$_SCRIPT_DIR" && -f "${_SCRIPT_DIR}/../lib/progbar.sh" ]] && _PROGBAR_CANDIDATE="${_SCRIPT_DIR}/../lib/progbar.sh"
if [[ -n "$_PROGBAR_CANDIDATE" && -f "$_PROGBAR_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    source "$_PROGBAR_CANDIDATE"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_prog_init "OpenWrt Day-0 router normalization..."

# 1. Optional Operator User & Sudoers (when shadow-useradd / sudo are installed)
rvdk_prog 20 "Checking OpenWrt user & sudoers (${TARGET_USER:-root})..."
if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
    if id -u "$TARGET_USER" >/dev/null 2>&1; then
        log_skip "User '${TARGET_USER}' already exists"
    elif command -v useradd >/dev/null 2>&1; then
        mkdir -p /home
        useradd -m -s /bin/ash "$TARGET_USER"
        log_ok "Created user '${TARGET_USER}'"
    else
        log_warn "Skipping user creation for '${TARGET_USER}' (OpenWrt uses root by default; install 'shadow-useradd' if non-root accounts are needed)"
    fi

    if [[ "$NOPASSWD_SUDO" == "true" ]] && [[ -d /etc/sudoers.d ]] && id -u "$TARGET_USER" >/dev/null 2>&1; then
        SUDOERS_FILE="/etc/sudoers.d/010_${TARGET_USER}-nopasswd"
        SUDOERS_RULE="${TARGET_USER} ALL=(ALL) NOPASSWD: ALL"
        if [[ ! -f "$SUDOERS_FILE" ]] || ! grep -qxF "$SUDOERS_RULE" "$SUDOERS_FILE"; then
            echo "$SUDOERS_RULE" > "$SUDOERS_FILE"
            chmod 0440 "$SUDOERS_FILE"
            log_ok "Configured passwordless sudo in ${SUDOERS_FILE}"
        else
            log_skip "Passwordless sudo already active at ${SUDOERS_FILE}"
        fi
    fi
fi

# 2. UCI Hostname Configuration
rvdk_prog 50 "Configuring OpenWrt UCI hostname (${TARGET_HOSTNAME:-current})..."
if [[ -n "$TARGET_HOSTNAME" ]]; then
    if command -v uci >/dev/null 2>&1; then
        CUR_UCI_HOST="$(uci -q get system.@system[0].hostname || true)"
        if [[ "$CUR_UCI_HOST" == "$TARGET_HOSTNAME" ]]; then
            log_skip "OpenWrt UCI hostname is already '${TARGET_HOSTNAME}'"
        else
            uci set "system.@system[0].hostname=${TARGET_HOSTNAME}"
            uci commit system
            echo "$TARGET_HOSTNAME" > /proc/sys/kernel/hostname 2>/dev/null || true
            [[ -x /etc/init.d/system ]] && /etc/init.d/system reload 2>/dev/null || true
            log_ok "Updated OpenWrt UCI hostname: '${CUR_UCI_HOST:-OpenWrt}' -> '${TARGET_HOSTNAME}'"
        fi
    else
        echo "$TARGET_HOSTNAME" > /proc/sys/kernel/hostname 2>/dev/null || true
        log_ok "Updated kernel hostname to '${TARGET_HOSTNAME}'"
    fi
fi

# 3. CVE-2026-98432 Kernel IPv4 TCP Option Filter & MPTCP Lockdown (fw4 / procd / BusyBox sysctl compatible)
rvdk_prog 80 "Converging CVE-2026-98432 nftables & MPTCP guard..."
mkdir -p /etc/sysctl.d
SYSCTL_CVE_FILE="/etc/sysctl.d/99-cve-2026-98432-tcp.conf"
SYSCTL_LINES=("# Managed by RVDK (os/bootstrap-openwrt.sh)")
[[ -e /proc/sys/net/mptcp/enabled ]]        && SYSCTL_LINES+=("net.mptcp.enabled = 0")
[[ -e /proc/sys/net/ipv4/tcp_migrate_req ]] && SYSCTL_LINES+=("net.ipv4.tcp_migrate_req = 0")
printf "%s\n" "${SYSCTL_LINES[@]}" > "$SYSCTL_CVE_FILE"
sysctl -p "$SYSCTL_CVE_FILE" >/dev/null 2>&1 || true

if command -v nft >/dev/null 2>&1; then
    NFT_STANDALONE="/etc/cve-2026-98432.nft"
    INIT_CVE="/etc/init.d/cve-2026-98432-guard"
    if nft list table ip cve_2026_98432 >/dev/null 2>&1 && [[ -x "$INIT_CVE" ]]; then
        log_skip "CVE-2026-98432 TCP option filter & MPTCP lockdown already active"
    else
        cat << 'NFT_EOF' > "$NFT_STANDALONE"
add table ip cve_2026_98432
flush table ip cve_2026_98432
add chain ip cve_2026_98432 pre { type filter hook prerouting priority -300; policy accept; }
add rule ip cve_2026_98432 pre meta l4proto tcp ip hdrlength gt 5 counter drop
NFT_EOF
        nft -f "$NFT_STANDALONE"

        cat << 'INIT_EOF' > "$INIT_CVE"
#!/bin/sh /etc/rc.common
START=18
start() {
    /usr/sbin/nft -f /etc/cve-2026-98432.nft 2>/dev/null || true
}
INIT_EOF
        chmod +x "$INIT_CVE"
        "$INIT_CVE" enable 2>/dev/null || true
        log_ok "Configured OpenWrt procd CVE-2026-98432 raw prerouting drop guard"
    fi
else
    log_warn "nft CLI not present; applied sysctl MPTCP lockdown only"
fi

rvdk_prog 100 "OpenWrt Day-0 router normalization complete"
log_info "Day-0 OpenWrt bootstrap complete."
