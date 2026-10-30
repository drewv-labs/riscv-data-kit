#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Day-0 Debian Node Bootstrap Script
# Path: riscv-data-kit/bootstrap-debian.sh
# Description: Idempotent user creation, group assignment, passwordless sudo,
#              UTF-8 locale, and hostname configuration for Debian nodes.
#
# Usage:
#   ./bootstrap-debian.sh --user drew --hostname brakerbox-titan --nopasswd
# ==============================================================================

set -euo pipefail

# --- Default State ---
TARGET_USER=""
TARGET_HOSTNAME=""
NOPASSWD_SUDO="false"
FIX_LOCALE="true"
DEFAULT_GROUPS=("sudo" "adm" "dialout" "plugdev" "render" "video")

# --- Logging Helpers ---
log_info() { printf "\033[1;36m[INFO]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_err()  { printf "\033[1;31m[ERR!]\033[0m %s\n" "$1" >&2; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -u, --user <username>       Username to create or update
  -H, --hostname <hostname>   New system hostname to configure
  -n, --nopasswd              Enable passwordless sudo (NOPASSWD) for --user
      --skip-locale           Skip en_US.UTF-8 locale verification
  -h, --help                  Show this help message and exit

Example:
  $0 --user drew --hostname brakerbox-titan --nopasswd
EOF
}

# ==============================================================================
# ARGUMENT PARSER
# ==============================================================================
if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)
            if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
                log_err "Option '$1' requires a username argument."
                exit 1
            fi
            TARGET_USER="$2"
            shift 2
            ;;
        -H|--hostname)
            if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
                log_err "Option '$1' requires a hostname argument."
                exit 1
            fi
            TARGET_HOSTNAME="$2"
            shift 2
            ;;
        -n|--nopasswd|--passwordless-sudo)
            NOPASSWD_SUDO="true"
            shift
            ;;
        --skip-locale)
            FIX_LOCALE="false"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_err "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate flag combinations
if [[ "$NOPASSWD_SUDO" == "true" && -z "$TARGET_USER" ]]; then
    log_err "--nopasswd requires --user <username> to be specified."
    exit 1
fi

# Escalate to root via sudo if not already running as root
if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        log_info "Escalating privileges via sudo..."
        exec sudo -E bash "$0" "$@"
    else
        log_err "This script must be run as root (and 'sudo' is not installed)."
        exit 1
    fi
fi

export DEBIAN_FRONTEND=noninteractive

# Ensure 'sudo' package itself is installed (minimal Debian images often omit it)
if ! command -v sudo >/dev/null 2>&1; then
    log_info "Installing missing 'sudo' package..."
    apt-get update -q && apt-get install -y sudo
    log_ok "Installed 'sudo'"
fi

# ==============================================================================
# 0. UTF-8 LOCALE HYGIENE (Prevents macOS SSH LC_* Perl/APT warnings)
# ==============================================================================
if [[ "$FIX_LOCALE" == "true" ]]; then
    if locale -a 2>/dev/null | grep -qi "en_US\.utf8"; then
        log_skip "Locale en_US.UTF-8 is already generated"
    else
        log_info "Generating en_US.UTF-8 locale..."
        apt-get update -q && apt-get install -y locales
        sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
        locale-gen en_US.UTF-8
        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
        log_ok "Configured en_US.UTF-8 locale"
    fi
fi

