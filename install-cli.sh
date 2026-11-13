#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK CLI & Engine Installer
# Path: riscv-data-kit/install-cli.sh
# Description: Clones or updates the riscv-data-kit engine in ~/.rvdk/engine
#              and links /usr/local/bin/rvdk without modifying OS/BSP state.
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

SCRIPT_SELF="${BASH_SOURCE[0]:-}"
if [[ $EUID -ne 0 ]]; then
    if [[ -n "$SCRIPT_SELF" && -f "$SCRIPT_SELF" ]]; then
        exec sudo -E bash "$SCRIPT_SELF" "$@"
    else
        echo "[RVDK:FATAL] Pipe into 'sudo bash' or 'sudo zsh': curl -fsSL https://rvdk.drewv-labs.dev/install-cli.sh | sudo bash" >&2
        exit 1
    fi
fi

# Sanitize SSH-forwarded LC_* (e.g. ZedBook / macOS SendEnv) before en_US.UTF-8 exists on target
if { locale -a 2>/dev/null || true; } | grep -qiE '^en_US\.utf-?8$'; then
    export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
elif { locale -a 2>/dev/null || true; } | grep -qiE '^C\.utf-?8$'; then
    export LANG="C.UTF-8" LC_ALL="C.UTF-8"
else
    export LANG="C" LC_ALL="C"
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo root)}"
REAL_GRP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"

if command -v getent >/dev/null 2>&1; then
    REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || true)"
elif command -v dscl >/dev/null 2>&1; then
    REAL_HOME="$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
else
    REAL_HOME=""
fi
[[ -z "$REAL_HOME" ]] && REAL_HOME="$(eval echo "~${REAL_USER}" 2>/dev/null || true)"
[[ -z "$REAL_HOME" || "$REAL_HOME" == "~"* ]] && REAL_HOME="/root"

RVDK_DIR="${REAL_HOME}/.rvdk"
CACHE_DIR="${RVDK_DIR}/cache"
ENGINE_DIR="${RVDK_DIR}/engine"
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

# 1. Ensure git and curl are installed
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        log_info "Installing git and curl prerequisites..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o Acquire::Check-Valid-Until=false -o DPkg::Lock::Timeout=120 update -q || true
        apt-get -o DPkg::Lock::Timeout=120 install -y git ca-certificates curl
    else
        log_fatal "Missing git or curl. On macOS, run 'xcode-select --install' or 'brew install git curl'."
    fi
fi

# 2. Clone or update ~/.rvdk/engine
install -d -m 0755 -o "$REAL_USER" -g "$REAL_GRP" "$RVDK_DIR" "$CACHE_DIR"

if [[ -d "${ENGINE_DIR}/.git" ]]; then
    log_info "Updating RVDK engine in ${ENGINE_DIR} (${REPO_BRANCH})..."
    sudo -u "$REAL_USER" git -C "$ENGINE_DIR" fetch origin "$REPO_BRANCH" -q
    sudo -u "$REAL_USER" git -C "$ENGINE_DIR" reset --hard "origin/${REPO_BRANCH}" -q
else
    log_info "Cloning ${REPO_URL} into ${ENGINE_DIR}..."
    rm -rf "$ENGINE_DIR"
    sudo -u "$REAL_USER" git clone --branch "$REPO_BRANCH" "$REPO_URL" "$ENGINE_DIR" -q
fi

chmod +x "${ENGINE_DIR}/bootstrap.sh" "${ENGINE_DIR}/install-cli.sh" "${ENGINE_DIR}"/lib/*.sh "${ENGINE_DIR}"/utils/*.sh 2>/dev/null || true

# 3. Link /usr/local/bin/rvdk
install -d -m 0755 /usr/local/bin
ln -sf "${ENGINE_DIR}/bootstrap.sh" /usr/local/bin/rvdk
COMMIT_SHA="$(git -C "$ENGINE_DIR" rev-parse --short HEAD 2>/dev/null || echo "main")"
log_ok "Linked /usr/local/bin/rvdk -> ${ENGINE_DIR}/bootstrap.sh (${COMMIT_SHA})"

if [[ "$QUIET_MODE" == "false" ]]; then
    DT_MODEL="Unknown"
    if [[ -r /proc/device-tree/model ]]; then
        DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        DT_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m) (macOS Host)"
    fi

    OS_PRETTY="Unknown"
    if [[ -f /etc/os-release ]]; then
        OS_PRETTY="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Unknown}" || echo "Unknown")"
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
   sudo rvdk                  # Run full Day-0 (OS + Silicon BSP) forge
   sudo rvdk bsp              # Run Silicon BSP hardening only
   sudo rvdk os               # Run OS normalization & CVE guard only
   sudo rvdk postgresql       # Install PostgreSQL 18.6 (RVDK cache or --force-build)
   sudo rvdk mods/nvme-4kn    # Format 4Kn NVMe + LVM vg_braker + XFS/ext4
   sudo rvdk mods/btrfs-raid
   sudo rvdk mods/mosquitto
   sudo rvdk mods/nfs-vault
   sudo rvdk utils/<script>   # Run host media flash utilities (macOS / Linux)
   sudo rvdk update           # Pull latest RVDK engine from GitHub
======================================================================
EOF
fi
