#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Day-0 OpenWrt RISC-V Router Node Bootstrap Script
# Path: riscv-data-kit/os/bootstrap-openwrt.sh
# Description: Idempotent Layer 1D cold-RTC sync, US-first opkg/apk feed & UCI
#              NTP normalization, UCI hostname, optional operator SSH/sudo
#              account, and fw4-integrated nftables + MPTCP hardening for
#              OpenWrt RISC-V gateway/router nodes (e.g., Orange Pi R2S).
#
# Usage:
#   ./bootstrap-openwrt.sh [--hostname r2s-gw] [--user rvadmin] [--nopasswd] [--noprogbar]
# ==============================================================================

set -Eeuo pipefail

TARGET_USER=""
TARGET_HOSTNAME=""
NOPASSWD_SUDO="false"
ORIG_ARGS=("$@")

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/.." && pwd)"

# @RVDK_INLINE_LIBS: common progbar
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${_REPO_ROOT}/lib/common.sh"
else
    log_info()  { printf "\033[1;36m[RVDK:OPENWRT]\033[0m %s\n" "$1"; }
    log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
    log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
    log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
    log_err()   { printf "\033[1;31m[ERR!]\033[0m %s\n" "$1" >&2; }
    log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
    rvdk_log_init() { :; }
    rvdk_validate_username() { [[ "${1:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
    rvdk_validate_hostname() { [[ ${#1} -ge 1 && ${#1} -le 253 && "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; }
    rvdk_sync_cold_clock() { :; }
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]]; then
    # shellcheck source=lib/progbar.sh
    source "${_REPO_ROOT}/lib/progbar.sh"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_log_init "RVDK:OPENWRT"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -H, --hostname <hostname>   RFC-1123 system hostname to persist via OpenWrt UCI
  -u, --user <username>       Optional non-root operator account (requires shadow-useradd)
  -n, --nopasswd              Enable passwordless sudo if sudo is installed
      --keep-mirrors          Preserve existing OpenWrt package & NTP mirror configs
      --no-apt-update         Ignored on OpenWrt (compatibility flag)
      --noprogbar             Suppress persistent bottom progress bar
  -h, --help                  Show this help message and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)
            [[ -z "${2:-}" || "${2:-}" == --* ]] && log_fatal "Option '$1' requires a username argument."
            TARGET_USER="$2"; shift 2 ;;
        -H|--hostname)
            [[ -z "${2:-}" || "${2:-}" == --* ]] && log_fatal "Option '$1' requires a hostname argument."
            TARGET_HOSTNAME="$2"; shift 2 ;;
        -n|--nopasswd|--passwordless-sudo)
            NOPASSWD_SUDO="true"; shift ;;
        --keep-mirrors)
            export RVDK_KEEP_VENDOR_MIRRORS="1"; shift ;;
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

if [[ -n "$TARGET_USER" ]] && ! rvdk_validate_username "$TARGET_USER"; then
    log_fatal "Invalid POSIX username format: '${TARGET_USER}'."
fi
if [[ -n "$TARGET_HOSTNAME" ]] && ! rvdk_validate_hostname "$TARGET_HOSTNAME"; then
    log_fatal "Invalid RFC-1123 hostname: '${TARGET_HOSTNAME}'."
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    else
        log_fatal "This script must be run as root."
    fi
fi

export LANG="C" LC_ALL="C"

rvdk_prog_init "OpenWrt Day-0 router normalization..."
rvdk_sync_cold_clock

# 0. Normalize OpenWrt package feeds & UCI NTP servers onto US-first endpoints
if [[ "${RVDK_KEEP_VENDOR_MIRRORS:-0}" != "1" && "${RVDK_KEEP_VENDOR_MIRRORS:-false}" != "true" ]]; then
    OWRT_CN_HOSTS="repo\\.huaweicloud\\.com|mirrors\\.tuna\\.tsinghua\\.edu\\.cn|mirrors\\.bfsu\\.edu\\.cn|mirrors\\.ustc\\.edu\\.cn|mirrors\\.aliyun\\.com|mirrors\\.163\\.com|mirrors\\.cloud\\.tencent\\.com|mirrors\\.sjtug\\.sjtu\\.edu\\.cn|mirror\\.iscas\\.ac\\.cn|mirror\\.sjtu\\.edu\\.cn"
    OWRT_SCHEME="http"
    [[ -s /etc/ssl/certs/ca-certificates.crt || -s /etc/ssl/certs/ca-bundle.crt ]] && OWRT_SCHEME="https"
    OWRT_FEED_CHANGED="false"
    for _of in /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf /etc/apk/repositories; do
        [[ -f "$_of" ]] || continue
        _tmp_of="$(mktemp)"
        sed -E "/^[[:space:]]*#/! s@https?://(${OWRT_CN_HOSTS})/openwrt([[:space:]/]|$)@${OWRT_SCHEME}://downloads.openwrt.org\\2@g" "$_of" > "$_tmp_of"
        if ! cmp -s "$_tmp_of" "$_of" 2>/dev/null; then
            mkdir -p /var/lib/rvdk/backups/openwrt
            cp -a "$_of" "/var/lib/rvdk/backups/openwrt/$(basename "$_of").orig" 2>/dev/null || true
            chmod 0644 "$_tmp_of"
            mv -f "$_tmp_of" "$_of"
            OWRT_FEED_CHANGED="true"
        else
            rm -f "$_tmp_of"
        fi
    done
    [[ "$OWRT_FEED_CHANGED" == "true" ]] && log_ok "Normalized OpenWrt package feeds onto ${OWRT_SCHEME}://downloads.openwrt.org"

    if command -v uci >/dev/null 2>&1; then
        CUR_OWRT_NTP="$(uci -q get system.ntp.server || true)"
        WANT_OWRT_NTP="0.us.pool.ntp.org 1.us.pool.ntp.org 2.us.pool.ntp.org 3.us.pool.ntp.org time.cloudflare.com"
        if [[ "$CUR_OWRT_NTP" != "$WANT_OWRT_NTP" ]]; then
            uci -q delete system.ntp.server || true
            for _ns in 0.us.pool.ntp.org 1.us.pool.ntp.org 2.us.pool.ntp.org 3.us.pool.ntp.org time.cloudflare.com; do
                uci add_list "system.ntp.server=${_ns}"
            done
            uci set system.ntp.enabled='1'
            uci commit system
            [[ -x /etc/init.d/sysntpd ]] && /etc/init.d/sysntpd reload 2>/dev/null || true
            log_ok "Configured OpenWrt UCI NTP servers onto US-first pools"
        else
            log_skip "OpenWrt UCI NTP servers already converged on US-first pools"
        fi
    fi

    OWRT_CN_DNS_RE='(114\.114\.114\.114|114\.114\.115\.115|223\.5\.5\.5|223\.6\.6\.6|119\.29\.29\.29|182\.254\.116\.116|180\.76\.76\.76|1\.2\.4\.8|210\.2\.4\.8)'
    OWRT_DNS_CHANGED="false"
    for _ocfg in /etc/config/network /etc/config/dhcp; do
        [[ -f "$_ocfg" ]] || continue
        if grep -Eq "$OWRT_CN_DNS_RE" "$_ocfg" 2>/dev/null; then
            mkdir -p /var/lib/rvdk/backups/openwrt
            [[ -f "/var/lib/rvdk/backups/openwrt/$(basename "$_ocfg").orig" ]] || cp -a "$_ocfg" "/var/lib/rvdk/backups/openwrt/$(basename "$_ocfg").orig" 2>/dev/null || true
            _tmp_odns="$(mktemp)"
            awk -v re="$OWRT_CN_DNS_RE" '
                {
                    if ($0 ~ re) {
                        chg = 0
                        for (i = 1; i <= NF; i++) {
                            tok = $i; gsub(/['''"]/, "", tok)
                            if (tok ~ ("^" re "$")) {
                                rep = (!seen_p++) ? "1.1.1.1" : "8.8.8.8"
                                sub(tok, rep, $i)
                                chg = 1
                            }
                        }
                    }
                    print
                }
            ' "$_ocfg" > "$_tmp_odns"
            chmod 0644 "$_tmp_odns"
            mv -f "$_tmp_odns" "$_ocfg"
            OWRT_DNS_CHANGED="true"
        fi
    done
    if [[ "$OWRT_DNS_CHANGED" == "true" ]]; then
        [[ -x /etc/init.d/dnsmasq ]] && /etc/init.d/dnsmasq reload 2>/dev/null || true
        log_ok "Replaced OpenWrt factory CN DNS forwarders with 1.1.1.1 / 8.8.8.8"
    fi
fi

if [[ -x /etc/init.d/sysntpd ]]; then
    if ! /etc/init.d/sysntpd enabled 2>/dev/null; then
        /etc/init.d/sysntpd enable 2>/dev/null || true
        /etc/init.d/sysntpd start 2>/dev/null || true
        log_ok "Enabled OpenWrt sysntpd NTP daemon"
    fi
fi

# 1. Optional Operator User, SSH Keys & Sudoers (when shadow-useradd / sudo are installed)
rvdk_prog 20 "Checking OpenWrt user & sudoers (${TARGET_USER:-root})..."
if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
    if id -u "$TARGET_USER" >/dev/null 2>&1; then
        log_skip "User '${TARGET_USER}' already exists"
    elif command -v useradd >/dev/null 2>&1; then
        mkdir -p /home
        useradd -m -s /bin/ash "$TARGET_USER"
        passwd -l "$TARGET_USER" >/dev/null 2>&1 || true
        log_ok "Created user '${TARGET_USER}'"
    else
        log_warn "Skipping user creation for '${TARGET_USER}' (OpenWrt uses root by default; install 'shadow-useradd' if non-root accounts are needed)"
    fi

    if id -u "$TARGET_USER" >/dev/null 2>&1; then
        USER_HOME="/home/${TARGET_USER}"
        if [[ -d "$USER_HOME" && ! -s "${USER_HOME}/.ssh/authorized_keys" ]]; then
            SRC_KEYS=""
            if [[ -s /etc/dropbear/authorized_keys ]]; then
                SRC_KEYS="/etc/dropbear/authorized_keys"
            elif [[ -s /root/.ssh/authorized_keys ]]; then
                SRC_KEYS="/root/.ssh/authorized_keys"
            fi
            if [[ -n "$SRC_KEYS" ]]; then
                mkdir -p "${USER_HOME}/.ssh"
                cp "$SRC_KEYS" "${USER_HOME}/.ssh/authorized_keys"
                chmod 0700 "${USER_HOME}/.ssh"
                chmod 0600 "${USER_HOME}/.ssh/authorized_keys"
                chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.ssh" 2>/dev/null || chown -R "${TARGET_USER}" "${USER_HOME}/.ssh" 2>/dev/null || true
                log_ok "Seeded ${USER_HOME}/.ssh/authorized_keys from ${SRC_KEYS}"
            fi
        fi

        if [[ "$NOPASSWD_SUDO" == "true" && -d /etc/sudoers.d ]]; then
            SUDOERS_FILE="/etc/sudoers.d/010_${TARGET_USER}-nopasswd"
            SUDOERS_RULE="${TARGET_USER} ALL=(ALL) NOPASSWD: ALL"
            if [[ ! -f "$SUDOERS_FILE" ]] || ! grep -qxF "$SUDOERS_RULE" "$SUDOERS_FILE"; then
                printf '%s\n' "$SUDOERS_RULE" > "$SUDOERS_FILE"
                chmod 0440 "$SUDOERS_FILE"
                log_ok "Configured passwordless sudo in ${SUDOERS_FILE}"
            else
                log_skip "Passwordless sudo already active at ${SUDOERS_FILE}"
            fi
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
            printf '%s\n' "$TARGET_HOSTNAME" > /proc/sys/kernel/hostname 2>/dev/null || true
            [[ -x /etc/init.d/system ]] && /etc/init.d/system reload 2>/dev/null || true
            log_ok "Updated OpenWrt UCI hostname: '${CUR_UCI_HOST:-OpenWrt}' -> '${TARGET_HOSTNAME}'"
        fi
    else
        printf '%s\n' "$TARGET_HOSTNAME" > /proc/sys/kernel/hostname 2>/dev/null || true
        log_ok "Updated kernel hostname to '${TARGET_HOSTNAME}'"
    fi
fi

# 3. CVE-2026-98432 Kernel IPv4 TCP Option Filter & MPTCP Lockdown
#    Persisted via BOTH `/usr/share/nftables.d/ruleset-post/` (loaded natively by
#    OpenWrt fw4 after `flush ruleset`) AND procd `START=99` (after fw4's START=19).
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
    FW4_POST_DIR="/usr/share/nftables.d/ruleset-post"
    FW4_POST_SNIPPET="${FW4_POST_DIR}/10-cve-2026-98432.nft"
    INIT_CVE="/etc/init.d/cve-2026-98432-guard"

    WANT_NFT_STANDALONE="add table ip cve_2026_98432
flush table ip cve_2026_98432
add chain ip cve_2026_98432 pre { type filter hook prerouting priority -300; policy accept; }
add rule ip cve_2026_98432 pre meta l4proto tcp ip hdrlength gt 5 counter drop"

    WANT_FW4_SNIPPET="table ip cve_2026_98432 {
    chain pre {
        type filter hook prerouting priority -300; policy accept;
        meta l4proto tcp ip hdrlength gt 5 counter drop
    }
}"

    WANT_INIT_CVE="#!/bin/sh /etc/rc.common
START=99
start() {
    /usr/sbin/nft -f /etc/cve-2026-98432.nft 2>/dev/null || true
}
reload() {
    start
}"

    mkdir -p "$FW4_POST_DIR"
    OWRT_CVE_CHANGED="false"
    if ! printf '%s\n' "$WANT_NFT_STANDALONE" | cmp -s - "$NFT_STANDALONE" 2>/dev/null; then
        printf '%s\n' "$WANT_NFT_STANDALONE" > "$NFT_STANDALONE"
        OWRT_CVE_CHANGED="true"
    fi
    if ! printf '%s\n' "$WANT_FW4_SNIPPET" | cmp -s - "$FW4_POST_SNIPPET" 2>/dev/null; then
        printf '%s\n' "$WANT_FW4_SNIPPET" > "$FW4_POST_SNIPPET"
        OWRT_CVE_CHANGED="true"
    fi
    if ! printf '%s\n' "$WANT_INIT_CVE" | cmp -s - "$INIT_CVE" 2>/dev/null; then
        printf '%s\n' "$WANT_INIT_CVE" > "$INIT_CVE"
        chmod +x "$INIT_CVE"
        "$INIT_CVE" enable 2>/dev/null || true
        OWRT_CVE_CHANGED="true"
    fi

    if [[ "$OWRT_CVE_CHANGED" == "true" ]] || ! nft list table ip cve_2026_98432 >/dev/null 2>&1; then
        if [[ -x /etc/init.d/firewall ]]; then
            /etc/init.d/firewall reload 2>/dev/null || true
        fi
        nft -f "$NFT_STANDALONE"
        log_ok "Configured fw4-persistent OpenWrt CVE-2026-98432 raw prerouting drop guard"
    else
        log_skip "CVE-2026-98432 TCP option filter & MPTCP lockdown already active"
    fi
else
    log_warn "nft CLI not present; applied sysctl MPTCP lockdown only"
fi

rvdk_prog 100 "OpenWrt Day-0 router normalization complete"
log_info "Day-0 OpenWrt bootstrap complete."