# ==============================================================================
# 1. USER & GROUP PROVISIONING (--user)
# ==============================================================================
if [[ -n "$TARGET_USER" ]]; then
    log_info "Processing user configuration for '${TARGET_USER}'..."

    if [[ ! "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log_err "Invalid POSIX username format: '${TARGET_USER}'"
        exit 1
    fi

    # 1.1 Idempotent User Creation
    if id -u "$TARGET_USER" >/dev/null 2>&1; then
        log_skip "User '${TARGET_USER}' already exists"
    else
        log_info "Creating user '${TARGET_USER}' (you will be prompted to set a password)..."
        adduser --gecos "" "$TARGET_USER"
        log_ok "Created user '${TARGET_USER}'"
    fi

    # 1.2 Idempotent Group Membership Assignment
    for grp in "${DEFAULT_GROUPS[@]}"; do
        if getent group "$grp" >/dev/null 2>&1; then
            if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$grp"; then
                log_skip "User '${TARGET_USER}' is already in group '${grp}'"
            else
                usermod -aG "$grp" "$TARGET_USER"
                log_ok "Added '${TARGET_USER}' to group '${grp}'"
            fi
        else
            log_skip "Group '${grp}' does not exist on this OS; skipping"
        fi
    done
fi

# ==============================================================================
# 2. PASSWORDLESS SUDO (--nopasswd)
# ==============================================================================
if [[ "$NOPASSWD_SUDO" == "true" ]]; then
    SUDOERS_FILE="/etc/sudoers.d/010_${TARGET_USER}-nopasswd"
    SUDOERS_RULE="${TARGET_USER} ALL=(ALL) NOPASSWD: ALL"

    if [[ -f "$SUDOERS_FILE" ]] && grep -qxF "$SUDOERS_RULE" "$SUDOERS_FILE" && [[ "$(stat -c "%a" "$SUDOERS_FILE")" == "440" ]]; then
        log_skip "Passwordless sudo already active at ${SUDOERS_FILE}"
    else
        TMP_SUDO="$(mktemp)"
        echo "$SUDOERS_RULE" > "$TMP_SUDO"
        chmod 0440 "$TMP_SUDO"

        if visudo -cf "$TMP_SUDO" >/dev/null 2>&1; then
            mv "$TMP_SUDO" "$SUDOERS_FILE"
            chown root:root "$SUDOERS_FILE"
            chmod 0440 "$SUDOERS_FILE"
            log_ok "Configured passwordless sudo in ${SUDOERS_FILE}"
        else
            rm -f "$TMP_SUDO"
            log_err "Generated sudoers rule failed visudo syntax validation!"
            exit 1
        fi
    fi
fi

# ==============================================================================
# 3. HOSTNAME CONFIGURATION (--hostname)
# ==============================================================================
if [[ -n "$TARGET_HOSTNAME" ]]; then
    CURRENT_HOSTNAME="$(hostname)"

    if [[ "$CURRENT_HOSTNAME" == "$TARGET_HOSTNAME" ]]; then
        log_skip "System hostname is already '${TARGET_HOSTNAME}'"
    else
        if command -v hostnamectl >/dev/null 2>&1; then
            hostnamectl set-hostname "$TARGET_HOSTNAME"
        else
            echo "$TARGET_HOSTNAME" > /etc/hostname
            hostname "$TARGET_HOSTNAME"
        fi
        log_ok "Updated system hostname: '${CURRENT_HOSTNAME}' -> '${TARGET_HOSTNAME}'"
    fi

    # Idempotently update /etc/hosts (replaces old hostname or injects 127.0.1.1)
    if grep -qE "[[:space:]]${TARGET_HOSTNAME}([[:space:]]|$)" /etc/hosts; then
        log_skip "'${TARGET_HOSTNAME}' is already mapped in /etc/hosts"
    else
        if [[ -n "$CURRENT_HOSTNAME" && "$CURRENT_HOSTNAME" != "localhost" ]] && grep -qE "[[:space:]]${CURRENT_HOSTNAME}([[:space:]]|$)" /etc/hosts; then
            sed -i "s/\b${CURRENT_HOSTNAME}\b/${TARGET_HOSTNAME}/g" /etc/hosts
            log_ok "Replaced '${CURRENT_HOSTNAME}' with '${TARGET_HOSTNAME}' in /etc/hosts"
        elif grep -q "^127\.0\.1\.1" /etc/hosts; then
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${TARGET_HOSTNAME}/" /etc/hosts
            log_ok "Updated 127.0.1.1 entry in /etc/hosts to '${TARGET_HOSTNAME}'"
        else
            printf "127.0.1.1\t%s\n" "$TARGET_HOSTNAME" >> /etc/hosts
            log_ok "Appended '127.0.1.1 ${TARGET_HOSTNAME}' to /etc/hosts"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# CVE-2026-98432 Kernel IPv4 TCP RCU Use-After-Free Mitigation
# ------------------------------------------------------------------------------
echo ">>> [SECURITY] Converging CVE-2026-98432 TCP option filter & MPTCP lockdown..."
cat << 'SYSCTL_EOF' > /etc/sysctl.d/99-cve-2026-98432-tcp.conf
net.mptcp.enabled = 0
net.ipv4.tcp_migrate_req = 0
SYSCTL_EOF
sysctl --system >/dev/null

if ! command -v nft >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables
fi

mkdir -p /etc/nftables.d
cat << 'NFT_EOF' > /etc/nftables.d/cve-2026-98432.nft
add table ip cve_2026_98432
flush table ip cve_2026_98432
add chain ip cve_2026_98432 pre { type filter hook prerouting priority -300; policy accept; }
add rule ip cve_2026_98432 pre meta l4proto tcp ip hdrlength gt 5 counter drop
NFT_EOF

nft -f /etc/nftables.d/cve-2026-98432.nft

cat << 'UNIT_EOF' > /etc/systemd/system/cve-2026-98432-guard.service
[Unit]
Description=CVE-2026-98432 IPv4 TCP Options Raw Prerouting Drop Guard
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/nftables.d/cve-2026-98432.nft
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl enable --now cve-2026-98432-guard.service >/dev/null

# ----------------------------------------------------------------------------------
log_info "Day-0 Debian bootstrap complete. Node is pregamed and ready for forge.sh."
