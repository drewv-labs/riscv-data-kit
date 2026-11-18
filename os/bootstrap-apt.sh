#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Unified Day-0 APT Headless OS Bootstrap (Debian / Ubuntu / Bianbu)
# Path: riscv-data-kit/os/bootstrap-apt.sh
#
# Description:
#   Idempotent Day-0 OS normalization across Debian, Ubuntu, and SpacemiT Bianbu
#   RISC-V nodes:
#     • Canonical US-first signed HTTPS APT mirror normalization (`deb.debian.org`,
#       `security.debian.org`, `ports.ubuntu.com`, `armbian.chi.auroradev.org`)
#       plus vendor CN PyPI/npm/cargo/goproxy/DNS touch-plane hygiene
#     • Cold-RTC clock skew recovery, US-first persistent NTP (`systemd-timesyncd`
#       / `chrony`), UTF-8 locale hygiene & non-interactive `sudo` availability
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
    rvdk_sync_cold_clock() { :; }
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
      --keep-mirrors          Preserve existing APT/NTP/registry mirror configs
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
        --keep-mirrors)
            export RVDK_KEEP_VENDOR_MIRRORS="1"
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
rvdk_sync_cold_clock

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

# Helper: US-first DNS & developer/container registry CN touch-plane hygiene
converge_us_touch_plane() {
    if [[ "${RVDK_KEEP_VENDOR_MIRRORS:-0}" == "1" || "${RVDK_KEEP_VENDOR_MIRRORS:-false}" == "true" ]]; then
        return 0
    fi

    # 1. Converge US-anycast DNS surface (1.1.1.1, 8.8.8.8, 1.0.0.1):
    #    - Scrubs hardcoded mainland CN public DNS resolvers
    #    - Expands single-homing static vendor public resolv.conf (e.g. sole 1.0.0.1)
    #      to multi-AS Cloudflare + Google diversity (glibc MAXNS=3) while preserving
    #      local LAN/DHCP/split-horizon/Tailscale resolvers untouched
    local cn_dns_re='(114\.114\.114\.114|114\.114\.115\.115|223\.5\.5\.5|223\.6\.6\.6|119\.29\.29\.29|182\.254\.116\.116|180\.76\.76\.76|1\.2\.4\.8|210\.2\.4\.8)'
    local dns_changed="false" dns_f tmp_dns
    if [[ ! -L /etc/resolv.conf && -f /etc/resolv.conf ]]; then
        local has_cn_dns="false" static_pub_only="false"
        if grep -Eq "^[[:space:]]*nameserver[[:space:]]+${cn_dns_re}([[:space:]]|$)" /etc/resolv.conf 2>/dev/null; then
            has_cn_dns="true"
        elif ! grep -Eqi 'Generated by|resolvconf|tailscale|systemd-resolved' /etc/resolv.conf 2>/dev/null; then
            if awk '
                /^[[:space:]]*nameserver[[:space:]]+/ {
                    ns_cnt++
                    if ($2 !~ /^(1\.1\.1\.1|1\.0\.0\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9)$/) non_pub=1
                }
                END { exit !(ns_cnt > 0 && !non_pub) }
            ' /etc/resolv.conf 2>/dev/null; then
                static_pub_only="true"
            fi
        fi

        if [[ "$has_cn_dns" == "true" ]]; then
            tmp_dns="$(mktemp)"
            awk -v re="$cn_dns_re" '
                BEGIN {
                    us[1] = "1.1.1.1"; us[2] = "8.8.8.8"; us[3] = "1.0.0.1"
                }
                /^[[:space:]]*nameserver[[:space:]]+/ {
                    ip = $2
                    if (ip ~ ("^" re "$")) {
                        had_cn = 1
                        next
                    }
                    if (!seen[ip]++ && kept < 3) {
                        lines[++n] = $0
                        kept++
                    }
                    next
                }
                { lines[++n] = $0 }
                END {
                    for (i = 1; i <= n; i++) print lines[i]
                    if (had_cn) {
                        for (j = 1; j <= 3 && kept < 3; j++) {
                            if (!seen[us[j]]++) {
                                print "nameserver " us[j]
                                kept++
                            }
                        }
                    }
                }
            ' /etc/resolv.conf > "$tmp_dns"
            if ! cmp -s "$tmp_dns" /etc/resolv.conf 2>/dev/null; then
                mkdir -p /var/lib/rvdk/backups/dns
                [[ -f /var/lib/rvdk/backups/dns/resolv.conf.orig ]] || cp -a /etc/resolv.conf /var/lib/rvdk/backups/dns/resolv.conf.orig 2>/dev/null || true
                chmod 0644 "$tmp_dns"
                mv -f "$tmp_dns" /etc/resolv.conf
                dns_changed="true"
            else
                rm -f "$tmp_dns"
            fi
        elif [[ "$static_pub_only" == "true" ]]; then
            tmp_dns="$(mktemp)"
            awk '
                /^[[:space:]]*nameserver[[:space:]]+/ { next }
                { print }
                END {
                    print "nameserver 1.1.1.1"
                    print "nameserver 8.8.8.8"
                    print "nameserver 1.0.0.1"
                }
            ' /etc/resolv.conf > "$tmp_dns"
            if ! cmp -s "$tmp_dns" /etc/resolv.conf 2>/dev/null; then
                mkdir -p /var/lib/rvdk/backups/dns
                [[ -f /var/lib/rvdk/backups/dns/resolv.conf.orig ]] || cp -a /etc/resolv.conf /var/lib/rvdk/backups/dns/resolv.conf.orig 2>/dev/null || true
                chmod 0644 "$tmp_dns"
                mv -f "$tmp_dns" /etc/resolv.conf
                dns_changed="true"
            else
                rm -f "$tmp_dns"
            fi
        fi
    fi

    local resolved_reload="false"
    for dns_f in /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d/*.conf; do
        [[ -f "$dns_f" ]] || continue
        [[ "$dns_f" == "/etc/systemd/resolved.conf.d/10-rvdk-dns.conf" ]] && continue
        if grep -Eq "^[[:space:]]*(Fallback)?DNS=.*${cn_dns_re}" "$dns_f" 2>/dev/null; then
            mkdir -p /var/lib/rvdk/backups/dns
            cp -a "$dns_f" "/var/lib/rvdk/backups/dns/$(basename "$dns_f").orig" 2>/dev/null || true
            tmp_dns="$(mktemp)"
            sed -E "/^[[:space:]]*#/! s@^([[:space:]]*(Fallback)?DNS=).*${cn_dns_re}.*@\11.1.1.1 8.8.8.8 1.0.0.1@" "$dns_f" > "$tmp_dns"
            chmod 0644 "$tmp_dns"
            mv -f "$tmp_dns" "$dns_f"
            resolved_reload="true"
            dns_changed="true"
        fi
    done

    if [[ -f /etc/systemd/resolved.conf || -x /lib/systemd/systemd-resolved || -x /usr/lib/systemd/systemd-resolved ]]; then
        local resolved_dropin_dir="/etc/systemd/resolved.conf.d"
        local resolved_dropin="${resolved_dropin_dir}/10-rvdk-dns.conf"
        local want_resolved_dropin="# Managed by RVDK (os/bootstrap-apt.sh)
[Resolve]
FallbackDNS=1.1.1.1 8.8.8.8 1.0.0.1"
        mkdir -p "$resolved_dropin_dir"
        if ! printf '%s
' "$want_resolved_dropin" | cmp -s - "$resolved_dropin" 2>/dev/null; then
            printf '%s
' "$want_resolved_dropin" > "$resolved_dropin"
            chmod 0644 "$resolved_dropin"
            resolved_reload="true"
            dns_changed="true"
        fi
    fi

    if [[ "$resolved_reload" == "true" ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet systemd-resolved.service 2>/dev/null && systemctl restart systemd-resolved.service 2>/dev/null || true
    fi
    [[ "$dns_changed" == "true" ]] && log_ok "Converged US-anycast DNS resolver surface (1.1.1.1, 8.8.8.8, 1.0.0.1)"

    # 2. Scrub factory CN PyPI / npm / Cargo / Go / HuggingFace mirror overrides
    local cn_reg_re='(pypi\.tuna\.tsinghua\.edu\.cn|mirrors\.(aliyun\.com|ustc\.edu\.cn|bfsu\.edu\.cn|cloud\.tencent\.com|zju\.edu\.cn|nju\.edu\.cn|sjtug\.sjtu\.edu\.cn|163\.com|sohu\.com)|repo\.huaweicloud\.com|pypi\.douban(io)?\.com|npmmirror\.com|registry\.npm\.taobao\.org|goproxy\.(cn|io)|rsproxy\.cn|hf-mirror\.com)'
    local reg_changed="false" rf tmp_rf bname
    local reg_candidates=(
        /etc/pip.conf
        /etc/xdg/pip/pip.conf
        /root/.pip/pip.conf
        /root/.config/pip/pip.conf
        /etc/skel/.pip/pip.conf
        /etc/skel/.config/pip.conf
        /etc/npmrc
        /root/.npmrc
        /etc/skel/.npmrc
        /root/.cargo/config
        /root/.cargo/config.toml
    )
    local hp
    for hp in /home/*/.pip/pip.conf /home/*/.config/pip/pip.conf /home/*/.npmrc; do
        [[ -f "$hp" ]] && reg_candidates+=("$hp")
    done

    for rf in "${reg_candidates[@]}"; do
        [[ -f "$rf" ]] || continue
        if grep -Eq "$cn_reg_re" "$rf" 2>/dev/null; then
            mkdir -p /var/lib/rvdk/backups/registries
            bname="$(printf '%s' "$rf" | sed 's|^/||; s|/|__|g')"
            [[ -f "/var/lib/rvdk/backups/registries/${bname}.orig" ]] || cp -a "$rf" "/var/lib/rvdk/backups/registries/${bname}.orig" 2>/dev/null || true
            tmp_rf="$(mktemp)"
            grep -Ev "$cn_reg_re" "$rf" > "$tmp_rf" || true
            if awk '!/^[[:space:]]*(#|$|\[.*\][[:space:]]*$)/ { active=1 } END { exit !active }' "$tmp_rf" 2>/dev/null; then
                chmod --reference="$rf" "$tmp_rf" 2>/dev/null || chmod 0644 "$tmp_rf"
                chown --reference="$rf" "$tmp_rf" 2>/dev/null || true
                mv -f "$tmp_rf" "$rf"
            else
                rm -f "$tmp_rf" "$rf"
            fi
            reg_changed="true"
        fi
    done

    local env_f
    for env_f in /etc/environment /etc/profile.d/*.sh; do
        [[ -f "$env_f" ]] || continue
        if grep -Eq "^[[:space:]]*(export[[:space:]]+)?(GOPROXY|RUSTUP_DIST_SERVER|RUSTUP_UPDATE_ROOT|PIP_INDEX_URL|UV_INDEX_URL|HF_ENDPOINT)=.*${cn_reg_re}" "$env_f" 2>/dev/null; then
            mkdir -p /var/lib/rvdk/backups/registries
            bname="$(printf '%s' "$env_f" | sed 's|^/||; s|/|__|g')"
            [[ -f "/var/lib/rvdk/backups/registries/${bname}.orig" ]] || cp -a "$env_f" "/var/lib/rvdk/backups/registries/${bname}.orig" 2>/dev/null || true
            tmp_rf="$(mktemp)"
            grep -Ev "^[[:space:]]*(export[[:space:]]+)?(GOPROXY|RUSTUP_DIST_SERVER|RUSTUP_UPDATE_ROOT|PIP_INDEX_URL|UV_INDEX_URL|HF_ENDPOINT)=.*${cn_reg_re}" "$env_f" > "$tmp_rf" || true
            chmod --reference="$env_f" "$tmp_rf" 2>/dev/null || chmod 0644 "$tmp_rf"
            mv -f "$tmp_rf" "$env_f"
            reg_changed="true"
        fi
    done
    [[ "$reg_changed" == "true" ]] && log_ok "Scrubbed factory CN developer registry overrides (restored upstream TLS registries)"
    return 0
}

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
    declare -F rvdk_apt_normalize_mirrors >/dev/null 2>&1 && rvdk_apt_normalize_mirrors --quiet-skip
    run_headless_debloat
    rvdk_prog 100 "${_DISTRO_TITLE} headless debloat complete"
    log_info "Day-0 ${_DISTRO_TITLE} --debloat-only complete."
    exit 0
fi

# ==============================================================================
# 0. US-FIRST SIGNED HTTPS APT MIRRORS, SUDO, PERSISTENT NTP & UTF-8 LOCALE
# ==============================================================================
rvdk_prog 5 "Normalizing US-first HTTPS mirrors, NTP & UTF-8 locale..."
if declare -F rvdk_apt_normalize_mirrors >/dev/null 2>&1; then
    rvdk_apt_normalize_mirrors
    if ! rvdk_apt_has_lists; then
        rvdk_apt_update
    fi
fi
converge_us_touch_plane

rvdk_prog 5 "Normalizing US-first HTTPS mirrors, NTP & UTF-8 locale..."
if declare -F rvdk_apt_normalize_mirrors >/dev/null 2>&1; then
    rvdk_apt_normalize_mirrors
    if ! rvdk_apt_has_lists; then
        rvdk_apt_update
    fi
fi
converge_us_touch_plane

if ! command -v sudo >/dev/null 2>&1; then
    log_info "Installing missing 'sudo' package..."
    rvdk_apt_ensure sudo
    log_ok "Installed 'sudo'"
fi

# Ensure batteryless RISC-V SBCs run persistent NTP pointedpointed atat US-firstUS-first poolspools
if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    TIMESYNCD_DROPIN_DIR="/etc/systemd/timesyncd.conf.d"
    TIMESYNCD_DROPIN_FILE="${TIMESYNCD_DROPIN_DIR}/10-rvdk-ntp.conf"
    WANT_TIMESYNCD_DROPIN="# Managed by RVDK (os/bootstrap-apt.sh)
[Time]
NTP=0.us.pool.ntp.org 1.us.pool.ntp.org 2.us.pool.ntp.org 3.us.pool.ntp.org
FallbackNTP=time.cloudflare.com time.nist.gov"

    NTP_CONF_CHANGED="false"
    if [[ "${RVDK_KEEP_VENDOR_MIRRORS:-0}" != "1" && "${RVDK_KEEP_VENDOR_MIRRORS:-false}" != "true" ]]; then
        mkdir -p "$TIMESYNCD_DROPIN_DIR"
        if ! printf '%s\n' "$WANT_TIMESYNCD_DROPIN" | cmp -s - "$TIMESYNCD_DROPIN_FILE" 2>/dev/null; then
            printf '%s\n' "$WANT_TIMESYNCD_DROPIN" > "$TIMESYNCD_DROPIN_FILE"
            chmod 0644 "$TIMESYNCD_DROPIN_FILE"
            NTP_CONF_CHANGED="true"
        fi

        for _chrony_cfg in /etc/chrony/chrony.conf /etc/chrony.conf; do
            [[ -f "$_chrony_cfg" ]] || continue
            if grep -Eq '^[[:space:]]*(pool|server)[[:space:]]+([^[:space:]]*\.cn\.pool\.ntp\.org|ntp[0-9]*\.aliyun\.com|ntp[0-9]*\.tencent\.com|time[0-9]*\.cloud\.tencent\.com|ntp\.ntsc\.ac\.cn|time\.ustc\.edu\.cn)' "$_chrony_cfg" 2>/dev/null; then
                mkdir -p /var/lib/rvdk/backups/ntp
                cp -a "$_chrony_cfg" "/var/lib/rvdk/backups/ntp/$(basename "$_chrony_cfg").orig" 2>/dev/null || true
                sed -i -E 's@^([[:space:]]*(pool|server)[[:space:]]+)([^[:space:]]*\.cn\.pool\.ntp\.org|ntp[0-9]*\.aliyun\.com|ntp[0-9]*\.tencent\.com|time[0-9]*\.cloud\.tencent\.com|ntp\.ntsc\.ac\.cn|time\.ustc\.edu\.cn)@pool us.pool.ntp.org@' "$_chrony_cfg" 2>/dev/null || true
                systemctl restart chrony.service 2>/dev/null || systemctl restart chronyd.service 2>/dev/null || true
                NTP_CONF_CHANGED="true"
            fi
        done
    fi

    _ACTIVE_NTP=""
    for _ntp_svc in systemd-timesyncd.service chrony.service chronyd.service ntpsec.service ntp.service ntpd.service; do
        if systemctl is-active --quiet "$_ntp_svc" 2>/dev/null; then
            _ACTIVE_NTP="$_ntp_svc"
            break
        fi
    done
    if [[ -n "$_ACTIVE_NTP" ]]; then
        if [[ "$NTP_CONF_CHANGED" == "true" && "$_ACTIVE_NTP" == "systemd-timesyncd.service" ]]; then
            systemctl restart systemd-timesyncd.service 2>/dev/null || true
            log_ok "Configured US-first NTP pools (${TIMESYNCD_DROPIN_FILE}) and reloaded systemd-timesyncd"
        elif [[ "$NTP_CONF_CHANGED" == "true" ]]; then
            log_ok "Configured US-first NTP pools (${_ACTIVE_NTP})"
        else
            log_skip "US-first NTP time synchronization already active (${_ACTIVE_NTP})"
        fi
        if [[ "$NTP_CONF_CHANGED" == "true" && "$_ACTIVE_NTP" == "systemd-timesyncd.service" ]]; then
            systemctl restart systemd-timesyncd.service 2>/dev/null || true
            log_ok "Configured US-first NTP pools (${TIMESYNCD_DROPIN_FILE}) and reloaded systemd-timesyncd"
        elif [[ "$NTP_CONF_CHANGED" == "true" ]]; then
            log_ok "Configured US-first NTP pools (${_ACTIVE_NTP})"
        else
            log_skip "US-first NTP time synchronization already active (${_ACTIVE_NTP})"
        fi
    else
        log_info "Enabling persistent US-first NTP synchronization (systemd-timesyncd)..."
        if [[ ! -x /lib/systemd/systemd-timesyncd && ! -x /usr/lib/systemd/systemd-timesyncd ]]; then
            rvdk_apt_ensure systemd-timesyncd
        fi
        systemctl unmask systemd-timesyncd.service >/dev/null 2>&1 || true
        systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1 || true
        command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp true >/dev/null 2>&1 || true
        log_ok "Enabled persistent US-first NTP synchronization (systemd-timesyncd.service)"
    fi

    # Refresh fake-hwclock / timesync floor so clean & unclean reboots never regress to factory image build dates
    if [[ -f /etc/fake-hwclock.data ]] || command -v fake-hwclock >/dev/null 2>&1; then
        if (( $(date -u +%s 2>/dev/null || echo 0) >= 1700000000 )); then
            date -u '+%Y-%m-%d %H:%M:%S' > /etc/fake-hwclock.data 2>/dev/null || true
        fi
    fi
    if [[ -d /var/lib/systemd/timesync ]] && (( $(date -u +%s 2>/dev/null || echo 0) >= 1700000000 )); then
        : > /var/lib/systemd/timesync/clock 2>/dev/null || true
    fi
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
