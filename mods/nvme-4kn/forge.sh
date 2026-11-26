#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: NVMe 4Kn + LVM Elastic Storage Provisioner
# Path: riscv-data-kit/mods/nvme-4kn/forge.sh
#
# Layouts:
#   • Default (Single-LV):
#       lv_data      (85%VG) -> 4Kn XFS/ext4/Btrfs at /mnt/nvme_data
#       Free Pool    (15%VG) -> CoW snapshot & online growth reserve
#   • Dual-LV (--with-secondary-lv | --with-nfs-lv):
#       Primary LV   (45%VG) -> 4Kn XFS/ext4 at /mnt/nvme_data (ENOSPC-isolated)
#       Secondary LV (30%VG) -> Btrfs zstd:3 at /mnt/nvme_secondary (or /mnt/nfs_vault)
#       Free Pool    (25%VG) -> Shared elastic VG reserve + CoW snapshots
#
# Safety Interlocks:
#   • Unconditionally refuses to touch any disk backing /, /boot*, /usr, /var, /home, or SWAP
#   • Enforces cross-disk label & LVM Volume Group confinement before touching any metadata
#   • Refuses to wipe existing user filesystems/LVM/RAID/LUKS without --force-wipe
#   • Selects only metadata-free (ms:0) 4096B LBA formats during `nvme format`
# ==============================================================================
set -Eeuo pipefail

ORIG_ARGS=("$@")
export DEBIAN_FRONTEND=noninteractive
# shellcheck disable=SC2034 # Consumed by lib/apt.sh rvdk_apt_ensure
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"

# @RVDK_INLINE_LIBS: common apt storage_guard progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:NVME]\033[0m %s\n" "$1"; }
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
if [[ -z "${_RVDK_STORAGE_GUARD_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/storage_guard.sh" ]]; then
        # shellcheck source=lib/storage_guard.sh
        source "${_REPO_ROOT}/lib/storage_guard.sh"
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

rvdk_log_init "RVDK:NVME"

usage() {
    cat <<'EOF'
Usage: sudo rvdk mods/nvme-4kn --device <dev> [options]

Options:
  --device <dev>            Target NVMe block device (required unless NVME_DEV is set in config.env)
  --mount <path>            Primary mountpoint (default: /mnt/nvme_data)
  --label <label>           Primary filesystem label (default: RVDK_NVME)
  --fs <auto|xfs|ext4|btrfs> Primary filesystem type (default: auto -> xfs, ext4 fallback)
  --vg <name>               LVM Volume Group name (default: vg_rvdk)
  --lv <name>               Primary Logical Volume name (default: lv_data)
  --pct <pct>               Single-LV primary allocation (default: 85%VG)
  --with-secondary-lv       Provision secondary Btrfs elastic LV (/mnt/nvme_secondary)
  --with-nfs-lv             Provision isolated NFS vault LV (/mnt/nfs_vault, lv_nfsvault, NFS_VAULT)
  --secondary-mount <path>  Secondary mountpoint (default: /mnt/nvme_secondary)
  --secondary-lv <name>     Secondary LV name (default: lv_secondary)
  --secondary-label <label> Secondary filesystem label (default: RVDK_SEC)
  --primary-pct <pct>       Dual-LV primary allocation (default: 45%VG)
  --secondary-pct <pct>     Dual-LV secondary allocation (default: 30%VG)
  --no-lvm                  Use raw GPT partition instead of LVM2
  --force-wipe              Permit wiping pre-existing non-OS filesystems on --device
  -y, --yes                 Confirm destructive --force-wipe non-interactively
  --no-apt-update           Skip redundant apt-get update calls
  --noprogbar               Disable persistent bottom progress bar
  -h, --help                Show this help message and exit
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

rvdk_load_config_env \
    NVME_DEV MOUNT_POINT FS_LABEL VG_NAME LV_NAME LV_PCT PRIMARY_FSTYPE \
    WITH_SECONDARY_LV WITH_NFS_LV SECONDARY_LV_NAME NFS_LV_NAME \
    SECONDARY_FS_LABEL NFS_FS_LABEL SECONDARY_MOUNT_POINT NFS_MOUNT_POINT \
    DUAL_PRIMARY_PCT DUAL_SECONDARY_PCT DUAL_NFS_PCT \
    USE_LVM FORCE_WIPE_NVME

NVME_DEV="${NVME_DEV:-}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/nvme_data}"
FS_LABEL="${FS_LABEL:-RVDK_NVME}"
VG_NAME="${VG_NAME:-vg_rvdk}"
LV_NAME="${LV_NAME:-lv_data}"
LV_PCT="${LV_PCT:-85%VG}"
PRIMARY_FSTYPE="${PRIMARY_FSTYPE:-auto}"

WITH_NFS_LV="${WITH_NFS_LV:-false}"
WITH_SECONDARY_LV="${WITH_SECONDARY_LV:-${WITH_NFS_LV}}"
CLI_SEC_LV="${SECONDARY_LV_NAME:-}"
CLI_SEC_LABEL="${SECONDARY_FS_LABEL:-}"
CLI_SEC_MOUNT="${SECONDARY_MOUNT_POINT:-}"
DUAL_PRIMARY_PCT="${DUAL_PRIMARY_PCT:-45%VG}"
DUAL_SECONDARY_PCT="${DUAL_SECONDARY_PCT:-${DUAL_NFS_PCT:-30%VG}}"

USE_LVM="${USE_LVM:-true}"
FORCE_WIPE="${FORCE_WIPE_NVME:-false}"
SKIP_CONFIRM="false"

_require_arg() {
    [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."
    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)                               _require_arg "$1" "${2:-}"; NVME_DEV="$2"; shift 2 ;;
        --device=*)                             NVME_DEV="${1#*=}"; [[ -n "$NVME_DEV" ]] || log_fatal "Option '--device=' requires an argument."; shift ;;
        --mount)                                _require_arg "$1" "${2:-}"; MOUNT_POINT="$2"; shift 2 ;;
        --label)                                _require_arg "$1" "${2:-}"; FS_LABEL="$2"; shift 2 ;;
        --fs|--fstype)                          _require_arg "$1" "${2:-}"; PRIMARY_FSTYPE="$2"; shift 2 ;;
        --vg|--vg-name)                         _require_arg "$1" "${2:-}"; VG_NAME="$2"; shift 2 ;;
        --lv|--lv-name)                         _require_arg "$1" "${2:-}"; LV_NAME="$2"; shift 2 ;;
        --pct|--lv-pct)                         _require_arg "$1" "${2:-}"; LV_PCT="$2"; shift 2 ;;
        --with-secondary-lv|--dual-lvm)         WITH_SECONDARY_LV="true"; shift ;;
        --with-nfs-lv)                          WITH_SECONDARY_LV="true"; WITH_NFS_LV="true"; shift ;;
        --no-secondary-lv|--no-nfs-lv)          WITH_SECONDARY_LV="false"; WITH_NFS_LV="false"; shift ;;
        --secondary-mount|--nfs-mount)          _require_arg "$1" "${2:-}"; CLI_SEC_MOUNT="$2"; shift 2 ;;
        --secondary-lv|--nfs-lv)                _require_arg "$1" "${2:-}"; CLI_SEC_LV="$2"; shift 2 ;;
        --secondary-label|--nfs-label)          _require_arg "$1" "${2:-}"; CLI_SEC_LABEL="$2"; shift 2 ;;
        --primary-pct)                          _require_arg "$1" "${2:-}"; DUAL_PRIMARY_PCT="$2"; shift 2 ;;
        --secondary-pct|--nfs-pct)              _require_arg "$1" "${2:-}"; DUAL_SECONDARY_PCT="$2"; shift 2 ;;
        --no-lvm)                               USE_LVM="false"; shift ;;
        --force-wipe|--force-wipe-nvme)         FORCE_WIPE="true"; shift ;;
        -y|--yes)                               SKIP_CONFIRM="true"; shift ;;
        --no-apt-update|--skip-apt-update)      export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)               export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)                              usage; exit 0 ;;
        *)                                      log_fatal "Unknown argument: $1 (try --help)" ;;
    esac
