#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: NFSv4 Vault Exporter (Kernel NFSD + Ganesha VFS)
# Path: riscv-data-kit/mods/nfs-vault/forge.sh
#
# Usage:
#   sudo rvdk mods/nfs-vault [--subnet 10.0.10.0/24] [--data-mount /mnt/nvme_pgdata] [--ganesha]
#   curl -fsSL https://rvdk.drewv-labs.dev/mods/nfs-vault/forge.sh | sudo bash
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
REAL_GRP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6 2>/dev/null || eval echo "~${REAL_USER}")"
[[ -z "$REAL_HOME" ]] && REAL_HOME="/root"

NODE_ENV="${BRAKERRAK_NODE_ENV:-${REAL_HOME}/.brakerrak/node.env}"
# shellcheck disable=SC1090
[[ -f "$NODE_ENV" ]] && source "$NODE_ENV"

LAB_SUBNET="${LAB_SUBNET:-10.0.10.0/24}"
DATA_MOUNT="${MOUNT_POINT:-/mnt/nvme_pgdata}"
WITH_RAID="${WITH_RAID:-false}"
RAID_ARRAYS_JSON="${RAID_ARRAYS_JSON:-[]}"
FORCE_GANESHA="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subnet)              LAB_SUBNET="${2:-10.0.10.0/24}"; shift 2 ;;
        --data-mount)          DATA_MOUNT="${2:-/mnt/nvme_pgdata}"; shift 2 ;;
        --ganesha|--userspace) FORCE_GANESHA="true"; shift ;;
        *) shift ;;
    esac
done

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

