#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Unified Day-0 APT Headless OS Bootstrap (Debian / Ubuntu / Bianbu)
# Path: riscv-data-kit/os/bootstrap-apt.sh
#
# Description:
#   Idempotent Day-0 OS normalization across Debian, Ubuntu, and SpacemiT Bianbu
#   RISC-V nodes:
#     • UTF-8 locale hygiene & non-interactive `sudo` availability
#     • Strict RFC-1123 hostname convergence with awk-safe `/etc/hosts` rewrite
#     • Non-interactive POSIX user provisioning (safe under `curl | sudo bash`),
#       automatic SSH `authorized_keys` inheritance, & `visudo`-verified sudoers
#     • Headless `multi-user.target` lock, `snapd` pin/purge, & distro GUI purge
#       (honoring `--debloat-only` and `--keep-gui`)
#     • Persistent CVE-2026-98432 raw prerouting TCP-options guard + MPTCP lockdown
#       ordered safely with `nftables.service`
# ==============================================================================

set -Eeuo pipefail

ORIG_ARGS=("$@")
DISTRO_FLAVOR="${RVDK_APT_DISTRO_DEFAULT:-auto}"
TARGET_USER=""
TARGET_HOSTNAME=""
NOPASSWD_SUDO="false"
DEBLOAT_ONLY="false"
KEEP_GUI="false"
FIX_LOCALE="true"
PROMPT_PASSWORD="false"
DEFAULT_GROUPS=("sudo" "adm" "dialout" "plugdev" "render" "video")

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/.." && pwd)"

# @RVDK_INLINE_LIBS: common apt progbar
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${_REPO_ROOT}/lib/common.sh"
else
    log_info()  { printf "\033[1;36m[RVDK:OS]\033[0m %s\n" "$1"; }
    log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
    log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
    log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
    log_err()   { printf "\033[1;31m[ERR!]\033[0m %s\n" "$1" >&2; }
    log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
    rvdk_log_init() { :; }
    rvdk_validate_username() { [[ "${1:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
    rvdk_validate_hostname() { [[ ${#1} -ge 1 && ${#1} -le 253 && "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; }
    rvdk_sanitize_locale() { export LANG="C.UTF-8" LC_ALL="C.UTF-8"; }
    rvdk_resolve_caller() { REAL_USER="${SUDO_USER:-root}"; REAL_HOME="/root"; }
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/apt.sh" ]]; then
    # shellcheck source=lib/apt.sh
    source "${_REPO_ROOT}/lib/apt.sh"
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]]; then
    # shellcheck source=lib/progbar.sh
    source "${_REPO_ROOT}/lib/progbar.sh"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_log_init "RVDK:OS"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
      --distro <debian|ubuntu|bianbu|auto>
                              Target APT OS flavor (default: ${DISTRO_FLAVOR})
  -u, --user <username>       POSIX operator username to create or converge
  -H, --hostname <hostname>   RFC-1123 system hostname to configure
  -n, --nopasswd              Enable passwordless sudo (NOPASSWD) for --user
      --prompt-password       Interactively set a password via /dev/tty on user creation
      --debloat-only          Execute headless target, snapd & GUI purge, then exit
      --keep-gui              Preserve graphical target, snapd & desktop packages
      --skip-locale           Skip en_US.UTF-8 locale generation
      --no-apt-update         Skip redundant apt-get update calls
      --noprogbar             Suppress persistent bottom progress bar
  -h, --help                  Show this help message and exit

Example:
  $0 --distro ubuntu --user rvadmin --hostname rv-node01 --nopasswd
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --distro)
            [[ -z "${2:-}" || "${2:-}" == --* ]] && log_fatal "Option '$1' requires a distro argument."
            DISTRO_FLAVOR="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
            shift 2
            ;;
        -u|--user)
            [[ -z "${2:-}" || "${2:-}" == --* ]] && log_fatal "Option '$1' requires a username argument."
            TARGET_USER="$2"
            shift 2
            ;;
        -H|--hostname)
            [[ -z "${2:-}" || "${2:-}" == --* ]] && log_fatal "Option '$1' requires a hostname argument."
            TARGET_HOSTNAME="$2"
            shift 2
            ;;
        -n|--nopasswd|--passwordless-sudo)
            NOPASSWD_SUDO="true"
            shift
            ;;
        --prompt-password)
            PROMPT_PASSWORD="true"
            shift
            ;;
        --debloat-only)
            DEBLOAT_ONLY="true"
            KEEP_GUI="false"
            shift
            ;;
        --keep-gui)
            KEEP_GUI="true"
            shift
            ;;
        --skip-locale)
            FIX_LOCALE="false"
            shift
            ;;
        --no-apt-update|--skip-apt-update)
            export RVDK_NO_APT_UPDATE="1"
            shift
            ;;
        --noprogbar|--no-progbar)
            export RVDK_NO_PROGBAR="1"
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
    log_fatal "--nopasswd requires --user <username> to be specified."
