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
#       Secondary LV (30%VG) -> Btrfs zstd:3 at /mnt/nfs_vault (grow+shrink elastic)
#       Free Pool    (25%VG) -> Shared elastic VG reserve + CoW snapshots
#
# Safety Interlocks:
#   • Unconditionally refuses to touch any disk backing /, /boot*, /usr, /var, /home, or SWAP
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
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${_REPO_ROOT}/lib/common.sh"
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/apt.sh" ]]; then
    # shellcheck source=lib/apt.sh
    source "${_REPO_ROOT}/lib/apt.sh"
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/storage_guard.sh" ]]; then
    # shellcheck source=lib/storage_guard.sh
    source "${_REPO_ROOT}/lib/storage_guard.sh"
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]]; then
    # shellcheck source=lib/progbar.sh
    source "${_REPO_ROOT}/lib/progbar.sh"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_log_init "RVDK:NVME"
rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
rvdk_resolve_caller

rvdk_load_config_env \
    NVME_DEV MOUNT_POINT FS_LABEL VG_NAME LV_NAME LV_PCT PRIMARY_FSTYPE \
    WITH_SECONDARY_LV WITH_NFS_LV SECONDARY_LV_NAME NFS_LV_NAME \
    SECONDARY_FS_LABEL NFS_FS_LABEL SECONDARY_MOUNT_POINT NFS_MOUNT_POINT \
    DUAL_PRIMARY_PCT DUAL_PG_PCT DUAL_SECONDARY_PCT DUAL_NFS_PCT \
    USE_LVM FORCE_WIPE_NVME

NVME_DEV="${NVME_DEV:-/dev/nvme0n1}"
VG_NAME="${VG_NAME:-vg_rvdk}"
LV_PCT="${LV_PCT:-85%VG}"
PRIMARY_FSTYPE="${PRIMARY_FSTYPE:-auto}"

# Preserve idempotency on nodes already converged with legacy default names, while
# defaulting fresh standalone deployments to workload-neutral identifiers.
if [[ -z "${MOUNT_POINT:-}" ]]; then
    if mountpoint -q /mnt/nvme_pgdata 2>/dev/null || grep -qs '[[:space:]]/mnt/nvme_pgdata[[:space:]]' /etc/fstab; then
        MOUNT_POINT="/mnt/nvme_pgdata"
    else
        MOUNT_POINT="/mnt/nvme_data"
    fi
fi
if [[ -z "${FS_LABEL:-}" ]]; then
    if [[ -n "$(blkid -L PGDATA_NVME 2>/dev/null || true)" ]]; then
        FS_LABEL="PGDATA_NVME"
    else
        FS_LABEL="RVDK_NVME"
    fi
fi
if [[ -z "${LV_NAME:-}" ]]; then
    if [[ -b "/dev/${VG_NAME}/lv_pgdata" ]]; then
        LV_NAME="lv_pgdata"
    else
        LV_NAME="lv_data"
    fi
fi

WITH_SECONDARY_LV="${WITH_SECONDARY_LV:-${WITH_NFS_LV:-false}}"
SECONDARY_LV_NAME="${SECONDARY_LV_NAME:-${NFS_LV_NAME:-lv_nfsvault}}"
SECONDARY_FS_LABEL="${SECONDARY_FS_LABEL:-${NFS_FS_LABEL:-NFS_VAULT}}"
SECONDARY_MOUNT_POINT="${SECONDARY_MOUNT_POINT:-${NFS_MOUNT_POINT:-/mnt/nfs_vault}}"
DUAL_PRIMARY_PCT="${DUAL_PRIMARY_PCT:-${DUAL_PG_PCT:-45%VG}}"
DUAL_SECONDARY_PCT="${DUAL_SECONDARY_PCT:-${DUAL_NFS_PCT:-30%VG}}"