done

_nvme_list_candidates() {
    local -a candidates=()
    local lsblk_out="" line="" path="" size="" type="" model="" entry="" sys_node="" blk_name="" sz_bytes=""
    if command -v lsblk >/dev/null 2>&1; then
        lsblk_out="$(lsblk -dn -o PATH,SIZE,TYPE,MODEL 2>/dev/null || true)"
        if [[ -z "$lsblk_out" ]]; then
            lsblk_out="$(lsblk -dn -o PATH,SIZE,TYPE 2>/dev/null || true)"
        fi
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            read -r path size type model <<< "$line"
            [[ "$path" == /dev/nvme* ]] || continue
            if [[ -n "$type" && "$type" != "disk" ]]; then
                continue
            fi
            if [[ -z "$type" && ! "$path" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
                continue
            fi
            entry="${path}"
            [[ -n "$size" ]] && entry="${entry} (${size}${model:+ ${model}})"
            candidates+=("$entry")
        done <<< "$lsblk_out"
    fi
    if (( ${#candidates[@]} == 0 )) && compgen -G "/sys/block/nvme*" >/dev/null 2>&1; then
        for sys_node in /sys/block/nvme*; do
            [[ -e "$sys_node" ]] || continue
            blk_name="$(basename "$sys_node")"
            sz_bytes=""
            if [[ -r "${sys_node}/size" ]]; then
                sz_bytes="$(cat "${sys_node}/size" 2>/dev/null || true)"
            fi
            if [[ "$sz_bytes" =~ ^[0-9]+$ ]] && (( sz_bytes > 0 )); then
                candidates+=("/dev/${blk_name} ($(( (sz_bytes * 512) / 1073741824 ))GiB)")
            else
                candidates+=("/dev/${blk_name}")
            fi
        done
    fi
    if (( ${#candidates[@]} == 0 )); then
        printf 'none detected'
    else
        local joined="" c=""
        for c in "${candidates[@]}"; do
            if [[ -z "$joined" ]]; then
                joined="$c"
            else
                joined="${joined}, ${c}"
            fi
        done
        printf '%s' "$joined"
    fi
}

if [[ -z "$NVME_DEV" ]]; then
    _nvme_candidates="$(_nvme_list_candidates)"
    log_fatal "Missing target NVMe block device: pass --device <dev> (or set NVME_DEV in /etc/rvdk/config.env). Candidate NVMe block devices: ${_nvme_candidates}"
fi

if [[ "$WITH_NFS_LV" == "true" ]]; then
    SECONDARY_LV_NAME="${CLI_SEC_LV:-${NFS_LV_NAME:-lv_nfsvault}}"
    SECONDARY_FS_LABEL="${CLI_SEC_LABEL:-${NFS_FS_LABEL:-NFS_VAULT}}"
    SECONDARY_MOUNT_POINT="${CLI_SEC_MOUNT:-${NFS_MOUNT_POINT:-/mnt/nfs_vault}}"
else
    SECONDARY_LV_NAME="${CLI_SEC_LV:-lv_secondary}"
    SECONDARY_FS_LABEL="${CLI_SEC_LABEL:-RVDK_SEC}"
    SECONDARY_MOUNT_POINT="${CLI_SEC_MOUNT:-/mnt/nvme_secondary}"
fi

_nvme_validate_fs_label() {
    local flag_name="$1"
    local label="$2"
    local fstype="$3"
    local max_len=0
    case "$fstype" in
        xfs)   max_len=12 ;;
        ext4)  max_len=16 ;;
        btrfs) max_len=255 ;;
    esac
    if (( max_len > 0 && ${#label} > max_len )); then
        log_fatal "Invalid ${flag_name} '${label}': length ${#label} exceeds ${fstype} maximum of ${max_len} characters."
    fi
}

MOUNT_POINT="$(rvdk_normalize_mount_path "$MOUNT_POINT")"
SECONDARY_MOUNT_POINT="$(rvdk_normalize_mount_path "$SECONDARY_MOUNT_POINT")"

[[ -z "$MOUNT_POINT" || "$MOUNT_POINT" != /* || "$MOUNT_POINT" == "/" ]] && log_fatal "Invalid --mount '${MOUNT_POINT}'."
[[ -z "$SECONDARY_MOUNT_POINT" || "$SECONDARY_MOUNT_POINT" != /* || "$SECONDARY_MOUNT_POINT" == "/" ]] && log_fatal "Invalid --secondary-mount '${SECONDARY_MOUNT_POINT}'."
[[ "$FS_LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --label '${FS_LABEL}'."
[[ "$SECONDARY_FS_LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --secondary-label '${SECONDARY_FS_LABEL}'."
[[ "$VG_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --vg '${VG_NAME}'."
[[ "$LV_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --lv '${LV_NAME}'."
[[ "$SECONDARY_LV_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --secondary-lv '${SECONDARY_LV_NAME}'."

_pri_fs_lc="$(tr '[:upper:]' '[:lower:]' <<< "$PRIMARY_FSTYPE")"
case "$_pri_fs_lc" in
    xfs|ext4|btrfs) _nvme_validate_fs_label "--label" "$FS_LABEL" "$_pri_fs_lc" ;;
esac

[[ ! -b "$NVME_DEV" ]] && log_fatal "NVMe block device not found: ${NVME_DEV}"
NVME_DEV="$(readlink -f "$NVME_DEV")"
[[ ! -b "$NVME_DEV" ]] && log_fatal "NVMe block device not found after canonicalization: ${NVME_DEV}"
if rvdk_device_backs_os_or_swap "$NVME_DEV"; then
    log_fatal "Safety Interlock: ${NVME_DEV} backs a critical OS filesystem or active SWAP! Aborting."
fi

if [[ "$FORCE_WIPE" == "true" && "$SKIP_CONFIRM" != "true" ]]; then
    if [[ -t 0 ]]; then
        printf "\033[1;33m[CONFIRM]\033[0m --force-wipe will DESTROY existing partitions/data on %s. Continue? [y/N]: " "$NVME_DEV"
        _wipe_reply=""
        read -r _wipe_reply || true
        case "$_wipe_reply" in
            [Yy]|[Yy][Ee][Ss]) ;;
            *) log_fatal "Aborted by user." ;;
        esac
    else
        log_fatal "Refusing destructive '--force-wipe' without '--yes' (-y) when stdin is not a TTY."
    fi
fi

rvdk_prog_init "NVMe 4Kn: validating ${NVME_DEV}..."

REQ_PKGS=(nvme-cli lvm2 xfsprogs e2fsprogs parted util-linux)
if [[ "$PRIMARY_FSTYPE" == "btrfs" ]] || [[ "$WITH_SECONDARY_LV" == "true" && "$USE_LVM" == "true" ]]; then
    REQ_PKGS+=(btrfs-progs)
fi
rvdk_prog 15 "NVMe 4Kn: verifying storage prerequisites..."
rvdk_apt_ensure "${REQ_PKGS[@]}"

PRIMARY_FSTYPE="$(tr '[:upper:]' '[:lower:]' <<< "$PRIMARY_FSTYPE")"
FSTYPE_IS_AUTO="false"
case "$PRIMARY_FSTYPE" in
    auto)
        FSTYPE_IS_AUTO="true"
        if modprobe xfs 2>/dev/null || grep -qw xfs /proc/filesystems; then
            NVME_FSTYPE="xfs"
        else
            NVME_FSTYPE="ext4"
        fi
        ;;
    xfs|ext4|btrfs)
        NVME_FSTYPE="$PRIMARY_FSTYPE"
        ;;
    *)
        log_fatal "Unsupported --fs '${PRIMARY_FSTYPE}' (expected: auto | xfs | ext4 | btrfs)."
        ;;
esac

if modprobe btrfs 2>/dev/null || grep -qw btrfs /proc/filesystems; then
    SEC_FSTYPE="btrfs"
else
    SEC_FSTYPE="$NVME_FSTYPE"
fi

# 1. Cross-Disk Label & LVM Volume Group Confinement Interlocks
EXISTING_FS_DEV="$(blkid -L "$FS_LABEL" 2>/dev/null || true)"
if [[ -n "$EXISTING_FS_DEV" ]] && ! rvdk_block_resides_on_disk "$EXISTING_FS_DEV" "$NVME_DEV"; then
    log_fatal "Cross-Disk Safety Interlock: filesystem label '${FS_LABEL}' already exists on '${EXISTING_FS_DEV}', which does NOT reside on '${NVME_DEV}'. Pass a unique --label <name> (and --vg <name>)."
fi

# Idempotent adoption when target --mount (or --vg/--lv) is already provisioned on --device
if [[ -z "$EXISTING_FS_DEV" && "$FORCE_WIPE" == "false" ]]; then
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        _mnt_src="$(findmnt -rn -o SOURCE -M "$MOUNT_POINT" 2>/dev/null || true)"
        _mnt_src="${_mnt_src%%\[*}"
        if [[ -b "$_mnt_src" ]]; then
            if rvdk_block_resides_on_disk "$_mnt_src" "$NVME_DEV"; then
                EXISTING_FS_DEV="$_mnt_src"
            else
                log_fatal "Cross-Disk Safety Interlock: target mount '${MOUNT_POINT}' is currently mounted from '${_mnt_src}', which does NOT reside on '${NVME_DEV}'."
            fi
        fi
    elif [[ "$USE_LVM" == "true" && -b "/dev/${VG_NAME}/${LV_NAME}" ]] && rvdk_block_resides_on_disk "/dev/${VG_NAME}/${LV_NAME}" "$NVME_DEV"; then
        _lv_type="$(blkid -s TYPE -o value "/dev/${VG_NAME}/${LV_NAME}" 2>/dev/null || true)"
        case "$_lv_type" in
            xfs|ext4|btrfs) EXISTING_FS_DEV="/dev/${VG_NAME}/${LV_NAME}" ;;
        esac
    fi
fi

if [[ "$WITH_SECONDARY_LV" == "true" ]]; then
    EXISTING_SEC_PRE="$(blkid -L "$SECONDARY_FS_LABEL" 2>/dev/null || true)"
    if [[ -n "$EXISTING_SEC_PRE" ]] && ! rvdk_block_resides_on_disk "$EXISTING_SEC_PRE" "$NVME_DEV"; then
        log_fatal "Cross-Disk Safety Interlock: secondary label '${SECONDARY_FS_LABEL}' already exists on '${EXISTING_SEC_PRE}', which does NOT reside on '${NVME_DEV}'. Pass a unique --secondary-label <name>."
    fi
    if mountpoint -q "$SECONDARY_MOUNT_POINT" 2>/dev/null; then
        _sec_mnt_src="$(findmnt -rn -o SOURCE -M "$SECONDARY_MOUNT_POINT" 2>/dev/null || true)"
        _sec_mnt_src="${_sec_mnt_src%%\[*}"
        if [[ -b "$_sec_mnt_src" ]] && ! rvdk_block_resides_on_disk "$_sec_mnt_src" "$NVME_DEV"; then
            log_fatal "Cross-Disk Safety Interlock: secondary mount '${SECONDARY_MOUNT_POINT}' is currently mounted from '${_sec_mnt_src}', which does NOT reside on '${NVME_DEV}'."
        fi
    fi
fi

if [[ "$USE_LVM" == "true" ]] && vgs "$VG_NAME" >/dev/null 2>&1; then
    if ! rvdk_vg_exclusively_on_disk "$VG_NAME" "$NVME_DEV"; then
        log_fatal "Cross-Disk Safety Interlock: LVM Volume Group '${VG_NAME}' already resides on a disk other than '${NVME_DEV}'. Refusing to touch '/dev/${VG_NAME}/*' or run vgremove — pass a unique --vg <name>."
    fi
fi

NVME_SHORT="$(basename "$NVME_DEV")"
EXISTING_FS_TYPE=""
[[ -n "$EXISTING_FS_DEV" ]] && EXISTING_FS_TYPE="$(blkid -s TYPE -o value "$EXISTING_FS_DEV" 2>/dev/null || true)"

if [[ "$FORCE_WIPE" == "false" && "$FSTYPE_IS_AUTO" == "true" ]]; then
    case "$EXISTING_FS_TYPE" in
        xfs|ext4|btrfs) NVME_FSTYPE="$EXISTING_FS_TYPE" ;;
    esac
fi

_nvme_validate_fs_label "--label" "$FS_LABEL" "$NVME_FSTYPE"
if [[ "$WITH_SECONDARY_LV" == "true" && "$USE_LVM" == "true" ]]; then
    _nvme_validate_fs_label "--secondary-label" "$SECONDARY_FS_LABEL" "$SEC_FSTYPE"
fi

EFFECTIVE_PRI_LABEL="$FS_LABEL"
EFFECTIVE_PRI_SPEC="LABEL=${FS_LABEL}"
if [[ -n "$EXISTING_FS_DEV" && "$FORCE_WIPE" == "false" ]]; then
    _pri_lbl="$(blkid -s LABEL -o value "$EXISTING_FS_DEV" 2>/dev/null || true)"
    _pri_uuid="$(blkid -s UUID -o value "$EXISTING_FS_DEV" 2>/dev/null || true)"
    if [[ -n "$_pri_lbl" ]]; then
        EFFECTIVE_PRI_LABEL="$_pri_lbl"
        EFFECTIVE_PRI_SPEC="LABEL=${_pri_lbl}"
    elif [[ -n "$_pri_uuid" ]]; then
        EFFECTIVE_PRI_SPEC="UUID=${_pri_uuid}"
    fi
fi

# If existing volume is NOT already converged, enforce non-destructive storage guard before wiping
if [[ -z "$EXISTING_FS_DEV" || "$EXISTING_FS_TYPE" != "$NVME_FSTYPE" || "$FORCE_WIPE" == "true" ]]; then
    rvdk_assert_device_safe_to_wipe "$NVME_DEV" "$FORCE_WIPE" "${FS_LABEL},${EFFECTIVE_PRI_LABEL},${SECONDARY_FS_LABEL},RVDK_NVME,RVDK_SEC,NFS_VAULT"
fi

_nvme_ensure_unmounted() {
    local dev_scope="$1"
    shift || true
    local -a mnt_targets=()
    local mp _desc_mnt _sorted_mnt

    for mp in "$@"; do
        [[ -n "$mp" ]] && mnt_targets+=("$mp")
    done

    if [[ -n "$dev_scope" && -b "$dev_scope" ]]; then
        while IFS= read -r _desc_mnt; do
            [[ -n "$_desc_mnt" && "$_desc_mnt" == /* ]] && mnt_targets+=("$_desc_mnt")
        done < <(_rvdk_lsblk_mountpoints "$dev_scope")
    fi

    if (( ${#mnt_targets[@]} > 0 )); then
        while IFS= read -r _sorted_mnt; do
            [[ -n "$_sorted_mnt" ]] || continue
            if mountpoint -q "$_sorted_mnt" 2>/dev/null; then
                umount "$_sorted_mnt" 2>/dev/null || true
            fi
        done < <(printf '%s\n' "${mnt_targets[@]}" | awk '!seen[$0]++ { printf "%d\t%s\n", length($0), $0 }' | sort -rn -k1,1 | cut -f2-)
    fi

    for mp in "$@"; do
        [[ -n "$mp" ]] || continue
        if mountpoint -q "$mp" 2>/dev/null; then
            log_fatal "Cannot proceed: mountpoint '${mp}' is still mounted/busy."
        fi
    done

    if [[ -n "$dev_scope" && -b "$dev_scope" ]]; then
        while IFS= read -r _desc_mnt; do
            [[ -z "$_desc_mnt" ]] && continue
            log_fatal "Cannot proceed: ${dev_scope} still has busy/mounted descendant '${_desc_mnt}'."
        done < <(_rvdk_lsblk_mountpoints "$dev_scope")
    fi
}

_nvme_deactivate_vg_if_exists() {
    local vg="$1"
    if command -v vgs >/dev/null 2>&1 && vgs "$vg" >/dev/null 2>&1; then
        if [[ "$USE_LVM" == "true" ]] || rvdk_vg_exclusively_on_disk "$vg" "$NVME_DEV"; then
            if ! vgchange -an "$vg"; then
                log_fatal "Failed to deactivate LVM Volume Group '${vg}' before modifying ${NVME_DEV}."
            fi
        fi
    fi
}

_nvme_wipe_partitions() {
    local dev="$1" _part
    while IFS= read -r _part; do
        [[ -n "$_part" && -b "$_part" ]] || continue
        wipefs -af "$_part" >/dev/null
    done < <(rvdk_list_child_partitions "$dev")
}

# 2. Verify or Convert to Native 4096-Byte (4Kn) Hardware LBA Sectors (ms:0 ONLY)
rvdk_prog 35 "NVMe 4Kn: checking 4096B LBA sector geometry..."
[[ -r "/sys/block/${NVME_SHORT}/queue/logical_block_size" ]] || log_fatal "Target --device '${NVME_DEV}' is not a whole block device (missing /sys/block/${NVME_SHORT}/queue/logical_block_size)."
CUR_LBA="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
if [[ -n "$EXISTING_FS_DEV" && "$EXISTING_FS_TYPE" == "$NVME_FSTYPE" && "$FORCE_WIPE" == "false" ]]; then
    if [[ "$CUR_LBA" == "4096" ]]; then
        log_skip "Existing 4Kn volume '${EFFECTIVE_PRI_LABEL}' found on ${EXISTING_FS_DEV} (4096B sectors)"
    else
        log_skip "Existing volume '${EFFECTIVE_PRI_LABEL}' found on ${EXISTING_FS_DEV} (${CUR_LBA}B sectors; pass --force-wipe to reformat as 4Kn)"
    fi
else
    if [[ "$CUR_LBA" != "4096" || "$FORCE_WIPE" == "true" ]]; then
        _nvme_ensure_unmounted "$NVME_DEV" "$MOUNT_POINT" "$SECONDARY_MOUNT_POINT"
        _nvme_deactivate_vg_if_exists "$VG_NAME"

        # Strictly require ms:0 (zero out-of-band metadata bytes) so Linux block layer never rejects T10-DIF LBA formats
        LBA_4K_IDX="$(nvme id-ns "$NVME_DEV" 2>/dev/null | awk '/lbads:12/ && /ms:0([[:space:]]|$)/ {print $2}' | tr -dc '0-9' | head -n1 || true)"
        if [[ -n "$LBA_4K_IDX" && "$CUR_LBA" != "4096" ]]; then
            rvdk_prog 45 "NVMe 4Kn: formatting ${NVME_DEV} to 4096B LBA (ms:0)..."
            log_info "Formatting ${NVME_DEV} from ${CUR_LBA}B to 4096B (4Kn, ms:0) sectors (LBA Format Index: ${LBA_4K_IDX})..."
            nvme format "$NVME_DEV" -l "$LBA_4K_IDX" --force
            partprobe "$NVME_DEV" 2>/dev/null || true
            udevadm settle
            sleep 2
            log_ok "${NVME_DEV} formatted to native 4096-byte sectors"
        else
            log_skip "${NVME_DEV} already at ${CUR_LBA}B sectors (or metadata-free 4Kn LBA index not advertised)"
        fi
    fi
fi

# 3. Provision Primary Volume (${VG_NAME}/${LV_NAME}) & Format
EFFECTIVE_PRI_PCT="$LV_PCT"
if [[ "$WITH_SECONDARY_LV" == "true" && "$USE_LVM" == "true" ]]; then
    EFFECTIVE_PRI_PCT="$DUAL_PRIMARY_PCT"
fi

FSTYPE_UPPER="$(tr '[:lower:]' '[:upper:]' <<< "$NVME_FSTYPE")"
rvdk_prog 55 "NVMe 4Kn: converging primary volume (${VG_NAME}/${LV_NAME}) & ${FSTYPE_UPPER}..."
if [[ -n "$EXISTING_FS_DEV" && "$EXISTING_FS_TYPE" == "$NVME_FSTYPE" && "$FORCE_WIPE" == "false" ]]; then
    TARGET_BLOCK_DEV="$EXISTING_FS_DEV"
    log_skip "${FSTYPE_UPPER} volume '${EFFECTIVE_PRI_LABEL}' already converged at ${TARGET_BLOCK_DEV}"
else
    if [[ "$USE_LVM" == "true" && -b "/dev/${VG_NAME}/${LV_NAME}" && "$FORCE_WIPE" == "false" ]] \
       && rvdk_block_resides_on_disk "/dev/${VG_NAME}/${LV_NAME}" "$NVME_DEV" \
       && [[ -z "$(blkid -s TYPE -o value "/dev/${VG_NAME}/${LV_NAME}" 2>/dev/null || true)" ]]; then
        TARGET_BLOCK_DEV="/dev/${VG_NAME}/${LV_NAME}"
        _nvme_ensure_unmounted "$TARGET_BLOCK_DEV" "$MOUNT_POINT"
        log_warn "Formatting uninitialized LVM volume ${TARGET_BLOCK_DEV} as ${NVME_FSTYPE}..."
        wipefs -af "$TARGET_BLOCK_DEV" >/dev/null
    elif [[ "$USE_LVM" == "true" ]]; then
        _nvme_ensure_unmounted "$NVME_DEV" "$MOUNT_POINT" "$SECONDARY_MOUNT_POINT"
        _nvme_deactivate_vg_if_exists "$VG_NAME"
        log_info "Building LVM Volume Group (${VG_NAME}/${LV_NAME} @ ${EFFECTIVE_PRI_PCT}) on ${NVME_DEV}..."
        if vgs "$VG_NAME" >/dev/null 2>&1; then
            vgremove -ff -y "$VG_NAME"
        fi
        if pvs "$NVME_DEV" >/dev/null 2>&1; then
            pvremove -ff -y "$NVME_DEV"
        fi
        _nvme_wipe_partitions "$NVME_DEV"
        wipefs -af "$NVME_DEV"
        partprobe "$NVME_DEV" 2>/dev/null || true

        pvcreate --dataalignment 4m -f -y "$NVME_DEV"
        vgcreate -s 4m "$VG_NAME" "$NVME_DEV"
        lvcreate -l "$EFFECTIVE_PRI_PCT" -n "$LV_NAME" -y "$VG_NAME"
        TARGET_BLOCK_DEV="/dev/${VG_NAME}/${LV_NAME}"
        log_ok "Created LVM Logical Volume ${TARGET_BLOCK_DEV} (${EFFECTIVE_PRI_PCT})"
    else
        _nvme_ensure_unmounted "$NVME_DEV" "$MOUNT_POINT" "$SECONDARY_MOUNT_POINT"
        _nvme_deactivate_vg_if_exists "$VG_NAME"
        log_info "Creating GPT partition layout on ${NVME_DEV}..."
        _nvme_wipe_partitions "$NVME_DEV"
        wipefs -af "$NVME_DEV"
        parted -s "$NVME_DEV" mklabel gpt
        parted -s -a optimal "$NVME_DEV" mkpart primary "$NVME_FSTYPE" 1MiB 100%
        partprobe "$NVME_DEV" 2>/dev/null || true
        udevadm settle && sleep 2
        if [[ "$NVME_DEV" =~ [0-9]$ ]]; then
            TARGET_BLOCK_DEV="${NVME_DEV}p1"
        else
            TARGET_BLOCK_DEV="${NVME_DEV}1"
        fi
    fi

    rvdk_prog 70 "NVMe 4Kn: mkfs.${NVME_FSTYPE} (${FS_LABEL})..."
    SECTOR_SZ="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
    case "$NVME_FSTYPE" in
        xfs)   mkfs.xfs -f -s "size=${SECTOR_SZ}" -b size=4096 -L "$FS_LABEL" "$TARGET_BLOCK_DEV" ;;
        btrfs) mkfs.btrfs -f -L "$FS_LABEL" "$TARGET_BLOCK_DEV"; btrfs device scan >/dev/null 2>&1 || true ;;
        *)     mkfs.ext4 -F -b 4096 -L "$FS_LABEL" "$TARGET_BLOCK_DEV" ;;
    esac
    udevadm settle
    EFFECTIVE_PRI_LABEL="$FS_LABEL"
    EFFECTIVE_PRI_SPEC="LABEL=${FS_LABEL}"
    log_ok "Formatted ${TARGET_BLOCK_DEV} as ${FSTYPE_UPPER} (label: ${FS_LABEL}, sector: ${SECTOR_SZ}B)"
fi

converge_fstab_entry() {
    rvdk_converge_fstab_entry "$@"
}

# 4. Persist Primary Volume in /etc/fstab & Mount
rvdk_prog 80 "NVMe 4Kn: persisting /etc/fstab & mounting ${MOUNT_POINT}..."
mkdir -p "$MOUNT_POINT"
case "$NVME_FSTYPE" in
    xfs)   FSTAB_ENTRY="${EFFECTIVE_PRI_SPEC}  ${MOUNT_POINT}  xfs  rw,noatime,nodiratime,attr2,inode64,logbsize=256k,noquota,nofail,x-systemd.device-timeout=15s  0  2" ;;
    btrfs) FSTAB_ENTRY="${EFFECTIVE_PRI_SPEC}  ${MOUNT_POINT}  btrfs  rw,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=15s  0  2" ;;
    *)     FSTAB_ENTRY="${EFFECTIVE_PRI_SPEC}  ${MOUNT_POINT}  ext4  rw,noatime,nodiratime,data=ordered,nofail,x-systemd.device-timeout=15s  0  2" ;;
esac

converge_fstab_entry "$EFFECTIVE_PRI_SPEC" "$MOUNT_POINT" "$NVME_FSTYPE" "$FSTAB_ENTRY"

if ! mountpoint -q "$MOUNT_POINT"; then
    mount "$MOUNT_POINT"
    log_ok "Mounted ${MOUNT_POINT} (${NVME_FSTYPE})"
else
    log_skip "${MOUNT_POINT} is already mounted"
fi

# 5. Optional Dual-LVM Secondary Elastic LV (${VG_NAME}/${SECONDARY_LV_NAME} -> Btrfs zstd:3)
if [[ "$WITH_SECONDARY_LV" == "true" && "$USE_LVM" == "true" ]]; then
    EXISTING_SEC_DEV="$(blkid -L "$SECONDARY_FS_LABEL" 2>/dev/null || true)"
    if [[ -z "$EXISTING_SEC_DEV" && "$FORCE_WIPE" == "false" ]]; then
        if mountpoint -q "$SECONDARY_MOUNT_POINT" 2>/dev/null; then
            _sec_src="$(findmnt -rn -o SOURCE -M "$SECONDARY_MOUNT_POINT" 2>/dev/null || true)"
            _sec_src="${_sec_src%%\[*}"
            if [[ -b "$_sec_src" ]] && rvdk_block_resides_on_disk "$_sec_src" "$NVME_DEV"; then
                EXISTING_SEC_DEV="$_sec_src"
            fi
        elif [[ -b "/dev/${VG_NAME}/${SECONDARY_LV_NAME}" ]] && rvdk_block_resides_on_disk "/dev/${VG_NAME}/${SECONDARY_LV_NAME}" "$NVME_DEV"; then
            _sec_lv_type="$(blkid -s TYPE -o value "/dev/${VG_NAME}/${SECONDARY_LV_NAME}" 2>/dev/null || true)"
            case "$_sec_lv_type" in
                xfs|ext4|btrfs) EXISTING_SEC_DEV="/dev/${VG_NAME}/${SECONDARY_LV_NAME}" ;;
            esac
        fi
    fi

    EXISTING_SEC_TYPE=""
    [[ -n "$EXISTING_SEC_DEV" ]] && EXISTING_SEC_TYPE="$(blkid -s TYPE -o value "$EXISTING_SEC_DEV" 2>/dev/null || true)"
    if [[ "$FORCE_WIPE" == "false" ]]; then
        case "$EXISTING_SEC_TYPE" in
            xfs|ext4|btrfs) SEC_FSTYPE="$EXISTING_SEC_TYPE" ;;
        esac
    fi

    EFFECTIVE_SEC_LABEL="$SECONDARY_FS_LABEL"
    EFFECTIVE_SEC_SPEC="LABEL=${SECONDARY_FS_LABEL}"
    if [[ -n "$EXISTING_SEC_DEV" && "$FORCE_WIPE" == "false" ]]; then
        _sec_lbl="$(blkid -s LABEL -o value "$EXISTING_SEC_DEV" 2>/dev/null || true)"
        _sec_uuid="$(blkid -s UUID -o value "$EXISTING_SEC_DEV" 2>/dev/null || true)"
        if [[ -n "$_sec_lbl" ]]; then
            EFFECTIVE_SEC_LABEL="$_sec_lbl"
            EFFECTIVE_SEC_SPEC="LABEL=${_sec_lbl}"
        elif [[ -n "$_sec_uuid" ]]; then
            EFFECTIVE_SEC_SPEC="UUID=${_sec_uuid}"
        fi
    fi

    SEC_UPPER="$(tr '[:lower:]' '[:upper:]' <<< "$SEC_FSTYPE")"
    rvdk_prog 90 "NVMe 4Kn: converging Dual-LVM secondary volume (${VG_NAME}/${SECONDARY_LV_NAME} -> ${SEC_UPPER})..."

    SEC_BLOCK_DEV=""
    if [[ -n "$EXISTING_SEC_DEV" && "$EXISTING_SEC_TYPE" == "$SEC_FSTYPE" && "$FORCE_WIPE" == "false" ]]; then
        SEC_BLOCK_DEV="$EXISTING_SEC_DEV"
        log_skip "Dual-LVM ${SEC_UPPER} volume '${EFFECTIVE_SEC_LABEL}' already converged at ${SEC_BLOCK_DEV}"
    elif [[ -b "/dev/${VG_NAME}/${SECONDARY_LV_NAME}" ]] \
         && rvdk_block_resides_on_disk "/dev/${VG_NAME}/${SECONDARY_LV_NAME}" "$NVME_DEV" \
         && { [[ "$FORCE_WIPE" == "true" ]] || [[ -z "$(blkid -s TYPE -o value "/dev/${VG_NAME}/${SECONDARY_LV_NAME}" 2>/dev/null || true)" ]]; }; then
        SEC_BLOCK_DEV="/dev/${VG_NAME}/${SECONDARY_LV_NAME}"
        _nvme_ensure_unmounted "$SEC_BLOCK_DEV" "$SECONDARY_MOUNT_POINT"
        wipefs -af "$SEC_BLOCK_DEV" >/dev/null
        if [[ "$SEC_FSTYPE" == "btrfs" ]]; then
            mkfs.btrfs -f -L "$SECONDARY_FS_LABEL" "$SEC_BLOCK_DEV"
            btrfs device scan >/dev/null 2>&1 || true
        elif [[ "$SEC_FSTYPE" == "xfs" ]]; then
            SECTOR_SZ="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
            mkfs.xfs -f -s "size=${SECTOR_SZ}" -b size=4096 -L "$SECONDARY_FS_LABEL" "$SEC_BLOCK_DEV"
        else
            mkfs.ext4 -F -b 4096 -L "$SECONDARY_FS_LABEL" "$SEC_BLOCK_DEV"
        fi
        udevadm settle
        EFFECTIVE_SEC_LABEL="$SECONDARY_FS_LABEL"
        EFFECTIVE_SEC_SPEC="LABEL=${SECONDARY_FS_LABEL}"
        log_ok "Formatted existing LV ${SEC_BLOCK_DEV} as ${SEC_UPPER} (${SECONDARY_FS_LABEL})"
    elif vgs "$VG_NAME" >/dev/null 2>&1; then
        VG_TOTAL_EXT="$(vgs --noheadings --nosuffix -o vg_extent_count "$VG_NAME" 2>/dev/null | tr -dc '0-9' || echo 0)"
        VG_FREE_EXT="$(vgs --noheadings --nosuffix -o vg_free_count "$VG_NAME" 2>/dev/null | tr -dc '0-9' || echo 0)"
        WANT_PCT_NUM="${DUAL_SECONDARY_PCT%%%*}"
        [[ "$WANT_PCT_NUM" =~ ^[0-9]+$ ]] || WANT_PCT_NUM=30
        WANT_EXT=$(( (VG_TOTAL_EXT * WANT_PCT_NUM) / 100 ))

        if (( VG_FREE_EXT >= WANT_EXT && WANT_EXT > 0 )); then
            lvcreate -l "$DUAL_SECONDARY_PCT" -n "$SECONDARY_LV_NAME" -y "$VG_NAME"
            SEC_BLOCK_DEV="/dev/${VG_NAME}/${SECONDARY_LV_NAME}"
            log_ok "Created Dual-LVM Logical Volume ${SEC_BLOCK_DEV} (${DUAL_SECONDARY_PCT}; elastic reserve retained in ${VG_NAME})"
        elif (( VG_FREE_EXT >= 64 )); then
            lvcreate -l "80%FREE" -n "$SECONDARY_LV_NAME" -y "$VG_NAME"
            SEC_BLOCK_DEV="/dev/${VG_NAME}/${SECONDARY_LV_NAME}"
            log_ok "Carved live Dual-LVM volume ${SEC_BLOCK_DEV} from free ${VG_NAME} extents (80%FREE)"
        else
            log_warn "Volume Group ${VG_NAME} has insufficient free extents (${VG_FREE_EXT}) for ${SECONDARY_LV_NAME}."
        fi

        if [[ -n "$SEC_BLOCK_DEV" ]]; then
            if [[ "$SEC_FSTYPE" == "btrfs" ]]; then
                mkfs.btrfs -f -L "$SECONDARY_FS_LABEL" "$SEC_BLOCK_DEV"
                btrfs device scan >/dev/null 2>&1 || true
            elif [[ "$SEC_FSTYPE" == "xfs" ]]; then
                SECTOR_SZ="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
                mkfs.xfs -f -s "size=${SECTOR_SZ}" -b size=4096 -L "$SECONDARY_FS_LABEL" "$SEC_BLOCK_DEV"
            else
                mkfs.ext4 -F -b 4096 -L "$SECONDARY_FS_LABEL" "$SEC_BLOCK_DEV"
            fi
            udevadm settle
            EFFECTIVE_SEC_LABEL="$SECONDARY_FS_LABEL"
            EFFECTIVE_SEC_SPEC="LABEL=${SECONDARY_FS_LABEL}"
            log_ok "Formatted ${SEC_BLOCK_DEV} as ${SEC_UPPER} (label: ${SECONDARY_FS_LABEL})"
        fi
    fi

    if [[ -n "$SEC_BLOCK_DEV" ]]; then
        mkdir -p "$SECONDARY_MOUNT_POINT"
        if [[ "$SEC_FSTYPE" == "btrfs" ]]; then
            FSTAB_SEC="${EFFECTIVE_SEC_SPEC}  ${SECONDARY_MOUNT_POINT}  btrfs  rw,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=15s  0  2"
        elif [[ "$SEC_FSTYPE" == "xfs" ]]; then
            FSTAB_SEC="${EFFECTIVE_SEC_SPEC}  ${SECONDARY_MOUNT_POINT}  xfs  rw,noatime,nodiratime,attr2,inode64,logbsize=256k,noquota,nofail,x-systemd.device-timeout=15s  0  2"
        else
            FSTAB_SEC="${EFFECTIVE_SEC_SPEC}  ${SECONDARY_MOUNT_POINT}  ext4  rw,noatime,nodiratime,data=ordered,nofail,x-systemd.device-timeout=15s  0  2"
        fi

        converge_fstab_entry "$EFFECTIVE_SEC_SPEC" "$SECONDARY_MOUNT_POINT" "$SEC_FSTYPE" "$FSTAB_SEC"

        if ! mountpoint -q "$SECONDARY_MOUNT_POINT"; then
            mount "$SECONDARY_MOUNT_POINT"
            chown "${REAL_USER}:${REAL_GRP}" "$SECONDARY_MOUNT_POINT"
            chmod 0775 "$SECONDARY_MOUNT_POINT"
            log_ok "Mounted Dual-LVM secondary volume at ${SECONDARY_MOUNT_POINT} (${SEC_FSTYPE})"
        else
            log_skip "${SECONDARY_MOUNT_POINT} is already mounted"
        fi
    fi
fi

if vgs "$VG_NAME" >/dev/null 2>&1; then
    VG_SUMMARY="$(vgs --noheadings -o vg_free,vg_size "$VG_NAME" 2>/dev/null | awk '{print $1 " free of " $2}' || true)"
    [[ -n "$VG_SUMMARY" ]] && log_info "LVM Elastic Pool (${VG_NAME}): ${VG_SUMMARY}"
fi

rvdk_prog 100 "NVMe 4Kn storage converged (${MOUNT_POINT})"
