#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: NFSv4 Vault Exporter (Auto: Kernel NFSD -> Ganesha)
# Path: riscv-data-kit/mods/nfs-vault/forge.sh
#
# Security & QoS Defaults:
#   • Requires explicit `--allow-cidr <CIDR>` (`--subnet`) OR `--auto-subnet`
#     (zero hardcoded private LAN assumptions)
#   • Enforces `root_squash` (`Squash = Root_Squash`) by default; `no_root_squash`
#     is gated behind `--dangerous-no-root-squash`
#   • Applies cgroup v2 CPU/IO QoS yield policy alongside bounded Ganesha MDCACHE
# ==============================================================================
set -Eeuo pipefail

ORIG_ARGS=("$@")
export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"

# @RVDK_INLINE_LIBS: common apt progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:NFSv4]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_resolve_caller() { REAL_USER="${SUDO_USER:-root}"; REAL_GRP="root"; }
        rvdk_load_config_env() { :; }
        rvdk_normalize_mount_path() {
            local p="${1:-}"
            while [[ "$p" != "/" && "$p" == */ ]]; do p="${p%/}"; done
            printf '%s\n' "$p"
        }
        rvdk_resolve_data_mount() {
            local explicit="${1:-${MOUNT_POINT:-}}"
            if [[ -n "$explicit" ]]; then
                rvdk_normalize_mount_path "$explicit"
            elif mountpoint -q /mnt/nvme_data 2>/dev/null; then
                printf '%s\n' "/mnt/nvme_data"
            else
                printf '%s' ""
            fi
        }
        rvdk_atomic_write() {
            local _dst="$1" _mode="${2:-0644}" _own="${3:-}" _tmp
            mkdir -p "$(dirname "$_dst")"
            _tmp="$(mktemp "$(dirname "$_dst")/.$(basename "$_dst").rvdk.XXXXXX")"
            cat > "$_tmp"
            chmod "$_mode" "$_tmp"
            [[ -n "$_own" ]] && chown "$_own" "$_tmp"
            mv -f "$_tmp" "$_dst"
        }
    fi
fi
if [[ -z "${_RVDK_APT_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/apt.sh" ]]; then
        # shellcheck source=lib/apt.sh
        source "${_REPO_ROOT}/lib/apt.sh"
    fi