USE_LVM="${USE_LVM:-true}"
FORCE_WIPE="${FORCE_WIPE_NVME:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)                               NVME_DEV="${2:-}"; shift 2 ;;
        --mount)                                MOUNT_POINT="${2:-}"; shift 2 ;;
        --label)                                FS_LABEL="${2:-}"; shift 2 ;;
        --fs|--fstype)                          PRIMARY_FSTYPE="${2:-auto}"; shift 2 ;;
        --vg|--vg-name)                         VG_NAME="${2:-vg_rvdk}"; shift 2 ;;
        --lv|--lv-name)                         LV_NAME="${2:-lv_data}"; shift 2 ;;
        --pct|--lv-pct)                         LV_PCT="${2:-85%VG}"; shift 2 ;;
        --with-secondary-lv|--with-nfs-lv|--dual-lvm)
                                                WITH_SECONDARY_LV="true"; shift ;;
        --no-secondary-lv|--no-nfs-lv)          WITH_SECONDARY_LV="false"; shift ;;
        --secondary-mount|--nfs-mount)          SECONDARY_MOUNT_POINT="${2:-/mnt/nfs_vault}"; shift 2 ;;
        --secondary-lv|--nfs-lv)                SECONDARY_LV_NAME="${2:-lv_nfsvault}"; shift 2 ;;
        --secondary-label|--nfs-label)          SECONDARY_FS_LABEL="${2:-NFS_VAULT}"; shift 2 ;;
        --primary-pct|--pg-pct)                 DUAL_PRIMARY_PCT="${2:-45%VG}"; shift 2 ;;
        --secondary-pct|--nfs-pct)              DUAL_SECONDARY_PCT="${2:-30%VG}"; shift 2 ;;
        --no-lvm)                               USE_LVM="false"; shift ;;
        --force-wipe|--force-wipe-nvme)         FORCE_WIPE="true"; shift ;;
        --no-apt-update|--skip-apt-update)      export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)               export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)
            cat <<EOF
Usage: sudo rvdk mods/nvme-4kn [options]

Options:
  --device <dev>            Target NVMe namespace (default: /dev/nvme0n1)
  --mount <path>            Primary mountpoint (default: /mnt/nvme_data)
  --label <label>           Primary filesystem label (default: RVDK_NVME)
  --fs <auto|xfs|ext4|btrfs> Primary filesystem type (default: auto -> xfs, ext4 fallback)
  --vg <name>               LVM Volume Group name (default: vg_rvdk)
  --lv <name>               Primary Logical Volume name (default: lv_data)
  --with-secondary-lv       Provision secondary Btrfs elastic LV (--with-nfs-lv alias)
  --secondary-mount <path>  Secondary mountpoint (default: /mnt/nfs_vault)
  --secondary-lv <name>     Secondary LV name (default: lv_nfsvault)
  --primary-pct <pct>       Dual-LV primary allocation (default: 45%VG)
  --secondary-pct <pct>     Dual-LV secondary allocation (default: 30%VG)
  --no-lvm                  Use raw GPT partition instead of LVM2
  --force-wipe              Permit wiping pre-existing non-OS filesystems on --device
EOF
            exit 0
            ;;
        *) shift ;;
    esac
done

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

NVME_SHORT="$(basename "$NVME_DEV")"
EXISTING_FS_DEV="$(blkid -L "$FS_LABEL" 2>/dev/null || true)"
EXISTING_FS_TYPE=""
[[ -n "$EXISTING_FS_DEV" ]] && EXISTING_FS_TYPE="$(blkid -s TYPE -o value "$EXISTING_FS_DEV" 2>/dev/null || true)"

