#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Day-0 OpenWrt RISC-V Router Node Bootstrap Script
# Path: riscv-data-kit/os/bootstrap-openwrt.sh
# Description: Idempotent Layer 1D cold-RTC sync, US-first opkg/apk feed & pure
#              UCI NTP/dnsmasq normalization, UCI hostname, optional operator
#              SSH/sudo account, and fw4-integrated IPv4 IP-Options Prerouting
#              Drop Guard (`ip hdrlength > 20B`) & MPTCP Lockdown for OpenWrt
#              RISC-V gateway/router nodes (e.g., Orange Pi R2S).
#
# Usage:
#   ./bootstrap-openwrt.sh [--hostname r2s-gw] [--user rvadmin] [--nopasswd] [--skip-net-guard] [--noprogbar]
# ==============================================================================

set -Eeuo pipefail

TARGET_USER=""
TARGET_HOSTNAME=""
NOPASSWD_SUDO="false"
SKIP_NET_GUARD="false"
if [[ "${RVDK_SKIP_NET_GUARD:-0}" == "1" || "${RVDK_SKIP_NET_GUARD:-false}" == "true" ]]; then
    SKIP_NET_GUARD="true"
fi
ORIG_ARGS=("$@")

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/.." && pwd)"

# @RVDK_INLINE_LIBS: common motd progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
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
        rvdk_atomic_write() {
            local _dst="$1" _mode="${2:-0644}" _tmp
            mkdir -p "$(dirname "$_dst")"
            _tmp="$(mktemp "$(dirname "$_dst")/.$(basename "$_dst").rvdk.XXXXXX")"
            cat > "$_tmp"
            chmod "$_mode" "$_tmp"
            mv -f "$_tmp" "$_dst"
        }
        rvdk_sync_cold_clock() { :; }
    fi
fi
if [[ -z "${_RVDK_MOTD_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/motd.sh" ]]; then
        # shellcheck source=lib/motd.sh
        source "${_REPO_ROOT}/lib/motd.sh"
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

rvdk_log_init "RVDK:OPENWRT"

if [[ -z "${_RVDK_TMPFILES+x}" ]]; then
    _RVDK_TMPFILES=()
fi
if ! typeset -f _rvdk_cleanup_tmpfiles >/dev/null 2>&1; then
    _rvdk_cleanup_tmpfiles() {
        local _tf
        for _tf in ${_RVDK_TMPFILES[@]+"${_RVDK_TMPFILES[@]}"}; do
            [[ -n "$_tf" ]] && rm -f "$_tf" 2>/dev/null || true
        done
        _RVDK_TMPFILES=()
    }