fi
if [[ -z "${_RVDK_PROGBAR_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]]; then
        # shellcheck source=lib/progbar.sh
        source "${_REPO_ROOT}/lib/progbar.sh"
    else
        rvdk_prog_init() { :; }
        rvdk_prog()      { :; }
    fi
fi

if ! declare -F rvdk_validate_abs_path >/dev/null 2>&1; then
    rvdk_validate_abs_path() {
        local p="${1:-}"
        [[ -n "$p" && "$p" != *$'\n'* && "$p" != *$'\r'* ]] || return 1
        [[ "$p" =~ ^/[A-Za-z0-9._/-]+$ && ! "$p" =~ (^|/)\.\.(/|$) ]]
    }
fi

rvdk_log_init "RVDK:NFSv4"

usage() {
    cat <<'EOF'
Usage: sudo rvdk mods/nfs-vault (--allow-cidr <CIDR> | --auto-subnet) [options]

Options:
  --allow-cidr <CIDR>          Authorized client IPv4 subnet (e.g. 192.168.1.0/24; alias: --subnet)
  --auto-subnet                Auto-detect primary interface IPv4 subnet CIDR
  --data-mount <path>          Optional NVMe mount root for shared vault subdirectory
  --vault-path <path>          Explicit directory to export via NFSv4
  --backend <auto|kernel|ganesha>
                               NFSv4 server implementation (default: auto)
  --workers <N>                NFS-Ganesha worker thread count (default: 4x CPU clamped [16..64])
  --dangerous-no-root-squash   Disable root_squash (NOT recommended; grants remote UID 0 root access)
  --no-apt-update              Skip redundant apt-get update calls
  --noprogbar                  Disable persistent bottom progress bar
  -h, --help                   Show this help message and exit
EOF
}

for _arg in "$@"; do
    if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
        usage
        exit 0
    fi
done

rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
rvdk_resolve_caller

PRESET_BACKEND="${NFS_BACKEND:-}"
rvdk_load_config_env \
    NFS_ALLOW_CIDR RVDK_ALLOW_CIDR MOUNT_POINT SECONDARY_MOUNT_POINT NFS_MOUNT_POINT \
    NFS_VAULT_PATH NFS_WORKERS WITH_RAID RAID_ARRAYS_JSON NFS_BACKEND

ALLOW_CIDR="${NFS_ALLOW_CIDR:-${RVDK_ALLOW_CIDR:-}}"
AUTO_SUBNET="false"
DANGEROUS_NO_ROOT_SQUASH="false"
EXPLICIT_DATA_MOUNT=""
DEDICATED_NFS_MOUNT="${SECONDARY_MOUNT_POINT:-${NFS_MOUNT_POINT:-/mnt/nfs_vault}}"
VAULT_PATH_OVERRIDE="${NFS_VAULT_PATH:-}"
NFS_WORKERS_OVERRIDE="${NFS_WORKERS:-}"
WITH_RAID="${WITH_RAID:-false}"
RAID_ARRAYS_JSON="${RAID_ARRAYS_JSON:-[]}"
REQUESTED_BACKEND="${PRESET_BACKEND:-${NFS_BACKEND:-auto}}"

_require_arg() {
    [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."
    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-cidr|--subnet)               _require_arg "$1" "${2:-}"; ALLOW_CIDR="$2"; shift 2 ;;
        --auto-subnet)                       AUTO_SUBNET="true"; shift ;;
        --dangerous-no-root-squash)          DANGEROUS_NO_ROOT_SQUASH="true"; shift ;;
        --data-mount)                        _require_arg "$1" "${2:-}"; EXPLICIT_DATA_MOUNT="$2"; shift 2 ;;
        --vault-path|--nfs-mount)            _require_arg "$1" "${2:-}"; VAULT_PATH_OVERRIDE="$2"; shift 2 ;;
        --workers|--nb-worker)               _require_arg "$1" "${2:-}"; NFS_WORKERS_OVERRIDE="$2"; shift 2 ;;
        --backend|--nfs-backend)             _require_arg "$1" "${2:-}"; REQUESTED_BACKEND="$2"; shift 2 ;;
        --auto|--nfs-auto)                   REQUESTED_BACKEND="auto"; shift ;;
        --ganesha|--nfs-ganesha|--userspace) REQUESTED_BACKEND="ganesha"; shift ;;
        --kernel|--nfs-kernel|--nfs-kernal)  REQUESTED_BACKEND="kernel"; shift ;;
        --no-apt-update|--skip-apt-update)   export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)            export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)                           usage; exit 0 ;;
        *)                                   log_fatal "Unknown argument: $1 (try --help)" ;;
    esac
done

DATA_MOUNT="$(rvdk_resolve_data_mount "$EXPLICIT_DATA_MOUNT")"
DEDICATED_NFS_MOUNT="$(rvdk_normalize_mount_path "$DEDICATED_NFS_MOUNT")"
if [[ -n "$VAULT_PATH_OVERRIDE" ]]; then
    [[ "$VAULT_PATH_OVERRIDE" != *$'\n'* && "$VAULT_PATH_OVERRIDE" != *$'\r'* ]] || log_fatal "Invalid --vault-path (contains newline)."
    VAULT_PATH_OVERRIDE="$(rvdk_normalize_mount_path "$VAULT_PATH_OVERRIDE")"
    if [[ -z "$VAULT_PATH_OVERRIDE" || "$VAULT_PATH_OVERRIDE" == "/" ]] || ! rvdk_validate_abs_path "$VAULT_PATH_OVERRIDE"; then
        log_fatal "Invalid --vault-path '${VAULT_PATH_OVERRIDE}' (must be a safe non-root absolute path)."
    fi
