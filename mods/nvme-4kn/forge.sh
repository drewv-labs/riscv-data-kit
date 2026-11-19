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
Usage: sudo rvdk mods/nvme-4kn [options]

Options:
  --device <dev>            Target NVMe namespace (default: /dev/nvme0n1)
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
  --secondary-label <label> Secondary filesystem label (default: RVDK_SECONDARY)
  --primary-pct <pct>       Dual-LV primary allocation (default: 45%VG)
  --secondary-pct <pct>     Dual-LV secondary allocation (default: 30%VG)
  --no-lvm                  Use raw GPT partition instead of LVM2
  --force-wipe              Permit wiping pre-existing non-OS filesystems on --device
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

NVME_DEV="${NVME_DEV:-/dev/nvme0n1}"
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

_require_arg() {
    [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."
    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)                               _require_arg "$1" "${2:-}"; NVME_DEV="$2"; shift 2 ;;
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
        --no-apt-update|--skip-apt-update)      export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)               export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)                              usage; exit 0 ;;
        *)                                      log_fatal "Unknown argument: $1 (try --help)" ;;
    esac
done

if [[ "$WITH_NFS_LV" == "true" ]]; then
    SECONDARY_LV_NAME="${CLI_SEC_LV:-${NFS_LV_NAME:-lv_nfsvault}}"
    SECONDARY_FS_LABEL="${CLI_SEC_LABEL:-${NFS_FS_LABEL:-NFS_VAULT}}"
    SECONDARY_MOUNT_POINT="${CLI_SEC_MOUNT:-${NFS_MOUNT_POINT:-/mnt/nfs_vault}}"
else
    SECONDARY_LV_NAME="${CLI_SEC_LV:-lv_secondary}"
    SECONDARY_FS_LABEL="${CLI_SEC_LABEL:-RVDK_SECONDARY}"
    SECONDARY_MOUNT_POINT="${CLI_SEC_MOUNT:-/mnt/nvme_secondary}"
fi

MOUNT_POINT="$(rvdk_normalize_mount_path "$MOUNT_POINT")"
SECONDARY_MOUNT_POINT="$(rvdk_normalize_mount_path "$SECONDARY_MOUNT_POINT")"