fi
if ! typeset -f _rvdk_untrack_tmpfile >/dev/null 2>&1; then
    _rvdk_untrack_tmpfile() {
        local target="${1:-}"
        [[ -n "$target" ]] || return 0
        local -a kept=()
        local _tf
        for _tf in ${_RVDK_TMPFILES[@]+"${_RVDK_TMPFILES[@]}"}; do
            [[ -n "$_tf" && "$_tf" != "$target" ]] && kept+=("$_tf")
        done
        if [[ ${#kept[@]} -gt 0 ]]; then
            _RVDK_TMPFILES=("${kept[@]}")
        else
            _RVDK_TMPFILES=()
        fi
    }
fi
if ! typeset -f rvdk_register_tmpfile >/dev/null 2>&1; then
    rvdk_register_tmpfile() {
        local tf="${1:-}"
        [[ -n "$tf" ]] || return 0
        if typeset -f _rvdk_install_cleanup_trap >/dev/null 2>&1; then
            _rvdk_install_cleanup_trap "true"
            _RVDK_TMPFILES+=("$tf")
        else
            _RVDK_TMPFILES+=("$tf")
            if [[ -z "$(trap -p EXIT 2>/dev/null || true)" ]]; then
                trap '_rvdk_cleanup_tmpfiles' EXIT
                trap 'trap - EXIT INT; _rvdk_cleanup_tmpfiles; kill -INT $$' INT
                trap 'trap - EXIT TERM; _rvdk_cleanup_tmpfiles; kill -TERM $$' TERM
            fi
        fi
    }
fi

if ! typeset -f rvdk_sudo_preserve >/dev/null 2>&1; then
    rvdk_sudo_preserve() {
        [[ $# -gt 0 ]] || return 1
        local -a _allowlist=(
            RVDK_ALLOW_CIDR
            RVDK_APT_DISTRO_DEFAULT
            RVDK_ARCH
            RVDK_BOARD
            RVDK_BOARD_QUIRKS
            RVDK_BOARD_TAG
            RVDK_BOOT_BACKUP_DIR
            RVDK_BRANCH
            RVDK_CACHE_DIR
            RVDK_DEEPTUNE_CHAIN
            RVDK_DEEPTUNE_ENV
            RVDK_DEEPTUNE_LAYERS
            RVDK_DT_MODEL
            RVDK_FLASH_FORCE_RAW
            RVDK_HOSTNAME
            RVDK_KEEP_VENDOR_MIRRORS
            RVDK_LOCALE
            RVDK_MAX_VALID_EPOCH
            RVDK_MIN_VALID_EPOCH
            RVDK_MMU
            RVDK_NO_APT_UPDATE
            RVDK_NO_PROGBAR
            RVDK_OS_ID
            RVDK_OS_VERSION_ID
            RVDK_P550_HDMI_STATE_FILE
            RVDK_PARENT_BADGE_SGR
            RVDK_PARENT_BAR_SGR
            RVDK_PARENT_LABEL
            RVDK_PARENT_PROGBAR
            RVDK_PARENT_STATE
            RVDK_PRIMARY_NIC
            RVDK_PROGBAR_SESSION
            RVDK_PROG_BASE
            RVDK_PROG_SPAN
            RVDK_SECONDARY_NIC
            RVDK_SKIP_NET_GUARD
            RVDK_SOC
            RVDK_SOC_SLUG
            RVDK_SUB_STATE
            RVDK_TIMEZONE
            RVDK_TUNE
            RVDK_TUNE_MODE
        )
        local preserve_csv=""
        local var_name
        for var_name in "${_allowlist[@]}"; do
            if [[ -n "${!var_name+x}" ]]; then
                preserve_csv+="${preserve_csv:+,}${var_name}"
            fi
        done

        local rc=0
        if [[ -z "$preserve_csv" ]]; then
            sudo "$@" || rc=$?
            return "$rc"
        fi

        local probe_err="" probe_rc=0
        probe_err="$(sudo --preserve-env="$preserve_csv" -n true 2>&1)" || probe_rc=$?
        if [[ "$probe_rc" -eq 0 ]]; then
            sudo --preserve-env="$preserve_csv" "$@" || rc=$?
            return "$rc"
        fi

        if [[ "$probe_err" =~ (not[[:space:]]+allowed|SETENV|preserve-env|unrecognized[[:space:]]+option|unknown[[:space:]]+option|illegal[[:space:]]+option|invalid[[:space:]]+option|unexpected[[:space:]]+argument) ]] \
            || sudo -n true >/dev/null 2>&1; then
            sudo "$@" || rc=$?
            return "$rc"
        fi

        if sudo -v; then
            if sudo --preserve-env="$preserve_csv" -n true >/dev/null 2>&1; then
                sudo --preserve-env="$preserve_csv" "$@" || rc=$?
                return "$rc"
            fi
            sudo "$@" || rc=$?
            return "$rc"
        fi
        return 1
    }
fi

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -H, --hostname <hostname>   RFC-1123 system hostname to persist via OpenWrt UCI
  -u, --user <username>       Optional non-root operator account (requires shadow-useradd)
  -n, --nopasswd              Enable passwordless sudo if sudo is installed
      --keep-mirrors          Preserve existing OpenWrt package, dnsmasq & NTP mirror configs
      --skip-net-guard        Skip IPv4 IP-Options Prerouting Drop Guard (ip hdrlength > 20B) & MPTCP Lockdown
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
        --skip-net-guard)
            SKIP_NET_GUARD="true"
            export RVDK_SKIP_NET_GUARD="1"
            shift ;;
        --prompt-password|--debloat-only|--keep-gui|--skip-locale|--no-apt-update|--skip-apt-update)
            shift ;;
        --noprogbar|--no-progbar)
            export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            log_fatal "Unknown argument: $1 (try --help)" ;;
    esac
done

if [[ "$NOPASSWD_SUDO" == "true" && -z "$TARGET_USER" ]]; then
    log_fatal "--nopasswd requires --user <username> to be specified."
fi
if [[ -n "$TARGET_USER" ]] && ! rvdk_validate_username "$TARGET_USER"; then
    log_fatal "Invalid POSIX username format: '${TARGET_USER}'."
fi
if [[ -n "$TARGET_HOSTNAME" ]] && ! rvdk_validate_hostname "$TARGET_HOSTNAME"; then
    log_fatal "Invalid RFC-1123 hostname: '${TARGET_HOSTNAME}'."
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && command -v sudo >/dev/null 2>&1; then
        _rvdk_sudo_rc=0
        rvdk_sudo_preserve bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} || _rvdk_sudo_rc=$?
        exit "$_rvdk_sudo_rc"
    else
        log_fatal "This script must be run as root."
    fi
fi

export LANG="C" LC_ALL="C"

rvdk_prog_init "OpenWrt Day-0 router normalization..."
rvdk_sync_cold_clock

# 0. Normalize OpenWrt package feeds & pure UCI NTP/dnsmasq servers onto US-first endpoints
#    Invariant: NEVER touch `/etc/config/network` and NEVER directly awk/sed `/etc/config/*`.
if [[ "${RVDK_KEEP_VENDOR_MIRRORS:-0}" != "1" && "${RVDK_KEEP_VENDOR_MIRRORS:-false}" != "true" ]]; then
    OWRT_CN_HOSTS=""
    if typeset -f rvdk_cn_mirror_hosts_regex >/dev/null 2>&1; then
        OWRT_CN_HOSTS="$(rvdk_cn_mirror_hosts_regex)"
    fi
    OWRT_SCHEME="http"
    [[ -s /etc/ssl/certs/ca-certificates.crt || -s /etc/ssl/certs/ca-bundle.crt ]] && OWRT_SCHEME="https"
    OWRT_FEED_CHANGED="false"
    for _of in /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf /etc/apk/repositories; do
        [[ -n "$OWRT_CN_HOSTS" && -f "$_of" ]] || continue
        _rendered_of="$(sed -E "/^[[:space:]]*#/! s@https?://(${OWRT_CN_HOSTS})/openwrt([[:space:]/]|$)@${OWRT_SCHEME}://downloads.openwrt.org\\2@g" "$_of")"
        if ! printf '%s\n' "$_rendered_of" | cmp -s - "$_of" 2>/dev/null; then
            mkdir -p /var/lib/rvdk/backups/openwrt
            [[ -f "/var/lib/rvdk/backups/openwrt/$(basename "$_of").orig" ]] || cp -a "$_of" "/var/lib/rvdk/backups/openwrt/$(basename "$_of").orig" 2>/dev/null || true
            printf '%s\n' "$_rendered_of" | rvdk_atomic_write "$_of" 0644
            OWRT_FEED_CHANGED="true"
        fi
    done
    [[ "$OWRT_FEED_CHANGED" == "true" ]] && log_ok "Normalized OpenWrt package feeds onto ${OWRT_SCHEME}://downloads.openwrt.org"

    if command -v uci >/dev/null 2>&1; then
        CUR_OWRT_NTP="$(uci -q get system.ntp.server || true)"
        WANT_OWRT_NTP="0.us.pool.ntp.org 1.us.pool.ntp.org 2.us.pool.ntp.org 3.us.pool.ntp.org time.cloudflare.com"
        if [[ "$CUR_OWRT_NTP" != "$WANT_OWRT_NTP" ]]; then
            if [[ -f /etc/config/system && ! -f /var/lib/rvdk/backups/openwrt/system.orig ]]; then
                mkdir -p /var/lib/rvdk/backups/openwrt
                cp -a /etc/config/system /var/lib/rvdk/backups/openwrt/system.orig 2>/dev/null || true
            fi
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

        # Scrub hardcoded CN resolvers strictly on `dhcp` `dnsmasq` sections via `uci` CLI
        OWRT_CN_DNS_RE='^(114\.114\.114\.114|114\.114\.115\.115|223\.5\.5\.5|223\.6\.6\.6|119\.29\.29\.29|182\.254\.116\.116|180\.76\.76\.76|1\.2\.4\.8|210\.2\.4\.8)$'
        OWRT_DNS_CHANGED="false"
        while IFS= read -r _dns_sec; do
            [[ -n "$_dns_sec" ]] || continue
            _cur_srv_list="$(uci -q get "dhcp.${_dns_sec}.server" || true)"
            [[ -n "$_cur_srv_list" ]] || continue

            _sec_had_cn="false"
            _had_noglob="false"
            [[ $- == *f* ]] && _had_noglob="true"
            set -f
            # shellcheck disable=SC2206 # intentional word-splitting under set -f
            _srv_tokens=($_cur_srv_list)
            [[ "$_had_noglob" == "false" ]] && set +f
            for _srv_tok in ${_srv_tokens[@]+"${_srv_tokens[@]}"}; do
                if [[ "$_srv_tok" =~ $OWRT_CN_DNS_RE ]]; then
                    if [[ "$OWRT_DNS_CHANGED" == "false" && -f /etc/config/dhcp && ! -f /var/lib/rvdk/backups/openwrt/dhcp.orig ]]; then
                        mkdir -p /var/lib/rvdk/backups/openwrt
                        cp -a /etc/config/dhcp /var/lib/rvdk/backups/openwrt/dhcp.orig 2>/dev/null || true
                    fi
                    uci -q del_list "dhcp.${_dns_sec}.server=${_srv_tok}" || true
                    _sec_had_cn="true"
                    OWRT_DNS_CHANGED="true"
                fi
            done

            if [[ "$_sec_had_cn" == "true" ]]; then
                _rem_srv_list="$(uci -q get "dhcp.${_dns_sec}.server" || true)"
                for _us_dns in 1.1.1.1 8.8.8.8; do
                    case " ${_rem_srv_list} " in
                        *" ${_us_dns} "*) ;;
                        *)
                            uci add_list "dhcp.${_dns_sec}.server=${_us_dns}"
                            _rem_srv_list="${_rem_srv_list} ${_us_dns}"
                            ;;
                    esac
                done
            fi
        done < <(uci show dhcp 2>/dev/null | awk -F'[.=]' '$1 == "dhcp" && $3 == "dnsmasq" { print $2 }')

        if [[ "$OWRT_DNS_CHANGED" == "true" ]]; then
            uci commit dhcp
            [[ -x /etc/init.d/dnsmasq ]] && /etc/init.d/dnsmasq reload 2>/dev/null || true
            log_ok "Scrubbed OpenWrt dnsmasq CN DNS forwarders via UCI (-> 1.1.1.1, 8.8.8.8)"
        fi
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
                TMP_SUDOERS="$(mktemp "/etc/sudoers.d/.010_${TARGET_USER}-nopasswd.rvdk.XXXXXX")"
                rvdk_register_tmpfile "$TMP_SUDOERS"
                if ! printf '%s\n' "$SUDOERS_RULE" > "$TMP_SUDOERS" || ! chmod 0440 "$TMP_SUDOERS"; then
                    rm -f "$TMP_SUDOERS"
                    _rvdk_untrack_tmpfile "$TMP_SUDOERS"
                    log_fatal "Failed to stage sudoers rule at ${TMP_SUDOERS}."
                fi
                if command -v visudo >/dev/null 2>&1; then
                    if ! visudo -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
                        rm -f "$TMP_SUDOERS"
                        _rvdk_untrack_tmpfile "$TMP_SUDOERS"
                        log_fatal "Generated sudoers rule failed visudo syntax check for '${TARGET_USER}'."
                    fi
                fi
                if ! mv -f "$TMP_SUDOERS" "$SUDOERS_FILE"; then
                    rm -f "$TMP_SUDOERS"
                    _rvdk_untrack_tmpfile "$TMP_SUDOERS"
                    log_fatal "Failed to install validated sudoers rule to ${SUDOERS_FILE}."
                fi
                _rvdk_untrack_tmpfile "$TMP_SUDOERS"
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