fi

if [[ -z "$ALLOW_CIDR" && "$AUTO_SUBNET" == "true" ]]; then
    ALLOW_CIDR="$(rvdk_detect_primary_cidr || true)"
    [[ -z "$ALLOW_CIDR" ]] && log_fatal "--auto-subnet could not determine an active IPv4 subnet; pass --allow-cidr <CIDR>."
fi
if [[ -z "$ALLOW_CIDR" ]]; then
    log_fatal "Missing authorized client subnet. Pass --allow-cidr <IPv4/len> (e.g. 192.168.1.0/24) or --auto-subnet."
fi
_norm_cidr=""
if ! _norm_cidr="$(rvdk_normalize_ipv4_cidr "$ALLOW_CIDR")"; then
    log_fatal "Invalid IPv4 CIDR '${ALLOW_CIDR}'."
fi
ALLOW_CIDR="$_norm_cidr"

KERNEL_SQUASH_OPT="root_squash"
GANESHA_SQUASH_OPT="Root_Squash"
if [[ "$DANGEROUS_NO_ROOT_SQUASH" == "true" ]]; then
    log_warn "Enabling no_root_squash (--dangerous-no-root-squash): remote root on ${ALLOW_CIDR} retains UID 0 privileges!"
    KERNEL_SQUASH_OPT="no_root_squash"
    GANESHA_SQUASH_OPT="No_Root_Squash"
fi

REQUESTED_BACKEND="$(tr '[:upper:]' '[:lower:]' <<< "$REQUESTED_BACKEND")"
case "$REQUESTED_BACKEND" in
    auto)                          REQUESTED_BACKEND="auto" ;;
    ganesha|nfs-ganesha|userspace) REQUESTED_BACKEND="ganesha" ;;
    kernel|nfs-kernel|nfs-kernal|knfsd|nfsd) REQUESTED_BACKEND="kernel" ;;
    *) log_fatal "Unknown NFS backend '${REQUESTED_BACKEND}' (expected: auto | ganesha | kernel)" ;;
esac

rvdk_prog_init "NFSv4 Vault: probing backend (${REQUESTED_BACKEND})..."

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

rvdk_prog 30 "NFSv4 Vault: verifying ${NFS_MODE} server packages..."
if [[ "$NFS_MODE" == "kernel" ]]; then
    if systemctl is-active --quiet nfs-ganesha.service 2>/dev/null || systemctl is-enabled --quiet nfs-ganesha.service 2>/dev/null; then
        systemctl disable --now nfs-ganesha.service 2>/dev/null || true
        systemctl reset-failed nfs-ganesha.service nfs-ganesha-lock.service 2>/dev/null || true
    fi
    rvdk_apt_ensure nfs-kernel-server nfs-common jq
else
    exportfs -ua 2>/dev/null || true
    systemctl stop nfs-server.service nfs-kernel-server.service nfs-mountd.service nfsdcld.service 2>/dev/null || true
    systemctl disable nfs-server.service nfs-kernel-server.service 2>/dev/null || true
    systemctl reset-failed proc-fs-nfsd.mount nfs-server.service nfs-mountd.service nfsdcld.service 2>/dev/null || true
    rvdk_apt_ensure nfs-ganesha nfs-ganesha-vfs nfs-common jq
fi

rvdk_prog 65 "NFSv4 Vault: building export definitions (${ALLOW_CIDR}, ${KERNEL_SQUASH_OPT})..."
EXPORT_PATHS=()
EXPORT_FSIDS=()
EXPORT_LINES=()

