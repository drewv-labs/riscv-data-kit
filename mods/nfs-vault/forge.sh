#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: NFSv4 Vault Exporter (Auto: Kernel NFSD -> Ganesha)
# Path: riscv-data-kit/mods/nfs-vault/forge.sh
#
# Usage:
#   sudo rvdk mods/nfs-vault [--subnet 10.0.10.0/24] [--data-mount /mnt/nvme_pgdata] [--noprogbar]
#   sudo rvdk mods/nfs-vault [--auto | --ganesha | --kernel | --backend <auto|ganesha|kernel>]
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

# Inherit storage/subnet layout from BrakerRak node.env if present, while keeping
# standalone RVDK's own backend default as 'auto' unless explicitly passed.
PRESET_BACKEND="${NFS_BACKEND:-}"
NODE_ENV="${BRAKERRAK_NODE_ENV:-${REAL_HOME}/.brakerrak/node.env}"
# shellcheck disable=SC1090
[[ -f "$NODE_ENV" ]] && source "$NODE_ENV"

LAB_SUBNET="${LAB_SUBNET:-10.0.10.0/24}"
DATA_MOUNT="${MOUNT_POINT:-/mnt/nvme_pgdata}"
WITH_RAID="${WITH_RAID:-false}"
RAID_ARRAYS_JSON="${RAID_ARRAYS_JSON:-[]}"
# Standalone RVDK defaults to 'auto' (kernel -> ganesha fallback)
REQUESTED_BACKEND="${PRESET_BACKEND:-auto}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subnet)                            LAB_SUBNET="${2:-10.0.10.0/24}"; shift 2 ;;
        --data-mount)                        DATA_MOUNT="${2:-/mnt/nvme_pgdata}"; shift 2 ;;
        --backend|--nfs-backend)             REQUESTED_BACKEND="${2:-auto}"; shift 2 ;;
        --auto|--nfs-auto)                   REQUESTED_BACKEND="auto"; shift ;;
        --ganesha|--nfs-ganesha|--userspace) REQUESTED_BACKEND="ganesha"; shift ;;
        --kernel|--nfs-kernel|--nfs-kernal)  REQUESTED_BACKEND="kernel"; shift ;;
        --noprogbar|--no-progbar)            export RVDK_NO_PROGBAR="1"; shift ;;
        *) shift ;;
    esac
done

REQUESTED_BACKEND="$(tr '[:upper:]' '[:lower:]' <<< "$REQUESTED_BACKEND")"
case "$REQUESTED_BACKEND" in
    auto)                        REQUESTED_BACKEND="auto" ;;
    ganesha|nfs-ganesha|userspace) REQUESTED_BACKEND="ganesha" ;;
    kernel|nfs-kernel|nfs-kernal|knfsd|nfsd) REQUESTED_BACKEND="kernel" ;;
    *)
        echo "[RVDK:FATAL] Unknown NFS backend '${REQUESTED_BACKEND}' (expected: auto | ganesha | kernel)" >&2
        exit 1
        ;;
esac

_PROGBAR_CANDIDATE="${RVDK_PROGBAR_LIB:-}"
if [[ -z "$_PROGBAR_CANDIDATE" && -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -f "${_SCRIPT_DIR}/../../lib/progbar.sh" ]] && _PROGBAR_CANDIDATE="${_SCRIPT_DIR}/../../lib/progbar.sh"
fi
if [[ -n "$_PROGBAR_CANDIDATE" && -f "$_PROGBAR_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    source "$_PROGBAR_CANDIDATE"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_prog_init "NFSv4 Vault: probing backend (${REQUESTED_BACKEND})..."

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

log_info()  { printf "\033[1;36m[RVDK:NFSv4]\033[0m %s\n" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

# Reliably check whether the running kernel supports the 'nfsd' filesystem.
# Note: Do NOT check [[ -d /proc/fs/nfsd ]] because that empty mountpoint
# directory exists even on vendor kernels built with '# CONFIG_NFSD is not set'.
check_nfsd_support() {
    modprobe nfsd 2>/dev/null || true
    grep -qw nfsd /proc/filesystems 2>/dev/null
}

case "$REQUESTED_BACKEND" in
    kernel)
        if ! check_nfsd_support; then
            log_fatal "Kernel $(uname -r) lacks CONFIG_NFSD ('nfsd' missing from /proc/filesystems); cannot satisfy --kernel override."
        fi
        NFS_MODE="kernel"
        log_info "Backend: nfs-kernel-server (explicit kernel nfsd mode)"
        ;;
    ganesha)
        NFS_MODE="ganesha"
        log_info "Backend: nfs-ganesha (userspace FSAL_VFS on TCP :2049)"
        ;;
    auto)
        if check_nfsd_support; then
            NFS_MODE="kernel"
            log_info "Backend: nfs-kernel-server (auto-detected CONFIG_NFSD support)"
        else
            NFS_MODE="ganesha"
            log_warn "Kernel $(uname -r) lacks CONFIG_NFSD; falling back to userspace NFS-Ganesha (FSAL_VFS) on TCP :2049..."
        fi
        ;;
esac

rvdk_prog 30 "NFSv4 Vault: installing ${NFS_MODE} server packages..."
apt-get -o Acquire::Check-Valid-Until=false update -q || apt-get update -q

if [[ "$NFS_MODE" == "kernel" ]]; then
    if systemctl is-active --quiet nfs-ganesha.service 2>/dev/null || systemctl is-enabled --quiet nfs-ganesha.service 2>/dev/null; then
        systemctl disable --now nfs-ganesha.service 2>/dev/null || true
        systemctl reset-failed nfs-ganesha.service nfs-ganesha-lock.service 2>/dev/null || true
    fi
    apt-get install "${APT_FLAGS[@]}" nfs-kernel-server nfs-common jq
else
    exportfs -ua 2>/dev/null || true
    systemctl stop nfs-server.service nfs-kernel-server.service nfs-mountd.service nfsdcld.service 2>/dev/null || true
    systemctl disable nfs-server.service nfs-kernel-server.service 2>/dev/null || true
    systemctl reset-failed proc-fs-nfsd.mount nfs-server.service nfs-mountd.service nfsdcld.service 2>/dev/null || true
    apt-get install "${APT_FLAGS[@]}" nfs-ganesha nfs-ganesha-vfs nfs-common jq
fi

rvdk_prog 65 "NFSv4 Vault: building export definitions (${LAB_SUBNET})..."
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

rvdk_prog 85 "NFSv4 Vault: activating ${NFS_MODE} exports..."
if [[ "$NFS_MODE" == "kernel" ]]; then
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

# Bounded metadata/dirent cache sized to coexist cleanly alongside PostgreSQL 18
# Sv39 2MB HugePages on 8GB-16GB RISC-V SBCs (Chunks_LWMark * 128 <= Entries_HWMark)
MDCACHE {
    Entries_HWMark = 16384;
    Chunks_HWMark = 128;
    Chunks_LWMark = 64;
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

rvdk_prog 100 "NFSv4 vault exports converged (${NFS_MODE})"