fi
if [[ -n "$TARGET_USER" ]] && ! rvdk_validate_username "$TARGET_USER"; then
    log_fatal "Invalid POSIX username format: '${TARGET_USER}' (expected lowercase [a-z_][a-z0-9_-]{0,31})."
fi
if [[ -n "$TARGET_HOSTNAME" ]] && ! rvdk_validate_hostname "$TARGET_HOSTNAME"; then
    log_fatal "Invalid RFC-1123 hostname: '${TARGET_HOSTNAME}'."
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && command -v sudo >/dev/null 2>&1; then
        log_info "Escalating privileges via sudo..."
        exec sudo -E bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    else
        log_fatal "This script must be run as root."
    fi
fi

rvdk_sanitize_locale
rvdk_resolve_caller

# Auto-detect APT distro flavor if set to auto
if [[ "$DISTRO_FLAVOR" == "auto" ]]; then
    if [[ -r /etc/os-release ]]; then
        _os_id="$(awk -F= '/^ID=/ {gsub(/["'\'']/, "", $2); print tolower($2)}' /etc/os-release)"
        case "$_os_id" in
            bianbu) DISTRO_FLAVOR="bianbu" ;;
            ubuntu) DISTRO_FLAVOR="ubuntu" ;;
            *)      DISTRO_FLAVOR="debian" ;;
        esac
    else
        DISTRO_FLAVOR="debian"
    fi
fi

case "$DISTRO_FLAVOR" in
    debian|ubuntu|bianbu) ;;
    *) log_fatal "Unsupported --distro '${DISTRO_FLAVOR}' (expected debian, ubuntu, bianbu, or auto)." ;;
esac

_DISTRO_TITLE="$(printf '%s' "${DISTRO_FLAVOR:0:1}" | tr '[:lower:]' '[:upper:]')${DISTRO_FLAVOR:1}"
rvdk_prog_init "${_DISTRO_TITLE} Day-0 OS normalization..."

