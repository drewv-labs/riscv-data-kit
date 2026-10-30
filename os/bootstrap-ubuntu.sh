#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Day-0 Headless Ubuntu Node Bootstrap Script
# Path: riscv-data-kit/bootstrap-ubuntu.sh
# Description: Idempotent user/sudo/hostname bootstrap + headless GUI & snapd
#              eradication for Ubuntu 24.04+ RISC-V nodes.
#
# Usage:
#   ./bootstrap-ubuntu.sh --user drew --hostname brakerbox-p550 --nopasswd
#   ./bootstrap-ubuntu.sh --debloat-only
# ==============================================================================

set -euo pipefail

# --- Default State ---
TARGET_USER=""
TARGET_HOSTNAME=""
NOPASSWD_SUDO="false"
DEBLOAT_UBUNTU="true"
DEFAULT_GROUPS=("sudo" "adm" "dialout" "plugdev" "render" "video")

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

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
      --debloat-only          Only execute headless target, snapd, and GUI purge
      --keep-gui              Skip snapd and desktop GUI purge
  -h, --help                  Show this help message and exit

Example:
  $0 --user drew --hostname brakerbox-p550 --nopasswd
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
        --debloat-only)
            DEBLOAT_UBUNTU="true"
            shift
            ;;
        --keep-gui)
            DEBLOAT_UBUNTU="false"
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

if [[ "$NOPASSWD_SUDO" == "true" && -z "$TARGET_USER" ]]; then
    log_err "--nopasswd requires --user <username> to be specified."
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        log_info "Escalating privileges via sudo..."
        exec sudo -E bash "$0" "$@"
    else
        log_err "This script must be run as root."
        exit 1
    fi
fi

# ==============================================================================
# 1. USER, GROUP & NOPASSWD SUDO PROVISIONING
# ==============================================================================
if [[ -n "$TARGET_USER" ]]; then
    log_info "Processing user configuration for '${TARGET_USER}'..."

    if [[ ! "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log_err "Invalid POSIX username format: '${TARGET_USER}'"
        exit 1
    fi

    if id -u "$TARGET_USER" >/dev/null 2>&1; then
        log_skip "User '${TARGET_USER}' already exists"
    else
        log_info "Creating user '${TARGET_USER}'..."
        adduser --gecos "" "$TARGET_USER"
        log_ok "Created user '${TARGET_USER}'"
    fi

    for grp in "${DEFAULT_GROUPS[@]}"; do
        if getent group "$grp" >/dev/null 2>&1; then
            if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$grp"; then
                log_skip "User '${TARGET_USER}' is already in group '${grp}'"
            else
                usermod -aG "$grp" "$TARGET_USER"
                log_ok "Added '${TARGET_USER}' to group '${grp}'"
            fi
        fi
    done
fi

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
# 2. HOSTNAME CONFIGURATION
# ==============================================================================
if [[ -n "$TARGET_HOSTNAME" ]]; then
    CURRENT_HOSTNAME="$(hostname)"

    if [[ "$CURRENT_HOSTNAME" == "$TARGET_HOSTNAME" ]]; then
        log_skip "System hostname is already '${TARGET_HOSTNAME}'"
    else
        hostnamectl set-hostname "$TARGET_HOSTNAME"
        log_ok "Updated system hostname: '${CURRENT_HOSTNAME}' -> '${TARGET_HOSTNAME}'"
    fi

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

# ==============================================================================
# 3. HEADLESS TARGET, SNAPD ERADICATION & DESKTOP GUI PURGE
# ==============================================================================
if [[ "$DEBLOAT_UBUNTU" == "true" ]]; then
    log_info "Enforcing headless Ubuntu server configuration..."

    # 3.1 Lock boot target to headless console
    if [[ "$(systemctl get-default)" != "multi-user.target" ]]; then
        systemctl set-default multi-user.target
        systemctl stop gdm3 2>/dev/null || true
        log_ok "Boot target set to headless multi-user.target"
    else
        log_skip "Boot target is already multi-user.target"
    fi

    # 3.2 Purge snapd & prevent Canonical from re-installing it via APT pin
    if command -v snap >/dev/null 2>&1 || dpkg -l snapd 2>/dev/null | grep -q "^ii"; then
        for s in firefox snap-store gnome-42-2204 gtk-common-themes core22 bare snapd; do
            snap remove --purge "$s" 2>/dev/null || true
        done
        systemctl stop snapd.socket snapd.service 2>/dev/null || true
        apt-get purge "${APT_FLAGS[@]}" snapd 2>/dev/null || true
        rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd /root/snap /home/*/snap
        log_ok "Purged snapd and all snap mounts"
    else
        log_skip "snapd already purged"
    fi

    NOSNAP_PREF="/etc/apt/preferences.d/nosnap.pref"
    if [[ ! -f "$NOSNAP_PREF" ]]; then
        cat << 'EOF' > "$NOSNAP_PREF"
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
        log_ok "Pinned snapd to Priority -10 in $NOSNAP_PREF"
    else
        log_skip "APT nosnap preference pin already present"
    fi

    # 3.3 Purge Ubuntu Desktop GUI, crash reporters & background apt locks
    GUI_BLOAT=(
        ubuntu-desktop ubuntu-desktop-minimal gnome-shell gdm3 xwayland
        apport whoopsie unattended-upgrades packagekit modemmanager
    )
    PURGE_LIST=()
    for pkg in "${GUI_BLOAT[@]}"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            PURGE_LIST+=("$pkg")
        fi
    done

    if [[ ${#PURGE_LIST[@]} -gt 0 ]]; then
        apt-get purge "${APT_FLAGS[@]}" "${PURGE_LIST[@]}"
        apt-get autoremove "${APT_FLAGS[@]}" --purge
        apt-get clean
        log_ok "Purged Ubuntu GUI & background daemon bloat: ${PURGE_LIST[*]}"
    else
        log_skip "Ubuntu desktop GUI & telemetry bloat already purged"
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

# ----------------------------------------------------------------------------
log_info "Day-0 Ubuntu headless bootstrap complete. Node is ready for forge.sh."