log_info() { printf "\033[1;36m[RVDK:NFSv4]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }

# Reliably check whether the running kernel supports the 'nfsd' filesystem.
# Note: Do NOT check [[ -d /proc/fs/nfsd ]] because that empty mountpoint
# directory exists even on vendor kernels built with '# CONFIG_NFSD is not set'.
check_nfsd_support() {
    modprobe nfsd 2>/dev/null || true
    grep -qw nfsd /proc/filesystems 2>/dev/null
}

apt-get -o Acquire::Check-Valid-Until=false update -q || apt-get update -q

if [[ "$FORCE_GANESHA" != "true" ]] && check_nfsd_support; then
    NFS_MODE="kernel"
    apt-get install "${APT_FLAGS[@]}" nfs-kernel-server nfs-common jq
else
    NFS_MODE="ganesha"
    if [[ "$FORCE_GANESHA" == "true" ]]; then
        log_info "Using userspace NFS-Ganesha (FSAL_VFS) per --ganesha flag..."
    else
        log_warn "Kernel $(uname -r) lacks CONFIG_NFSD; falling back to userspace NFS-Ganesha (FSAL_VFS) on TCP :2049..."
    fi
    systemctl stop nfs-server.service nfs-kernel-server.service nfs-mountd.service nfsdcld.service 2>/dev/null || true
    systemctl disable nfs-server.service nfs-kernel-server.service 2>/dev/null || true
    systemctl reset-failed proc-fs-nfsd.mount nfs-server.service nfs-mountd.service nfsdcld.service 2>/dev/null || true
    apt-get install "${APT_FLAGS[@]}" nfs-ganesha nfs-ganesha-vfs nfs-common jq
fi

EXPORT_PATHS=()
EXPORT_FSIDS=()
EXPORT_LINES=()

ARRAY_COUNT="$(jq 'length' <<< "$RAID_ARRAYS_JSON" 2>/dev/null || echo 0)"
if [[ "$WITH_RAID" == "true" ]] && (( ARRAY_COUNT > 0 )); then
    for (( i=0; i<ARRAY_COUNT; i++ )); do
        ARR_MOUNT="$(jq -r ".[$i].mount" <<< "$RAID_ARRAYS_JSON")"
        ARR_FSID="$(jq -r ".[$i].nfs_fsid // $(( (i + 1) * 10 ))" <<< "$RAID_ARRAYS_JSON")"
        mkdir -p "$ARR_MOUNT"
        EXPORT_PATHS+=("$ARR_MOUNT")
        EXPORT_FSIDS+=("$ARR_FSID")
        EXPORT_LINES+=("${ARR_MOUNT} ${LAB_SUBNET}(rw,sync,no_subtree_check,no_root_squash,fsid=${ARR_FSID})")
    done
else
    FALLBACK_VAULT="${DATA_MOUNT}/nfs_vault"
    install -d -m 0775 -o "$REAL_USER" -g "$REAL_GRP" "$FALLBACK_VAULT"
    EXPORT_PATHS+=("$FALLBACK_VAULT")
    EXPORT_FSIDS+=("10")
    EXPORT_LINES+=("${FALLBACK_VAULT} ${LAB_SUBNET}(rw,sync,no_subtree_check,no_root_squash,fsid=10)")
fi

mkdir -p /etc/exports.d
EXPORTS_FILE="/etc/exports.d/rvdk-vaults.exports"
WANT_EXPORTS="$(printf "%s\n" "${EXPORT_LINES[@]}")"

EXPORTS_CHANGED="false"
if ! printf "%s\n" "$WANT_EXPORTS" | cmp -s - "$EXPORTS_FILE" 2>/dev/null; then
    printf "%s\n" "$WANT_EXPORTS" > "$EXPORTS_FILE"
    EXPORTS_CHANGED="true"
fi

if [[ "$NFS_MODE" == "kernel" ]]; then
    if systemctl is-active --quiet nfs-ganesha.service 2>/dev/null; then
        systemctl disable --now nfs-ganesha.service 2>/dev/null || true
    fi
    if ! mountpoint -q /proc/fs/nfsd 2>/dev/null; then
        mount -t nfsd nfsd /proc/fs/nfsd 2>/dev/null || true
    fi
    if [[ "$EXPORTS_CHANGED" == "true" ]] || ! systemctl is-active --quiet nfs-server.service; then
        systemctl enable --now nfs-kernel-server
        exportfs -ra
        log_ok "Exported NFSv4 vaults via kernel nfsd to ${LAB_SUBNET} (${EXPORTS_FILE})"
    else
        exportfs -ra
        log_skip "Kernel NFSv4 exports already converged (${EXPORTS_FILE})"
    fi
else
    GANESHA_CONF="/etc/ganesha/ganesha.conf"
    mkdir -p /etc/ganesha /var/log/ganesha /var/lib/nfs/ganesha

    WANT_GANESHA="$(cat <<EOF
# ==============================================================================
# DREW-V Labs // RVDK Userspace NFSv4 Vault Exporter (NFS-Ganesha FSAL_VFS)
# Managed by: riscv-data-kit/mods/nfs-vault/forge.sh
# ==============================================================================
NFS_CORE_PARAM {
    Protocols = 4;
    Enable_NLM = false;
    Enable_RQUOTA = false;
}

NFSV4 {
    Graceless = true;
}
EOF
)"

    for (( idx=0; idx<${#EXPORT_PATHS[@]}; idx++ )); do
        E_PATH="${EXPORT_PATHS[$idx]}"
        E_FSID="${EXPORT_FSIDS[$idx]}"
        WANT_GANESHA+=$'\n\n'"$(cat <<EOF
EXPORT {
    Export_Id = ${E_FSID};
    Path = "${E_PATH}";
    Pseudo = "${E_PATH}";
    Protocols = 4;
    Transports = TCP;
    Access_Type = None;
    Squash = No_Root_Squash;
    SecType = sys;
    FSAL {
        Name = VFS;
    }
    CLIENT {
        Clients = ${LAB_SUBNET}, 127.0.0.1;
        Access_Type = RW;
        Squash = No_Root_Squash;
    }
}
EOF
)"
    done

    GANESHA_CHANGED="false"
    if ! printf "%s\n" "$WANT_GANESHA" | cmp -s - "$GANESHA_CONF" 2>/dev/null; then
        printf "%s\n" "$WANT_GANESHA" > "$GANESHA_CONF"
        GANESHA_CHANGED="true"
    fi

    systemctl stop rpc-statd.service 2>/dev/null || true
    systemctl enable nfs-ganesha.service >/dev/null 2>&1 || true

    if [[ "$GANESHA_CHANGED" == "true" ]] || ! systemctl is-active --quiet nfs-ganesha.service; then
        systemctl restart nfs-ganesha.service
        systemctl reset-failed nfs-ganesha-lock.service 2>/dev/null || true
        sleep 1
        if ! systemctl is-active --quiet nfs-ganesha.service; then
            echo "[RVDK:FATAL] nfs-ganesha.service failed to stay active. Recent log:" >&2
            tail -n 30 /var/log/ganesha/ganesha.log >&2 2>/dev/null || journalctl -u nfs-ganesha.service -n 30 --no-pager >&2 || true
            exit 1
        fi
        log_ok "Exported NFSv4 vaults via userspace NFS-Ganesha (FSAL_VFS) to ${LAB_SUBNET} (${GANESHA_CONF})"
    else
        systemctl reset-failed nfs-ganesha-lock.service 2>/dev/null || true
        log_skip "Userspace NFSv4 exports (NFS-Ganesha) already converged (${GANESHA_CONF})"
    fi
fi