# 3. RVDK IPv4 IP-Options Prerouting Drop Guard (`ip hdrlength > 20B`) & MPTCP Lockdown
#    Persisted via BOTH `/usr/share/nftables.d/ruleset-post/` (loaded natively by
#    OpenWrt fw4 after `flush ruleset`) AND procd `START=99` (after fw4's START=19).
rvdk_prog 80 "Converging rvdk-net-guard IPv4 IP-options & MPTCP guard..."

# Retire legacy synthetic cve-2026-98432* files/init/tables
if [[ -x /etc/init.d/cve-2026-98432-guard ]]; then
    /etc/init.d/cve-2026-98432-guard disable 2>/dev/null || true
fi
rm -f \
    /etc/sysctl.d/99-cve-2026-98432-tcp.conf \
    /etc/cve-2026-98432.nft \
    /usr/share/nftables.d/ruleset-post/10-cve-2026-98432.nft \
    /etc/init.d/cve-2026-98432-guard 2>/dev/null || true
if command -v nft >/dev/null 2>&1 && nft list table ip cve_2026_98432 >/dev/null 2>&1; then
    nft delete table ip cve_2026_98432 2>/dev/null || true
fi

if [[ "$SKIP_NET_GUARD" == "true" ]]; then
    log_skip "Skipped rvdk-net-guard IPv4 IP-options & MPTCP lockdown (--skip-net-guard)"