# Helper: headless target, snapd & distro GUI debloat
run_headless_debloat() {
    [[ "$KEEP_GUI" == "true" ]] && return 0

    rvdk_prog 55 "Enforcing headless target & purging desktop bloat (${DISTRO_FLAVOR})..."
    log_info "Enforcing headless ${_DISTRO_TITLE} server configuration..."

    if command -v systemctl >/dev/null 2>&1; then
        if [[ "$(systemctl get-default 2>/dev/null || true)" != "multi-user.target" ]]; then
            systemctl set-default multi-user.target
            systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
            systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
            systemctl stop gdm3 lightdm sddm 2>/dev/null || true
            log_ok "Boot target locked to headless multi-user.target"
        else
            log_skip "Boot target is already multi-user.target"
        fi
    fi

    if [[ "$DISTRO_FLAVOR" == "ubuntu" || "$DISTRO_FLAVOR" == "bianbu" ]]; then
        if command -v snap >/dev/null 2>&1 || dpkg-query -W -f='${Status}\n' snapd 2>/dev/null | grep -qx "install ok installed"; then
            rvdk_prog 64 "Purging snapd & snap mounts..."
            if command -v snap >/dev/null 2>&1; then
                local s
                for s in firefox snap-store gnome-42-2204 gtk-common-themes core22 bare snapd; do
                    snap remove --purge "$s" 2>/dev/null || true
                done
            fi
            systemctl stop snapd.socket snapd.service 2>/dev/null || true
            apt-get purge "${APT_FLAGS[@]}" snapd 2>/dev/null || true
            rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd /root/snap /home/*/snap
            log_ok "Purged snapd and snap mounts"
        else
            log_skip "snapd already purged"
        fi

        local nosnap_pref="/etc/apt/preferences.d/nosnap.pref"
        if [[ ! -f "$nosnap_pref" ]]; then
            cat << 'EOF' > "$nosnap_pref"
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
            log_ok "Pinned snapd to Priority -10 in ${nosnap_pref}"
        else
            log_skip "APT nosnap preference pin already present"
        fi
    fi

    local gui_bloat=()
    case "$DISTRO_FLAVOR" in
        bianbu)
            gui_bloat=(
                bianbu-desktop bianbu-desktop-minimal bianbu-desktop-en bianbu-desktop-zh
                ubuntu-desktop ubuntu-desktop-minimal gnome-shell gdm3 lightdm xwayland
                chromium-browser firefox apport whoopsie unattended-upgrades packagekit modemmanager
            )
            ;;
        ubuntu)
            gui_bloat=(
                ubuntu-desktop ubuntu-desktop-minimal gnome-shell gdm3 xwayland
                apport whoopsie unattended-upgrades packagekit modemmanager
            )
            ;;
        debian)
            gui_bloat=(
                task-desktop task-gnome-desktop task-xfce-desktop task-wayland-desktop
                gnome-shell gdm3 lightdm xwayland packagekit modemmanager unattended-upgrades
            )
            ;;
    esac

    local purge_list=() pkg
    for pkg in "${gui_bloat[@]}"; do
        if dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -qx "install ok installed"; then
            purge_list+=("$pkg")
        fi
    done

    if [[ ${#purge_list[@]} -gt 0 ]]; then
        rvdk_prog 74 "Purging ${_DISTRO_TITLE} desktop GUI packages..."
        apt-get purge "${APT_FLAGS[@]}" "${purge_list[@]}"
        apt-get autoremove "${APT_FLAGS[@]}" --purge
        apt-get clean
        log_ok "Purged ${_DISTRO_TITLE} GUI & background daemon bloat: ${purge_list[*]}"
    else
        log_skip "${_DISTRO_TITLE} desktop GUI & background bloat already absent"
    fi
}

if [[ "$DEBLOAT_ONLY" == "true" ]]; then
    run_headless_debloat
    rvdk_prog 100 "${_DISTRO_TITLE} headless debloat complete"
    log_info "Day-0 ${_DISTRO_TITLE} --debloat-only complete."
    exit 0
fi

# ==============================================================================
# 0. SUDO & UTF-8 LOCALE HYGIENE
# ==============================================================================
rvdk_prog 5 "Verifying sudo & UTF-8 locale..."
if ! command -v sudo >/dev/null 2>&1; then
    log_info "Installing missing 'sudo' package..."
    rvdk_apt_ensure sudo
    log_ok "Installed 'sudo'"
fi

if [[ "$FIX_LOCALE" == "true" ]]; then
    if { locale -a 2>/dev/null || true; } | grep -qiE '^en_US\.utf-?8$'; then
        export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
        log_skip "Locale en_US.UTF-8 is already generated"
    else
        log_info "Generating en_US.UTF-8 locale..."
        rvdk_apt_ensure locales
        if [[ -f /etc/locale.gen ]]; then
            sed -i 's/^# *en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
        fi
        locale-gen en_US.UTF-8
        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true
        export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
        log_ok "Configured en_US.UTF-8 locale"
    fi
fi

# ==============================================================================
# 1. NON-INTERACTIVE USER, SSH KEYS, GROUPS & NOPASSWD SUDO PROVISIONING
# ==============================================================================
rvdk_prog 20 "Converging user & sudoers (${TARGET_USER:-skip})..."
if [[ -n "$TARGET_USER" ]]; then
    log_info "Processing user configuration for '${TARGET_USER}'..."

    if id -u "$TARGET_USER" >/dev/null 2>&1; then
        log_skip "User '${TARGET_USER}' already exists"
    else
        log_info "Creating headless operator user '${TARGET_USER}'..."
        useradd -m -s /bin/bash "$TARGET_USER"
        if [[ "$PROMPT_PASSWORD" == "true" && -r /dev/tty ]]; then
            passwd "$TARGET_USER" < /dev/tty
        else
            passwd -l "$TARGET_USER" >/dev/null 2>&1 || true
        fi
        log_ok "Created user '${TARGET_USER}'"
    fi

    # Inherit SSH authorized_keys from invoking sudo user or root if target has none
    TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || echo "/home/${TARGET_USER}")"
    TARGET_GRP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
    if [[ -d "$TARGET_HOME" && ! -s "${TARGET_HOME}/.ssh/authorized_keys" ]]; then
        SRC_AUTH_KEYS=""
        if [[ -n "${REAL_HOME:-}" && -s "${REAL_HOME}/.ssh/authorized_keys" ]]; then
            SRC_AUTH_KEYS="${REAL_HOME}/.ssh/authorized_keys"
        elif [[ -s /root/.ssh/authorized_keys ]]; then
            SRC_AUTH_KEYS="/root/.ssh/authorized_keys"
        fi
        if [[ -n "$SRC_AUTH_KEYS" ]]; then
            install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_GRP" "${TARGET_HOME}/.ssh"
            install -m 0600 -o "$TARGET_USER" -g "$TARGET_GRP" "$SRC_AUTH_KEYS" "${TARGET_HOME}/.ssh/authorized_keys"
            log_ok "Seeded ${TARGET_HOME}/.ssh/authorized_keys from ${SRC_AUTH_KEYS}"
        fi
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
        printf '%s\n' "$SUDOERS_RULE" > "$TMP_SUDO"
        chmod 0440 "$TMP_SUDO"

        if visudo -cf "$TMP_SUDO" >/dev/null 2>&1; then
            mv -f "$TMP_SUDO" "$SUDOERS_FILE"
            chown root:root "$SUDOERS_FILE"
            chmod 0440 "$SUDOERS_FILE"
            log_ok "Configured passwordless sudo in ${SUDOERS_FILE}"
        else
            rm -f "$TMP_SUDO"
            log_fatal "Generated sudoers rule failed visudo syntax validation!"
        fi
    fi
fi

# ==============================================================================
# 2. HOSTNAME CONFIGURATION (RFC-1123 + AWK-SAFE /etc/hosts CONVERGENCE)
# ==============================================================================
rvdk_prog 40 "Configuring system hostname (${TARGET_HOSTNAME:-current})..."
if [[ -n "$TARGET_HOSTNAME" ]]; then
    CURRENT_HOSTNAME="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo localhost)"

    if [[ "$CURRENT_HOSTNAME" == "$TARGET_HOSTNAME" ]]; then
        log_skip "System hostname is already '${TARGET_HOSTNAME}'"
    else
        if command -v hostnamectl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
            hostnamectl set-hostname "$TARGET_HOSTNAME"
        else
            printf '%s\n' "$TARGET_HOSTNAME" > /etc/hostname
            hostname "$TARGET_HOSTNAME" 2>/dev/null || true
        fi
        log_ok "Updated system hostname: '${CURRENT_HOSTNAME}' -> '${TARGET_HOSTNAME}'"
    fi

    if awk -v h="$TARGET_HOSTNAME" '!/^[[:space:]]*#/ { for (i=2; i<=NF; i++) if ($i == h) found=1 } END { exit !found }' /etc/hosts 2>/dev/null; then
        log_skip "'${TARGET_HOSTNAME}' is already mapped in /etc/hosts"
    else
        TMP_HOSTS="$(mktemp /etc/hosts.rvdk.XXXXXX)"
        awk -v old="$CURRENT_HOSTNAME" -v new="$TARGET_HOSTNAME" '
            BEGIN { updated = 0 }
            /^[[:space:]]*#/ { print; next }
            $1 == "127.0.1.1" {
                printf "127.0.1.1\t%s\n", new
                updated = 1
                next
            }
            old != "" && old != "localhost" {
                changed = 0
                for (i = 2; i <= NF; i++) {
                    if ($i == old) { $i = new; changed = 1; updated = 1 }
                }
                if (changed) { print; next }
            }
            { print }
            END {
                if (!updated) {
                    printf "127.0.1.1\t%s\n", new
                }
            }
        ' /etc/hosts > "$TMP_HOSTS"
        chmod 0644 "$TMP_HOSTS"
        mv -f "$TMP_HOSTS" /etc/hosts
        log_ok "Converged /etc/hosts mapping for '${TARGET_HOSTNAME}'"
    fi
fi

# ==============================================================================
# 3. HEADLESS TARGET, SNAPD ERADICATION & DESKTOP GUI PURGE
# ==============================================================================
run_headless_debloat

# ==============================================================================
# 4. CVE-2026-98432 KERNEL IPv4 TCP RCU USE-AFTER-FREE MITIGATION
#    Ordered After=nftables.service + nftables ExecStartPost hook so `flush ruleset`
#    in /etc/nftables.conf cannot wipe `table ip cve_2026_98432`.
# ==============================================================================
rvdk_prog 85 "Converging CVE-2026-98432 nftables & MPTCP guard..."
SYSCTL_CVE_FILE="/etc/sysctl.d/99-cve-2026-98432-tcp.conf"
NFT_CVE_FILE="/etc/nftables.d/10-cve-2026-98432.nft"
LEGACY_NFT_CVE_FILE="/etc/nftables.d/cve-2026-98432.nft"
UNIT_CVE_FILE="/etc/systemd/system/cve-2026-98432-guard.service"
NFT_DROPIN_DIR="/etc/systemd/system/nftables.service.d"
NFT_DROPIN_FILE="${NFT_DROPIN_DIR}/90-rvdk-cve-2026-98432.conf"

WANT_SYSCTL_CVE="-net.mptcp.enabled = 0
-net.ipv4.tcp_migrate_req = 0"

WANT_NFT_CVE="add table ip cve_2026_98432
flush table ip cve_2026_98432
add chain ip cve_2026_98432 pre { type filter hook prerouting priority -300; policy accept; }
add rule ip cve_2026_98432 pre meta l4proto tcp ip hdrlength gt 5 counter drop"

WANT_UNIT_CVE="[Unit]
Description=CVE-2026-98432 IPv4 TCP Options Raw Prerouting Drop Guard
DefaultDependencies=no
After=nftables.service
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f ${NFT_CVE_FILE}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"

WANT_NFT_DROPIN="[Service]
ExecStartPost=-/usr/sbin/nft -f ${NFT_CVE_FILE}"

CVE_CHANGED="false"
if ! printf '%s\n' "$WANT_SYSCTL_CVE" | cmp -s - "$SYSCTL_CVE_FILE" 2>/dev/null; then
    printf '%s\n' "$WANT_SYSCTL_CVE" > "$SYSCTL_CVE_FILE"
    sysctl --system >/dev/null
    CVE_CHANGED="true"
fi

if ! command -v nft >/dev/null 2>&1; then
    rvdk_apt_ensure nftables
fi

mkdir -p /etc/nftables.d "$NFT_DROPIN_DIR"
rm -f "$LEGACY_NFT_CVE_FILE"

if ! printf '%s\n' "$WANT_NFT_CVE" | cmp -s - "$NFT_CVE_FILE" 2>/dev/null; then
    printf '%s\n' "$WANT_NFT_CVE" > "$NFT_CVE_FILE"
    chmod 0644 "$NFT_CVE_FILE"
    CVE_CHANGED="true"
fi

if ! printf '%s\n' "$WANT_UNIT_CVE" | cmp -s - "$UNIT_CVE_FILE" 2>/dev/null; then
    printf '%s\n' "$WANT_UNIT_CVE" > "$UNIT_CVE_FILE"
    chmod 0644 "$UNIT_CVE_FILE"
    CVE_CHANGED="true"
fi

if ! printf '%s\n' "$WANT_NFT_DROPIN" | cmp -s - "$NFT_DROPIN_FILE" 2>/dev/null; then
    printf '%s\n' "$WANT_NFT_DROPIN" > "$NFT_DROPIN_FILE"
    chmod 0644 "$NFT_DROPIN_FILE"
    CVE_CHANGED="true"
fi

if [[ "$CVE_CHANGED" == "true" ]] \
   || ! systemctl is-active --quiet cve-2026-98432-guard.service 2>/dev/null \
   || ! nft list table ip cve_2026_98432 >/dev/null 2>&1; then
    nft -f "$NFT_CVE_FILE"
    systemctl daemon-reload
    systemctl enable --now cve-2026-98432-guard.service >/dev/null
    log_ok "Configured persistent CVE-2026-98432 raw prerouting guard and MPTCP lockdown"
else
    log_skip "CVE-2026-98432 TCP option filter & MPTCP lockdown already converged"
fi

rvdk_prog 100 "${_DISTRO_TITLE} Day-0 OS normalization complete"
log_info "Day-0 ${_DISTRO_TITLE} bootstrap complete."