# If existing volume is NOT already converged, enforce non-destructive storage guard before wiping!
if [[ -z "$EXISTING_FS_DEV" || "$EXISTING_FS_TYPE" != "$NVME_FSTYPE" || "$FORCE_WIPE" == "true" ]]; then
    rvdk_assert_device_safe_to_wipe "$NVME_DEV" "$FORCE_WIPE" "${FS_LABEL},${SECONDARY_FS_LABEL},PGDATA_NVME,RVDK_NVME,NFS_VAULT"
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

    if [[ -b "/dev/${VG_NAME}/${LV_NAME}" && "$FORCE_WIPE" == "false" ]]; then
        TARGET_BLOCK_DEV="/dev/${VG_NAME}/${LV_NAME}"
        log_warn "Formatting existing LVM volume ${TARGET_BLOCK_DEV} as ${NVME_FSTYPE}..."
        wipefs -af "$TARGET_BLOCK_DEV" >/dev/null 2>&1 || true
    elif [[ "$USE_LVM" == "true" ]]; then
        umount -f "$SECONDARY_MOUNT_POINT" 2>/dev/null || true
        log_info "Building LVM Volume Group (${VG_NAME}/${LV_NAME} @ ${EFFECTIVE_PRI_PCT}) on ${NVME_DEV}..."
        vgremove -ff -y "$VG_NAME" 2>/dev/null || true
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

# 4. Persist Primary Volume in /etc/fstab & Mount
rvdk_prog 80 "NVMe 4Kn: persisting /etc/fstab & mounting ${MOUNT_POINT}..."
mkdir -p "$MOUNT_POINT"
case "$NVME_FSTYPE" in
    xfs)   FSTAB_ENTRY="LABEL=${FS_LABEL}  ${MOUNT_POINT}  xfs  rw,noatime,nodiratime,attr2,inode64,logbsize=256k,noquota,nofail,x-systemd.device-timeout=15s  0  2" ;;
    btrfs) FSTAB_ENTRY="LABEL=${FS_LABEL}  ${MOUNT_POINT}  btrfs  rw,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=15s  0  2" ;;
    *)     FSTAB_ENTRY="LABEL=${FS_LABEL}  ${MOUNT_POINT}  ext4  rw,noatime,nodiratime,data=ordered,nofail,x-systemd.device-timeout=15s  0  2" ;;
esac

if ! grep -qE "^LABEL=${FS_LABEL}[[:space:]]+${MOUNT_POINT}[[:space:]]+${NVME_FSTYPE}[[:space:]]" /etc/fstab; then
    sed -i "\|LABEL=${FS_LABEL}|d" /etc/fstab 2>/dev/null || true
    sed -i "\|[[:space:]]${MOUNT_POINT}[[:space:]]|d" /etc/fstab 2>/dev/null || true
    printf '%s\n' "$FSTAB_ENTRY" >> /etc/fstab
    systemctl daemon-reload
    log_ok "Persisted ${FS_LABEL} -> ${MOUNT_POINT} (${NVME_FSTYPE}) in /etc/fstab"
else
    log_skip "${MOUNT_POINT} (${NVME_FSTYPE}) already in /etc/fstab"
fi

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
    elif [[ -b "/dev/${VG_NAME}/${SECONDARY_LV_NAME}" ]]; then
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

        if ! grep -qE "^LABEL=${SECONDARY_FS_LABEL}[[:space:]]+${SECONDARY_MOUNT_POINT}[[:space:]]+${SEC_FSTYPE}[[:space:]]" /etc/fstab; then
            sed -i "\|LABEL=${SECONDARY_FS_LABEL}|d" /etc/fstab 2>/dev/null || true
            sed -i "\|[[:space:]]${SECONDARY_MOUNT_POINT}[[:space:]]|d" /etc/fstab 2>/dev/null || true
            printf '%s\n' "$FSTAB_SEC" >> /etc/fstab
            systemctl daemon-reload
            log_ok "Persisted ${SECONDARY_FS_LABEL} -> ${SECONDARY_MOUNT_POINT} (${SEC_FSTYPE}) in /etc/fstab"
        else
            log_skip "${SECONDARY_MOUNT_POINT} (${SEC_FSTYPE}) already in /etc/fstab"
        fi

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