else
    mkdir -p /etc/sysctl.d
    SYSCTL_GUARD_FILE="/etc/sysctl.d/99-rvdk-net-guard.conf"
    SYSCTL_LINES=(
        "# Managed by RVDK (os/bootstrap-openwrt.sh)"
        "# IPv4 IP-Options Prerouting Drop Guard (ip hdrlength > 20B) & MPTCP Lockdown"
    )
    [[ -e /proc/sys/net/mptcp/enabled ]]        && SYSCTL_LINES+=("net.mptcp.enabled = 0")
    [[ -e /proc/sys/net/ipv4/tcp_migrate_req ]] && SYSCTL_LINES+=("net.ipv4.tcp_migrate_req = 0")
    WANT_OWRT_SYSCTL="$(printf '%s\n' "${SYSCTL_LINES[@]}")"
    if ! printf '%s\n' "$WANT_OWRT_SYSCTL" | cmp -s - "$SYSCTL_GUARD_FILE" 2>/dev/null; then
        printf '%s\n' "$WANT_OWRT_SYSCTL" | rvdk_atomic_write "$SYSCTL_GUARD_FILE" 0644
        sysctl -p "$SYSCTL_GUARD_FILE" >/dev/null 2>&1 || true
    fi

    if command -v nft >/dev/null 2>&1; then
        NFT_STANDALONE="/etc/rvdk-net-guard.nft"
        FW4_POST_DIR="/usr/share/nftables.d/ruleset-post"
        FW4_POST_SNIPPET="${FW4_POST_DIR}/10-rvdk-net-guard.nft"
        INIT_GUARD="/etc/init.d/rvdk-net-guard"

        WANT_NFT_STANDALONE="add table ip rvdk_net_guard