ARRAY_COUNT="$(jq 'length' <<< "$RAID_ARRAYS_JSON" 2>/dev/null || echo 0)"
if [[ "$WITH_RAID" == "true" ]] && (( ARRAY_COUNT > 0 )); then
    for (( i=0; i<ARRAY_COUNT; i++ )); do
        ARR_RAW_MOUNT="$(jq -r "(if (.[$i].mount | type) == \"string\" then .[$i].mount else \"\" end) + \"_\"" <<< "$RAID_ARRAYS_JSON")"
        ARR_RAW_MOUNT="${ARR_RAW_MOUNT%_}"
        [[ "$ARR_RAW_MOUNT" != *$'\n'* && "$ARR_RAW_MOUNT" != *$'\r'* ]] || log_fatal "Invalid RAID array mount path at index ${i} (contains newline)."
        ARR_MOUNT="$(rvdk_normalize_mount_path "$ARR_RAW_MOUNT")"
        if [[ -z "$ARR_MOUNT" || "$ARR_MOUNT" == "/" ]] || ! rvdk_validate_abs_path "$ARR_MOUNT"; then
            log_fatal "Invalid RAID array mount path '${ARR_RAW_MOUNT}' at index ${i}."
        fi

        ARR_FSID="$(jq -r "((.[$i].nfs_fsid // $(( (i + 1) * 10 ))) | tostring) + \"_\"" <<< "$RAID_ARRAYS_JSON")"
        ARR_FSID="${ARR_FSID%_}"
        [[ "$ARR_FSID" =~ ^[1-9][0-9]*$ ]] || log_fatal "Invalid nfs_fsid '${ARR_FSID}' at RAID array index ${i} (expected positive integer >= 1)."
        for _seen_fsid in ${EXPORT_FSIDS[@]+"${EXPORT_FSIDS[@]}"}; do
            if [[ "$_seen_fsid" == "$ARR_FSID" ]]; then
                log_fatal "Duplicate nfs_fsid '${ARR_FSID}' in RAID_ARRAYS_JSON (index ${i})."
            fi
        done

        mkdir -p "$ARR_MOUNT"
        EXPORT_PATHS+=("$ARR_MOUNT")
        EXPORT_FSIDS+=("$ARR_FSID")
        EXPORT_LINES+=("${ARR_MOUNT} ${ALLOW_CIDR}(rw,sync,no_subtree_check,${KERNEL_SQUASH_OPT},fsid=${ARR_FSID})")
    done
elif [[ -n "$VAULT_PATH_OVERRIDE" ]]; then
    install -d -m 0775 -o "$REAL_USER" -g "$REAL_GRP" "$VAULT_PATH_OVERRIDE"
    EXPORT_PATHS+=("$VAULT_PATH_OVERRIDE")
    EXPORT_FSIDS+=("10")
    EXPORT_LINES+=("${VAULT_PATH_OVERRIDE} ${ALLOW_CIDR}(rw,sync,no_subtree_check,${KERNEL_SQUASH_OPT},fsid=10)")
    log_info "Export target: explicit vault path (${VAULT_PATH_OVERRIDE})"
elif [[ -n "$DEDICATED_NFS_MOUNT" ]] && mountpoint -q "$DEDICATED_NFS_MOUNT" 2>/dev/null; then
    chmod 0775 "$DEDICATED_NFS_MOUNT" 2>/dev/null || true
    EXPORT_PATHS+=("$DEDICATED_NFS_MOUNT")
    EXPORT_FSIDS+=("10")
    EXPORT_LINES+=("${DEDICATED_NFS_MOUNT} ${ALLOW_CIDR}(rw,sync,no_subtree_check,${KERNEL_SQUASH_OPT},fsid=10)")
    log_info "Export target: Dual-LVM isolated NFS volume (${DEDICATED_NFS_MOUNT})"
elif [[ -n "$DATA_MOUNT" ]] && mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    FALLBACK_VAULT="${DATA_MOUNT}/nfs_vault"
    install -d -m 0775 -o "$REAL_USER" -g "$REAL_GRP" "$FALLBACK_VAULT"
    EXPORT_PATHS+=("$FALLBACK_VAULT")
    EXPORT_FSIDS+=("10")
    EXPORT_LINES+=("${FALLBACK_VAULT} ${ALLOW_CIDR}(rw,sync,no_subtree_check,${KERNEL_SQUASH_OPT},fsid=10)")
    log_info "Export target: NVMe data mount subdirectory (${FALLBACK_VAULT})"
else
    FALLBACK_VAULT="/srv/nfs_vault"
    install -d -m 0775 -o "$REAL_USER" -g "$REAL_GRP" "$FALLBACK_VAULT"
    EXPORT_PATHS+=("$FALLBACK_VAULT")
    EXPORT_FSIDS+=("10")
    EXPORT_LINES+=("${FALLBACK_VAULT} ${ALLOW_CIDR}(rw,sync,no_subtree_check,${KERNEL_SQUASH_OPT},fsid=10)")
    log_info "Export target: rootfs service vault fallback (${FALLBACK_VAULT})"
fi

CPU_HARTS="$(nproc 2>/dev/null || echo 4)"
if [[ -n "$NFS_WORKERS_OVERRIDE" && "$NFS_WORKERS_OVERRIDE" =~ ^[0-9]+$ ]] && (( NFS_WORKERS_OVERRIDE > 0 )); then
    GANESHA_WORKERS="$NFS_WORKERS_OVERRIDE"
else
    GANESHA_WORKERS=$(( CPU_HARTS * 4 ))
    (( GANESHA_WORKERS < 16 )) && GANESHA_WORKERS=16
    (( GANESHA_WORKERS > 64 )) && GANESHA_WORKERS=64
fi

WANT_NFS_QOS="# Managed by RVDK (mods/nfs-vault/forge.sh)
# Yields CPU & block I/O to primary OLTP/compute services during bulk streaming
# while allowing full link saturation when the node is otherwise idle.
[Service]
CPUWeight=30
IOWeight=25
Nice=5
IOSchedulingClass=best-effort
IOSchedulingPriority=6"

rvdk_prog 85 "NFSv4 Vault: activating ${NFS_MODE} exports & I/O QoS..."
if [[ "$NFS_MODE" == "kernel" ]]; then
    mkdir -p /etc/exports.d
    EXPORTS_FILE="/etc/exports.d/rvdk-vaults.exports"
    WANT_EXPORTS="$(printf "%s\n" "${EXPORT_LINES[@]}")"

    EXPORTS_CHANGED="false"
    if ! printf "%s\n" "$WANT_EXPORTS" | cmp -s - "$EXPORTS_FILE" 2>/dev/null; then
        printf "%s\n" "$WANT_EXPORTS" | rvdk_atomic_write "$EXPORTS_FILE" 0644
        EXPORTS_CHANGED="true"
    fi

    QOS_DIR="/etc/systemd/system/nfs-server.service.d"
    QOS_FILE="${QOS_DIR}/90-rvdk-qos.conf"
    QOS_CHANGED="false"
    install -d -m 0755 "$QOS_DIR"
    if ! printf "%s\n" "$WANT_NFS_QOS" | cmp -s - "$QOS_FILE" 2>/dev/null; then
        printf "%s\n" "$WANT_NFS_QOS" | rvdk_atomic_write "$QOS_FILE" 0644
        systemctl daemon-reload
        QOS_CHANGED="true"
    fi

    if ! mountpoint -q /proc/fs/nfsd 2>/dev/null; then
        mount -t nfsd nfsd /proc/fs/nfsd 2>/dev/null || true
    fi
    if [[ "$EXPORTS_CHANGED" == "true" || "$QOS_CHANGED" == "true" ]] || ! systemctl is-active --quiet nfs-server.service; then
        systemctl enable --now nfs-kernel-server
        [[ "$QOS_CHANGED" == "true" ]] && systemctl restart nfs-server.service 2>/dev/null || true
        exportfs -ra
        log_ok "Exported NFSv4 vaults via kernel nfsd to ${ALLOW_CIDR} (${KERNEL_SQUASH_OPT}, QoS active)"
    else
        exportfs -ra
        log_skip "Kernel NFSv4 exports & QoS already converged (${EXPORTS_FILE})"
    fi
else
    QOS_DIR="/etc/systemd/system/nfs-ganesha.service.d"
    QOS_FILE="${QOS_DIR}/90-rvdk-qos.conf"
    QOS_CHANGED="false"
    install -d -m 0755 "$QOS_DIR"
    if ! printf "%s\n" "$WANT_NFS_QOS" | cmp -s - "$QOS_FILE" 2>/dev/null; then
        printf "%s\n" "$WANT_NFS_QOS" | rvdk_atomic_write "$QOS_FILE" 0644
        systemctl daemon-reload
        QOS_CHANGED="true"
        log_ok "Applied cgroup v2 CPU/IO yield policy (${QOS_FILE}: CPUWeight=30, IOWeight=25, Nice=5)"
    fi

    GANESHA_CONF="/etc/ganesha/ganesha.conf"
    mkdir -p /etc/ganesha /var/log/ganesha /var/lib/nfs/ganesha

    WANT_GANESHA="$(cat <<EOF
# ==============================================================================
# DREW-V Labs // RVDK Userspace NFSv4 Vault Exporter (NFS-Ganesha FSAL_VFS)
# Managed by: riscv-data-kit/mods/nfs-vault/forge.sh
# ==============================================================================
NFS_CORE_PARAM {
    Nb_Worker = ${GANESHA_WORKERS};
    Protocols = 4;
    Enable_NLM = false;
    Enable_RQUOTA = false;
}

NFSV4 {
    Graceless = true;
}

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
    Squash = ${GANESHA_SQUASH_OPT};
    SecType = sys;
    FSAL {
        Name = VFS;
    }
    CLIENT {
        Clients = ${ALLOW_CIDR}, 127.0.0.1;
        Access_Type = RW;
        Squash = ${GANESHA_SQUASH_OPT};
    }
}
EOF
)"
    done

    GANESHA_CHANGED="false"
    if ! printf "%s\n" "$WANT_GANESHA" | cmp -s - "$GANESHA_CONF" 2>/dev/null; then
        printf "%s\n" "$WANT_GANESHA" | rvdk_atomic_write "$GANESHA_CONF" 0644
        GANESHA_CHANGED="true"
    fi

    systemctl stop rpc-statd.service 2>/dev/null || true
    systemctl enable nfs-ganesha.service >/dev/null 2>&1 || true

    if [[ "$GANESHA_CHANGED" == "true" || "$QOS_CHANGED" == "true" ]] || ! systemctl is-active --quiet nfs-ganesha.service; then
        systemctl restart nfs-ganesha.service
        systemctl reset-failed nfs-ganesha-lock.service 2>/dev/null || true
        sleep 1
        if ! systemctl is-active --quiet nfs-ganesha.service; then
            tail -n 30 /var/log/ganesha/ganesha.log >&2 2>/dev/null || journalctl -u nfs-ganesha.service -n 30 --no-pager >&2 || true
            log_fatal "nfs-ganesha.service failed to stay active."
        fi
        log_ok "Exported NFSv4 vaults via userspace NFS-Ganesha (Nb_Worker=${GANESHA_WORKERS}, Squash=${GANESHA_SQUASH_OPT}) to ${ALLOW_CIDR}"
    else
        systemctl reset-failed nfs-ganesha-lock.service 2>/dev/null || true
        log_skip "Userspace NFSv4 exports & QoS (Nb_Worker=${GANESHA_WORKERS}) already converged (${GANESHA_CONF})"
    fi
fi

rvdk_prog 100 "NFSv4 vault exports converged (${NFS_MODE})"
