#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK CLI & Engine Installer
# Path: riscv-data-kit/install-cli.sh
# Description: Stages the riscv-data-kit engine and caches strictly in system
#              space (/usr/local/share/rvdk/engine, /etc/rvdk, /var/cache/rvdk)
#              with zero ~/.rvdk user-home footprint, and links /usr/bin/rvdk +
#              /usr/local/bin/rvdk without modifying OS/BSP state.
#
# Usage:
#   curl -fsSL https://rvdk.drewv-labs.dev/install-cli.sh | sudo bash
#   curl -fsSL https://rvdk.drewv-labs.dev/install-cli.sh | sudo zsh
# ==============================================================================

# Ensure compatibility when invoked via `zsh` or `bash` (including `curl ... | sudo zsh`)
if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L ksh
    setopt PIPE_FAIL ERR_RETURN NO_UNSET
else
    set -Eeuo pipefail
fi

if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_SELF="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" && "${0:-}" != "zsh" && "${0:-}" != "-zsh" && -f "${0:-}" ]]; then
    SCRIPT_SELF="$0"
else
    SCRIPT_SELF=""
fi
if [[ $EUID -ne 0 ]]; then
    if [[ -n "$SCRIPT_SELF" && -f "$SCRIPT_SELF" ]] && command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$SCRIPT_SELF" "$@"
    else
        echo "[RVDK:FATAL] Pipe into 'sudo bash' or 'sudo zsh': curl -fsSL https://rvdk.drewv-labs.dev/install-cli.sh | sudo bash" >&2
        exit 1
    fi
fi

# Enforce 022 umask so system directories and cloned scripts remain 0755/0644
# even on hardened root environments with umask 077/027.
umask 022

# Sanitize SSH-forwarded LC_* environment variables before target locales exist
if { locale -a 2>/dev/null || true; } | grep -qiE '^en_US\.utf-?8$'; then
    export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
elif { locale -a 2>/dev/null || true; } | grep -qiE '^C\.utf-?8$'; then
    export LANG="C.UTF-8" LC_ALL="C.UTF-8"
else
    export LANG="C" LC_ALL="C"
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo root)}"
if [[ ! "$REAL_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    REAL_USER="root"
fi

REAL_HOME=""
if command -v getent >/dev/null 2>&1; then
    REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || true)"
elif command -v dscl >/dev/null 2>&1; then
    REAL_HOME="$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
fi
if [[ -z "$REAL_HOME" ]]; then
    if [[ "$REAL_USER" == "root" ]]; then
        REAL_HOME="/root"
    elif [[ -d "/Users/${REAL_USER}" ]]; then
        REAL_HOME="/Users/${REAL_USER}"
    elif [[ -d "/home/${REAL_USER}" ]]; then
        REAL_HOME="/home/${REAL_USER}"
    else
        REAL_HOME="/root"
    fi
fi

LEGACY_HOME_RVDK="${REAL_HOME}/.rvdk"
SYS_ETC_DIR="/etc/rvdk"
CACHE_DIR="${RVDK_CACHE_DIR:-/var/cache/rvdk}"
ENGINE_DIR="${RVDK_ENGINE_DIR:-/usr/local/share/rvdk/engine}"
ENGINE_PARENT="$(dirname "$ENGINE_DIR")"
REPO_URL="${RVDK_REPO_URL:-https://github.com/drewv-labs/riscv-data-kit.git}"
REPO_BRANCH="${RVDK_BRANCH:-main}"
QUIET_MODE="false"

for arg in "$@"; do
    case "$arg" in
        -q|--quiet) QUIET_MODE="true" ;;
    esac
done