[[ -z "$MOUNT_POINT" || "$MOUNT_POINT" != /* || "$MOUNT_POINT" == "/" ]] && log_fatal "Invalid --mount '${MOUNT_POINT}'."
[[ -z "$SECONDARY_MOUNT_POINT" || "$SECONDARY_MOUNT_POINT" != /* || "$SECONDARY_MOUNT_POINT" == "/" ]] && log_fatal "Invalid --secondary-mount '${SECONDARY_MOUNT_POINT}'."
[[ "$FS_LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --label '${FS_LABEL}'."
[[ "$SECONDARY_FS_LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --secondary-label '${SECONDARY_FS_LABEL}'."
[[ "$VG_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --vg '${VG_NAME}'."
[[ "$LV_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --lv '${LV_NAME}'."
[[ "$SECONDARY_LV_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --secondary-lv '${SECONDARY_LV_NAME}'."

[[ ! -b "$NVME_DEV" ]] && log_fatal "NVMe block device not found: ${NVME_DEV}"
if rvdk_device_backs_os_or_swap "$NVME_DEV"; then
    log_fatal "Safety Interlock: ${NVME_DEV} backs a critical OS filesystem or active SWAP! Aborting."
fi

rvdk_prog_init "NVMe 4Kn: validating ${NVME_DEV}..."

REQ_PKGS=(nvme-cli lvm2 xfsprogs e2fsprogs parted util-linux)
if [[ "$PRIMARY_FSTYPE" == "btrfs" ]] || [[ "$WITH_SECONDARY_LV" == "true" && "$USE_LVM" == "true" ]]; then
    REQ_PKGS+=(btrfs-progs)
fi
rvdk_prog 15 "NVMe 4Kn: verifying storage prerequisites..."
rvdk_apt_ensure "${REQ_PKGS[@]}"

PRIMARY_FSTYPE="$(tr '[:upper:]' '[:lower:]' <<< "$PRIMARY_FSTYPE")"
case "$PRIMARY_FSTYPE" in
    auto)
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

if [[ "$WITH_SECONDARY_LV" == "true" ]]; then
    EXISTING_SEC_PRE="$(blkid -L "$SECONDARY_FS_LABEL" 2>/dev/null || true)"
    if [[ -n "$EXISTING_SEC_PRE" ]] && ! rvdk_block_resides_on_disk "$EXISTING_SEC_PRE" "$NVME_DEV"; then
        log_fatal "Cross-Disk Safety Interlock: secondary label '${SECONDARY_FS_LABEL}' already exists on '${EXISTING_SEC_PRE}', which does NOT reside on '${NVME_DEV}'. Pass a unique --secondary-label <name>."
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

# If existing volume is NOT already converged, enforce non-destructive storage guard before wiping
if [[ -z "$EXISTING_FS_DEV" || "$EXISTING_FS_TYPE" != "$NVME_FSTYPE" || "$FORCE_WIPE" == "true" ]]; then
    rvdk_assert_device_safe_to_wipe "$NVME_DEV" "$FORCE_WIPE" "${FS_LABEL},${SECONDARY_FS_LABEL},RVDK_NVME,RVDK_SECONDARY,NFS_VAULT"
fi

# 2. Verify or Convert to Native 4096-Byte (4Kn) Hardware LBA Sectors (ms:0 ONLY)
rvdk_prog 35 "NVMe 4Kn: checking 4096B LBA sector geometry..."
CUR_LBA="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
if [[ -n "$EXISTING_FS_DEV" && "$CUR_LBA" == "4096" && "$FORCE_WIPE" == "false" ]]; then
    log_skip "Existing 4Kn volume '${FS_LABEL}' found on ${EXISTING_FS_DEV} (4096B sectors)"
else
    if [[ "$CUR_LBA" != "4096" || "$FORCE_WIPE" == "true" ]]; then
        umount -f "$MOUNT_POINT" 2>/dev/null || true
        umount -f "$SECONDARY_MOUNT_POINT" 2>/dev/null || true
        vgchange -an "$VG_NAME" 2>/dev/null || true

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
    log_skip "${FSTYPE_UPPER} volume '${FS_LABEL}' already converged at ${TARGET_BLOCK_DEV}"
else
    umount -f "$MOUNT_POINT" 2>/dev/null || true

    if [[ "$USE_LVM" == "true" && -b "/dev/${VG_NAME}/${LV_NAME}" && "$FORCE_WIPE" == "false" ]] && rvdk_block_resides_on_disk "/dev/${VG_NAME}/${LV_NAME}" "$NVME_DEV"; then
        TARGET_BLOCK_DEV="/dev/${VG_NAME}/${LV_NAME}"
        log_warn "Formatting existing LVM volume ${TARGET_BLOCK_DEV} as ${NVME_FSTYPE}..."
        wipefs -af "$TARGET_BLOCK_DEV" >/dev/null 2>&1 || true
    elif [[ "$USE_LVM" == "true" ]]; then
        umount -f "$SECONDARY_MOUNT_POINT" 2>/dev/null || true
        log_info "Building LVM Volume Group (${VG_NAME}/${LV_NAME} @ ${EFFECTIVE_PRI_PCT}) on ${NVME_DEV}..."
        if vgs "$VG_NAME" >/dev/null 2>&1; then
            vgremove -ff -y "$VG_NAME" 2>/dev/null || true
        fi
        pvremove -ff -y "$NVME_DEV" 2>/dev/null || true
        for p in "${NVME_DEV}"p*; do [[ -b "$p" ]] && wipefs -af "$p" >/dev/null 2>&1 || true; done
        wipefs -af "$NVME_DEV"
        partprobe "$NVME_DEV" 2>/dev/null || true

        pvcreate --dataalignment 4m -f -y "$NVME_DEV"
        vgcreate -s 4m "$VG_NAME" "$NVME_DEV"
        lvcreate -l "$EFFECTIVE_PRI_PCT" -n "$LV_NAME" -y "$VG_NAME"
        TARGET_BLOCK_DEV="/dev/${VG_NAME}/${LV_NAME}"
        log_ok "Created LVM Logical Volume ${TARGET_BLOCK_DEV} (${EFFECTIVE_PRI_PCT})"
    else
        log_info "Creating GPT partition layout on ${NVME_DEV}..."
        for p in "${NVME_DEV}"p*; do [[ -b "$p" ]] && wipefs -af "$p" >/dev/null 2>&1 || true; done
        wipefs -af "$NVME_DEV"
        parted -s "$NVME_DEV" mklabel gpt
        parted -s -a optimal "$NVME_DEV" mkpart primary "$NVME_FSTYPE" 1MiB 100%
        partprobe "$NVME_DEV" 2>/dev/null || true
        udevadm settle && sleep 2
        TARGET_BLOCK_DEV="${NVME_DEV}p1"
    fi

    rvdk_prog 70 "NVMe 4Kn: mkfs.${NVME_FSTYPE} (${FS_LABEL})..."
    SECTOR_SZ="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
    case "$NVME_FSTYPE" in
        xfs)   mkfs.xfs -f -s "size=${SECTOR_SZ}" -b size=4096 -L "$FS_LABEL" "$TARGET_BLOCK_DEV" ;;
        btrfs) mkfs.btrfs -f -L "$FS_LABEL" "$TARGET_BLOCK_DEV"; btrfs device scan >/dev/null 2>&1 || true ;;
        *)     mkfs.ext4 -F -b 4096 -L "$FS_LABEL" "$TARGET_BLOCK_DEV" ;;
    esac
    udevadm settle
    log_ok "Formatted ${TARGET_BLOCK_DEV} as ${FSTYPE_UPPER} (label: ${FS_LABEL}, sector: ${SECTOR_SZ}B)"
fi

converge_fstab_entry() {
    local label="$1"
    local mnt="$2"
    local fstype="$3"
    local entry="$4"
    local cur_fstab="" want_fstab=""

    [[ -f /etc/fstab ]] && cur_fstab="$(cat /etc/fstab)"
    want_fstab="$(awk -v lbl="LABEL=${label}" -v mp="$mnt" -v line="$entry" '
        /^[[:space:]]*#/ || NF < 2 { print; next }
        {
            m = $2
            while (length(m) > 1 && substr(m, length(m), 1) == "/") {
                m = substr(m, 1, length(m) - 1)
            }
            if ($1 == lbl || m == mp) next
            print
        }
        END { print line }
    ' <<< "$cur_fstab")"

    if [[ -f /etc/fstab ]] && printf '%s\n' "$want_fstab" | cmp -s - /etc/fstab 2>/dev/null; then
        log_skip "${mnt} (${fstype}) already in /etc/fstab"
    else
        printf '%s\n' "$want_fstab" | rvdk_atomic_write /etc/fstab 0644
        systemctl daemon-reload
        log_ok "Persisted ${label} -> ${mnt} (${fstype}) in /etc/fstab"
    fi
}

# 4. Persist Primary Volume in /etc/fstab & Mount
rvdk_prog 80 "NVMe 4Kn: persisting /etc/fstab & mounting ${MOUNT_POINT}..."
mkdir -p "$MOUNT_POINT"
case "$NVME_FSTYPE" in
    xfs)   FSTAB_ENTRY="LABEL=${FS_LABEL}  ${MOUNT_POINT}  xfs  rw,noatime,nodiratime,attr2,inode64,logbsize=256k,noquota,nofail,x-systemd.device-timeout=15s  0  2" ;;
    btrfs) FSTAB_ENTRY="LABEL=${FS_LABEL}  ${MOUNT_POINT}  btrfs  rw,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=15s  0  2" ;;
    *)     FSTAB_ENTRY="LABEL=${FS_LABEL}  ${MOUNT_POINT}  ext4  rw,noatime,nodiratime,data=ordered,nofail,x-systemd.device-timeout=15s  0  2" ;;
esac

converge_fstab_entry "$FS_LABEL" "$MOUNT_POINT" "$NVME_FSTYPE" "$FSTAB_ENTRY"

if ! mountpoint -q "$MOUNT_POINT"; then
    mount "$MOUNT_POINT"
    log_ok "Mounted ${MOUNT_POINT} (${NVME_FSTYPE})"
else
    log_skip "${MOUNT_POINT} is already mounted"
fi

# 5. Optional Dual-LVM Secondary Elastic LV (${VG_NAME}/${SECONDARY_LV_NAME} -> Btrfs zstd:3)
if [[ "$WITH_SECONDARY_LV" == "true" && "$USE_LVM" == "true" ]]; then
    SEC_UPPER="$(tr '[:lower:]' '[:upper:]' <<< "$SEC_FSTYPE")"
    rvdk_prog 90 "NVMe 4Kn: converging Dual-LVM secondary volume (${VG_NAME}/${SECONDARY_LV_NAME} -> ${SEC_UPPER})..."
    EXISTING_SEC_DEV="$(blkid -L "$SECONDARY_FS_LABEL" 2>/dev/null || true)"
    EXISTING_SEC_TYPE=""
    [[ -n "$EXISTING_SEC_DEV" ]] && EXISTING_SEC_TYPE="$(blkid -s TYPE -o value "$EXISTING_SEC_DEV" 2>/dev/null || true)"

    SEC_BLOCK_DEV=""
    if [[ -n "$EXISTING_SEC_DEV" && "$EXISTING_SEC_TYPE" == "$SEC_FSTYPE" && "$FORCE_WIPE" == "false" ]]; then
        SEC_BLOCK_DEV="$EXISTING_SEC_DEV"
        log_skip "Dual-LVM ${SEC_UPPER} volume '${SECONDARY_FS_LABEL}' already converged at ${SEC_BLOCK_DEV}"
    elif [[ -b "/dev/${VG_NAME}/${SECONDARY_LV_NAME}" ]] && rvdk_block_resides_on_disk "/dev/${VG_NAME}/${SECONDARY_LV_NAME}" "$NVME_DEV"; then
        umount -f "$SECONDARY_MOUNT_POINT" 2>/dev/null || true
        SEC_BLOCK_DEV="/dev/${VG_NAME}/${SECONDARY_LV_NAME}"
        wipefs -af "$SEC_BLOCK_DEV" >/dev/null 2>&1 || true
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
            log_ok "Formatted ${SEC_BLOCK_DEV} as ${SEC_UPPER} (label: ${SECONDARY_FS_LABEL})"
        fi
    fi

    if [[ -n "$SEC_BLOCK_DEV" ]]; then
        mkdir -p "$SECONDARY_MOUNT_POINT"
        if [[ "$SEC_FSTYPE" == "btrfs" ]]; then
            FSTAB_SEC="LABEL=${SECONDARY_FS_LABEL}  ${SECONDARY_MOUNT_POINT}  btrfs  rw,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=15s  0  2"
        elif [[ "$SEC_FSTYPE" == "xfs" ]]; then
            FSTAB_SEC="LABEL=${SECONDARY_FS_LABEL}  ${SECONDARY_MOUNT_POINT}  xfs  rw,noatime,nodiratime,attr2,inode64,logbsize=256k,noquota,nofail,x-systemd.device-timeout=15s  0  2"
        else
            FSTAB_SEC="LABEL=${SECONDARY_FS_LABEL}  ${SECONDARY_MOUNT_POINT}  ext4  rw,noatime,nodiratime,data=ordered,nofail,x-systemd.device-timeout=15s  0  2"
        fi

        converge_fstab_entry "$SECONDARY_FS_LABEL" "$SECONDARY_MOUNT_POINT" "$SEC_FSTYPE" "$FSTAB_SEC"

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
