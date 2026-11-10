#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK CLI & Engine Installer
# Path: riscv-data-kit/install-cli.sh
# Description: Clones or updates the riscv-data-kit engine in ~/.rvdk/engine
#              and links /usr/local/bin/rvdk without modifying OS/BSP state.
#
# Usage:
#   curl -fsSL https://rvdk.drewv-labs.dev/install-cli.sh | sudo bash
# ==============================================================================
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    else
        echo "[RVDK:FATAL] Pipe into 'sudo bash': curl -fsSL https://rvdk.drewv-labs.dev/install-cli.sh | sudo bash" >&2
        exit 1
    fi
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
[[ -z "$REAL_HOME" ]] && REAL_HOME="/root"

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

log_info() { printf "\033[1;36m[RVDK:CLI]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }

# 1. Ensure git and curl are installed
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    log_info "Installing git and curl prerequisites..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o Acquire::Check-Valid-Until=false -o DPkg::Lock::Timeout=120 update -q || true
    apt-get -o DPkg::Lock::Timeout=120 install -y git ca-certificates curl
fi

# 2. Clone or update ~/.rvdk/engine
install -d -m 0755 -o "$REAL_USER" -g "$REAL_USER" "$RVDK_DIR" "$CACHE_DIR"

if [[ -d "${ENGINE_DIR}/.git" ]]; then
    log_info "Updating RVDK engine in ${ENGINE_DIR} (${REPO_BRANCH})..."
    sudo -u "$REAL_USER" git -C "$ENGINE_DIR" fetch origin "$REPO_BRANCH" -q
    sudo -u "$REAL_USER" git -C "$ENGINE_DIR" reset --hard "origin/${REPO_BRANCH}" -q
else
    log_info "Cloning ${REPO_URL} into ${ENGINE_DIR}..."
    rm -rf "$ENGINE_DIR"
    sudo -u "$REAL_USER" git clone --branch "$REPO_BRANCH" "$REPO_URL" "$ENGINE_DIR" -q
fi

chmod +x "${ENGINE_DIR}/bootstrap.sh" "${ENGINE_DIR}/install-cli.sh" 2>/dev/null || true

# 3. Link /usr/local/bin/rvdk
ln -sf "${ENGINE_DIR}/bootstrap.sh" /usr/local/bin/rvdk
COMMIT_SHA="$(git -C "$ENGINE_DIR" rev-parse --short HEAD 2>/dev/null || echo "main")"
log_ok "Linked /usr/local/bin/rvdk -> ${ENGINE_DIR}/bootstrap.sh (${COMMIT_SHA})"

if [[ "$QUIET_MODE" == "false" ]]; then
    DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
    OS_PRETTY="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Unknown}" || echo "Unknown")"
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
   sudo rvdk storage/nvme-4kn # Format 4Kn NVMe + LVM vg_braker + XFS/ext4
   sudo rvdk storage/btrfs-raid
   sudo rvdk mosquitto
   sudo rvdk nfs-vault
   sudo rvdk update           # Pull latest RVDK engine from GitHub
======================================================================
EOF
fi