flush table ip rvdk_net_guard
add chain ip rvdk_net_guard pre { type filter hook prerouting priority -300; policy accept; }
add rule ip rvdk_net_guard pre meta l4proto tcp ip hdrlength gt 5 counter drop"

        WANT_FW4_SNIPPET="table ip rvdk_net_guard {
    chain pre {
        type filter hook prerouting priority -300; policy accept;
        meta l4proto tcp ip hdrlength gt 5 counter drop
    }
}"

        WANT_INIT_GUARD="#!/bin/sh /etc/rc.common
# RVDK IPv4 IP-Options Prerouting Drop Guard (ip hdrlength > 20B) & MPTCP Lockdown
START=99
start() {
    /usr/sbin/nft -f /etc/rvdk-net-guard.nft 2>/dev/null || true
}
reload() {
    start
}"

        mkdir -p "$FW4_POST_DIR"
        OWRT_GUARD_CHANGED="false"
        if ! printf '%s\n' "$WANT_NFT_STANDALONE" | cmp -s - "$NFT_STANDALONE" 2>/dev/null; then
            printf '%s\n' "$WANT_NFT_STANDALONE" | rvdk_atomic_write "$NFT_STANDALONE" 0644
            OWRT_GUARD_CHANGED="true"
        fi
        if ! printf '%s\n' "$WANT_FW4_SNIPPET" | cmp -s - "$FW4_POST_SNIPPET" 2>/dev/null; then
            printf '%s\n' "$WANT_FW4_SNIPPET" | rvdk_atomic_write "$FW4_POST_SNIPPET" 0644
            OWRT_GUARD_CHANGED="true"
        fi
        if ! printf '%s\n' "$WANT_INIT_GUARD" | cmp -s - "$INIT_GUARD" 2>/dev/null; then
            printf '%s\n' "$WANT_INIT_GUARD" | rvdk_atomic_write "$INIT_GUARD" 0755
            "$INIT_GUARD" enable 2>/dev/null || true
            OWRT_GUARD_CHANGED="true"
        fi

        if [[ "$OWRT_GUARD_CHANGED" == "true" ]] || ! nft list table ip rvdk_net_guard >/dev/null 2>&1; then
            if [[ -x /etc/init.d/firewall ]]; then
                /etc/init.d/firewall reload 2>/dev/null || true
            fi
            nft -f "$NFT_STANDALONE"
            log_ok "Configured fw4-persistent OpenWrt rvdk-net-guard IPv4 IP-Options Prerouting Drop Guard (ip hdrlength > 20B)"
        else
            log_skip "rvdk-net-guard IPv4 IP-Options Prerouting Drop Guard & MPTCP Lockdown already active"
        fi
    else
        log_warn "nft CLI not present; applied sysctl MPTCP lockdown only"
    fi
fi

# 4. Unified RVDK Login Header (`/etc/profile.d/10-rvdk-motd.sh` + empty `/etc/banner`)
rvdk_prog 95 "Converging OpenWrt RVDK login header..."
if declare -F rvdk_converge_openwrt_motd >/dev/null 2>&1; then
    rvdk_converge_openwrt_motd
fi

rvdk_prog 100 "OpenWrt Day-0 router normalization complete"
log_info "Day-0 OpenWrt bootstrap complete."
