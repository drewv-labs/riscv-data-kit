#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: NFSv4 Kernel Server Vault Exporter
# Path: riscv-data-kit/nfs-vault/forge.sh
#
# Usage:
#   sudo rvdk nfs-vault [--subnet 10.0.10.0/24]
#   curl -fsSL https://rvdk.drewv-labs.dev/nfs-vault/forge.sh | sudo bash
# ==============================================================================
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    else
        echo "[RVDK:FATAL] Pipe into 'sudo bash': curl -fsSL ... | sudo bash" >&2
        exit 1
    fi
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6 2>/dev/null || eval echo "~${REAL_USER}")"
[[ -z "$REAL_HOME" ]] && REAL_HOME="/root"

NODE_ENV="${BRAKERRAK_NODE_ENV:-${REAL_HOME}/.brakerrak/node.env}"
# shellcheck disable=SC1090
[[ -f "$NODE_ENV" ]] && source "$NODE_ENV"

LAB_SUBNET="${LAB_SUBNET:-10.0.10.0/24}"
DATA_MOUNT="${MOUNT_POINT:-/mnt/nvme_pgdata}"
WITH_RAID="${WITH_RAID:-false}"
RAID_ARRAYS_JSON="${RAID_ARRAYS_JSON:-[]}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subnet)     LAB_SUBNET="${2:-10.0.10.0/24}"; shift 2 ;;
        --data-mount) DATA_MOUNT="${2:-/mnt/nvme_pgdata}"; shift 2 ;;
        *) shift ;;
    esac
done

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o DPkg::Options::="--force-confdef" -o DPkg::Options::="--force-confold")

log_info() { printf "\033[1;36m[RVDK:NFSv4]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }

# Check for kernel nfsd support prior to attempting nfs-kernel-server start
check_nfsd_support() {
    # If /proc/fs/nfsd already exists/mounted or nfsd module is loadable/built-in
    if [[ -d /proc/fs/nfsd ]] || grep -qw nfsd /proc/filesystems 2>/dev/null; then
        return 0
    fi
    if modprobe nfsd 2>/dev/null; then
        return 0
    fi
    # Check kernel config if available
    local kver
    kver="$(uname -r)"
    local kconf="/boot/config-${kver}"
    if [[ -f "$kconf" ]] && grep -qE "^CONFIG_NFSD=[my]" "$kconf" 2>/dev/null; then
        modprobe nfsd 2>/dev/null || true
        return 0
    fi
    return 1
}

apt-get update -q
apt-get install "${APT_FLAGS[@]}" nfs-kernel-server nfs-common jq

mkdir -p /etc/exports.d
EXPORTS_FILE="/etc/exports.d/rvdk-vaults.exports"
WANT_EXPORTS=""

ARRAY_COUNT="$(jq 'length' <<< "$RAID_ARRAYS_JSON" 2>/dev/null || echo 0)"
if [[ "$WITH_RAID" == "true" ]] && (( ARRAY_COUNT > 0 )); then
    for (( i=0; i<ARRAY_COUNT; i++ )); do
        ARR_MOUNT="$(jq -r ".[$i].mount" <<< "$RAID_ARRAYS_JSON")"
        ARR_FSID="$(jq -r ".[$i].nfs_fsid // $(( (i + 1) * 10 ))" <<< "$RAID_ARRAYS_JSON")"
        mkdir -p "$ARR_MOUNT"
        WANT_EXPORTS+="${ARR_MOUNT} ${LAB_SUBNET}(rw,sync,no_subtree_check,no_root_squash,fsid=${ARR_FSID})"$'\n'
    done
else
    FALLBACK_VAULT="${DATA_MOUNT}/nfs_vault"
    install -d -m 0775 -o "$REAL_USER" -g "$REAL_USER" "$FALLBACK_VAULT"
    WANT_EXPORTS="${FALLBACK_VAULT} ${LAB_SUBNET}(rw,sync,no_subtree_check,no_root_squash,fsid=10)"$'\n'
fi

if [[ ! -f "$EXPORTS_FILE" ]] || [[ "$(cat "$EXPORTS_FILE")" != "$WANT_EXPORTS" ]]; then
    printf "%s" "$WANT_EXPORTS" > "$EXPORTS_FILE"
fi

if ! check_nfsd_support; then
    log_warn "Linux kernel $(uname -r) lacks in-tree NFSD support (CONFIG_NFSD not enabled or module missing)."
    log_warn "nfs-kernel-server cannot mount /proc/fs/nfsd on this kernel. Exports configured in ${EXPORTS_FILE}."
    systemctl disable nfs-kernel-server 2>/dev/null || true
    exit 0
fi

# Ensure nfsd filesystem is mounted if not already
if ! mountpoint -q /proc/fs/nfsd 2>/dev/null; then
    mount -t nfsd nfsd /proc/fs/nfsd 2>/dev/null || true
fi

systemctl enable --now nfs-kernel-server
exportfs -ra 2>/dev/null || true
log_ok "Exported NFSv4 vaults to ${LAB_SUBNET} (${EXPORTS_FILE})"