log_info()  { printf "\033[1;36m[RVDK:CLI]\033[0m %s\n" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

if [[ ! "$REPO_BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
    log_fatal "Invalid RVDK_BRANCH name: '${REPO_BRANCH}'."
fi

# 1. Ensure bash, git (+ HTTPS transport), and curl are installed across Debian/Ubuntu/Bianbu & OpenWrt
NEED_GIT_HTTP="false"
if [[ -f /etc/openwrt_release ]] && command -v git >/dev/null 2>&1 && [[ ! -x /usr/lib/git-core/git-remote-https ]]; then
    NEED_GIT_HTTP="true"
fi

if ! command -v bash >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || [[ "$NEED_GIT_HTTP" == "true" ]]; then
    if command -v apt-get >/dev/null 2>&1; then
        log_info "Installing bash, git, and curl prerequisites (APT)..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o DPkg::Lock::Timeout=120 update -q || true
        apt-get -o DPkg::Lock::Timeout=120 install -y bash git ca-certificates curl
    elif command -v opkg >/dev/null 2>&1; then
        log_info "Installing bash, git-http, and curl prerequisites (OpenWrt opkg)..."
        opkg update
        opkg install bash git git-http curl ca-bundle
    elif command -v apk >/dev/null 2>&1; then
        log_info "Installing bash, git, and curl prerequisites (OpenWrt/Alpine apk)..."
        apk add --no-cache bash git curl ca-certificates
    else
        log_fatal "Missing git or curl. On macOS, run 'xcode-select --install' or 'brew install git curl'."
    fi
fi

# 2. Stage system-space directories (/etc/rvdk, /var/cache/rvdk, /usr/local/share/rvdk/engine)
mkdir -p "$SYS_ETC_DIR" "$CACHE_DIR" "$ENGINE_PARENT"
chmod 0755 "$SYS_ETC_DIR" /usr/local /usr/local/share "$ENGINE_PARENT" 2>/dev/null || true
if [[ "$(uname -s)" == "Darwin" ]]; then
    chown 0:admin "$CACHE_DIR" 2>/dev/null || chown 0:0 "$CACHE_DIR" 2>/dev/null || true
    chmod 1775 "$CACHE_DIR" 2>/dev/null || chmod 0755 "$CACHE_DIR" 2>/dev/null || true
else
    chown 0:0 "$CACHE_DIR" 2>/dev/null || true
    chmod 0755 "$CACHE_DIR" 2>/dev/null || true
fi

if [[ -d "${ENGINE_DIR}/.git" ]]; then
    log_info "Updating RVDK engine in ${ENGINE_DIR} (${REPO_BRANCH})..."
    chown -R 0:0 "$ENGINE_DIR" 2>/dev/null || true
    git -C "$ENGINE_DIR" fetch origin "$REPO_BRANCH" -q
    git -C "$ENGINE_DIR" reset --hard "origin/${REPO_BRANCH}" -q
else
    log_info "Cloning ${REPO_URL} into ${ENGINE_DIR}..."
    rm -rf "$ENGINE_DIR"
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$ENGINE_DIR" -q
fi

chown -R 0:0 "$ENGINE_DIR" 2>/dev/null || true
chmod -R a+rX "$ENGINE_DIR" 2>/dev/null || true
chmod 0755 "$ENGINE_DIR"
chmod +x \
    "${ENGINE_DIR}/bootstrap.sh" \
    "${ENGINE_DIR}/install-cli.sh" \
    "${ENGINE_DIR}"/lib/*.sh \
    "${ENGINE_DIR}"/os/*.sh \
    "${ENGINE_DIR}"/bsp/*/*/*.sh \
    "${ENGINE_DIR}"/boards/*/*/*.sh \
    "${ENGINE_DIR}"/boards/*/*/quirks/*.sh \
    "${ENGINE_DIR}"/postgresql/*/forge.sh \
    "${ENGINE_DIR}"/mods/*/forge.sh \
    "${ENGINE_DIR}"/utils/*.sh 2>/dev/null || true

# Promote & retire any legacy ~/.rvdk user-home directory into system space
if [[ -d "$LEGACY_HOME_RVDK" && "$ENGINE_DIR" != "${LEGACY_HOME_RVDK}/engine" ]]; then
    if [[ -f "${LEGACY_HOME_RVDK}/config.env" ]]; then
        if [[ ! -f "${SYS_ETC_DIR}/config.env" ]]; then
            cp -a "${LEGACY_HOME_RVDK}/config.env" "${SYS_ETC_DIR}/config.env"
            chown 0:0 "${SYS_ETC_DIR}/config.env" 2>/dev/null || true
            chmod 0640 "${SYS_ETC_DIR}/config.env" 2>/dev/null || true
        fi
        rm -f "${LEGACY_HOME_RVDK}/config.env" 2>/dev/null || true
    fi
    if [[ -d "${LEGACY_HOME_RVDK}/cache" ]]; then
        for _citem in "${LEGACY_HOME_RVDK}/cache/"*; do
            [[ -e "$_citem" ]] || continue
            _cbase="$(basename "$_citem")"
            [[ -e "${CACHE_DIR}/${_cbase}" ]] || mv -f "$_citem" "${CACHE_DIR}/${_cbase}" 2>/dev/null || true
        done
        rm -rf "${LEGACY_HOME_RVDK}/cache" 2>/dev/null || true
    fi
    rm -rf "${LEGACY_HOME_RVDK}/engine" 2>/dev/null || true
    rmdir "$LEGACY_HOME_RVDK" 2>/dev/null || true
fi

# Persist /etc/rvdk/kit.env cache on Linux target nodes right away if recognized
if [[ "$(uname -s)" == "Linux" && -f "${ENGINE_DIR}/lib/kit.sh" ]]; then
    # shellcheck source=lib/kit.sh
    source "${ENGINE_DIR}/lib/kit.sh"
    rvdk_kit_resolve --refresh || true
fi

# 3. Link /usr/local/bin/rvdk AND (on Linux) /usr/bin/rvdk so classic sudo,
#    Debian forky/sid sudo-rs, doas, OpenWrt, and root/user shells always resolve `rvdk`.
mkdir -p /usr/local/bin
chmod 0755 /usr/local /usr/local/bin 2>/dev/null || true
ln -sf "${ENGINE_DIR}/bootstrap.sh" /usr/local/bin/rvdk
LINKED_PATHS="/usr/local/bin/rvdk"
if [[ "$(uname -s)" == "Linux" && -d /usr/bin ]]; then
    if ln -sf "${ENGINE_DIR}/bootstrap.sh" /usr/bin/rvdk 2>/dev/null; then
        LINKED_PATHS="/usr/bin/rvdk & /usr/local/bin/rvdk"
    fi
fi
COMMIT_SHA="$(git -C "$ENGINE_DIR" rev-parse --short HEAD 2>/dev/null || echo "main")"
log_ok "Linked ${LINKED_PATHS} -> ${ENGINE_DIR}/bootstrap.sh (${COMMIT_SHA})"

if [[ "$QUIET_MODE" == "false" ]]; then
    DT_MODEL="${RVDK_DT_MODEL:-Unknown}"
    if [[ "$DT_MODEL" == "Unknown" ]]; then
        if [[ -r /proc/device-tree/model ]]; then
            DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
        elif [[ "$(uname -s)" == "Darwin" ]]; then
            DT_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m) (macOS Host)"
        fi
    fi

    OS_PRETTY="Unknown"
    if [[ -r /etc/os-release ]]; then
        OS_PRETTY="$(awk -F= '/^PRETTY_NAME=/ {sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit}' /etc/os-release 2>/dev/null || echo "Unknown")"
    elif [[ -r /etc/openwrt_release ]]; then
        OS_PRETTY="$(awk -F= '/^DISTRIB_DESCRIPTION=/ {sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit}' /etc/openwrt_release 2>/dev/null || echo "OpenWrt")"
    elif command -v sw_vers >/dev/null 2>&1; then
        OS_PRETTY="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) ($(uname -m))"
    fi

    cat <<EOF

======================================================================
 DREW-V Labs // RVDK CLI Installed (${COMMIT_SHA})
   Board : ${DT_MODEL}
   OS    : ${OS_PRETTY}
   Root  : ${ENGINE_DIR}

 Usage:
   sudo rvdk                      # Run full Day-0 (OS + Silicon BSP) bootstrap
   rvdk kit                       # Inspect resolved Board/SoC/OS Kit cache
   sudo rvdk deeptune             # Multi-layer DeepTune (--tune data|ai)
   sudo rvdk storage [status|...] # Live LVM elastic manager (grow, shrink, autotune)
   sudo rvdk quirk <name|list>    # Toggle board quirks (e.g. hdmi, fusb)
   rvdk flash <board> <medium>    # Flash board media (e.g. rvdk flash p550 usb 4)
   sudo rvdk bsp                  # Run Silicon BSP hardening only
   sudo rvdk os                   # Run OS normalization & CVE guard only
   sudo rvdk postgresql           # Install PostgreSQL 18.6 (cache or --force-build)
   sudo rvdk mods/nvme-4kn        # Format 4Kn NVMe + LVM vg_rvdk + XFS/Btrfs
   sudo rvdk mods/btrfs-raid
   sudo rvdk mods/mosquitto
   sudo rvdk mods/nfs-vault
   sudo rvdk mods/tailscale       # Install static riscv64 Tailscale VPN [--ssh|--up]
   sudo rvdk utils/purge-user.sh  # Migrate state & purge factory default user
   sudo rvdk update               # Pull latest RVDK engine from GitHub
======================================================================
EOF
fi
