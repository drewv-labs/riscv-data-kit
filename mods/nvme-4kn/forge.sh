#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: NVMe 4Kn + LVM + XFS/ext4 Storage Provisioner
# Path: riscv-data-kit/storage/nvme-4kn/forge.sh
#
# Usage:
#   sudo rvdk storage/nvme-4kn [--device /dev/nvme0n1] [--mount /mnt/nvme_pgdata] [--force-wipe]
#   curl -fsSL https://rvdk.drewv-labs.dev/storage/nvme-4kn/forge.sh | sudo bash
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
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
NODE_ENV="${BRAKERRAK_NODE_ENV:-${REAL_HOME}/.brakerrak/node.env}"
# shellcheck disable=SC1090
[[ -f "$NODE_ENV" ]] && source "$NODE_ENV"

NVME_DEV="${NVME_DEV:-/dev/nvme0n1}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/nvme_pgdata}"
FS_LABEL="${FS_LABEL:-PGDATA_NVME}"
VG_NAME="${VG_NAME:-vg_braker}"
LV_NAME="${LV_NAME:-lv_pgdata}"
LV_PCT="${LV_PCT:-85%VG}"
USE_LVM="${USE_LVM:-true}"
FORCE_WIPE="${FORCE_WIPE_NVME:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)     NVME_DEV="${2:-}"; shift 2 ;;
        --mount)      MOUNT_POINT="${2:-}"; shift 2 ;;
        --label)      FS_LABEL="${2:-}"; shift 2 ;;
        --no-lvm)     USE_LVM="false"; shift ;;
        --force-wipe|--force-wipe-nvme) FORCE_WIPE="true"; shift ;;
        *) shift ;;
    esac
done

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

log_info()  { printf "\033[1;36m[RVDK:NVME]\033[0m %s\n" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

[[ ! -b "$NVME_DEV" ]] && log_fatal "NVMe block device not found: ${NVME_DEV}"

# Safety Interlock: Never touch an NVMe drive backing the root OS
if lsblk -no MOUNTPOINT "$NVME_DEV" 2>/dev/null | grep -qE "^(/|/boot|/boot/efi)$"; then
    log_fatal "Safety Interlock: ${NVME_DEV} backs the root/boot OS filesystem! Aborting."
fi

apt-get update -q
apt-get install "${APT_FLAGS[@]}" nvme-cli lvm2 xfsprogs e2fsprogs parted util-linux

# 1. Detect Kernel Filesystem Support (XFS preferred; automatic 4K ext4 fallback on stripped vendor kernels)
if modprobe xfs 2>/dev/null || grep -qw xfs /proc/filesystems; then
    NVME_FSTYPE="xfs"
else
    NVME_FSTYPE="ext4"
fi

NVME_SHORT="$(basename "$NVME_DEV")"
EXISTING_FS_DEV="$(blkid -L "$FS_LABEL" || true)"
EXISTING_FS_TYPE=""
[[ -n "$EXISTING_FS_DEV" ]] && EXISTING_FS_TYPE="$(blkid -s TYPE -o value "$EXISTING_FS_DEV" 2>/dev/null || true)"

# 2. Verify or Convert to Native 4096-Byte (4Kn) Hardware LBA Sectors
CUR_LBA="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
if [[ -n "$EXISTING_FS_DEV" && "$CUR_LBA" == "4096" && "$FORCE_WIPE" == "false" ]]; then
    log_skip "Existing 4Kn volume '${FS_LABEL}' found on ${EXISTING_FS_DEV} (4096B sectors)"
else
    if [[ "$CUR_LBA" != "4096" || "$FORCE_WIPE" == "true" ]]; then
        umount -f "$MOUNT_POINT" 2>/dev/null || true
        vgchange -an "$VG_NAME" 2>/dev/null || true

        LBA_4K_IDX="$(nvme id-ns "$NVME_DEV" 2>/dev/null | awk '/lbads:12/ {print $2}' | tr -dc '0-9' | head -n1 || true)"
        if [[ -n "$LBA_4K_IDX" && "$CUR_LBA" != "4096" ]]; then
            log_info "Formatting ${NVME_DEV} from ${CUR_LBA}B to 4096B (4Kn) sectors (LBA Format Index: ${LBA_4K_IDX})..."
            nvme format "$NVME_DEV" -l "$LBA_4K_IDX" --force
            partprobe "$NVME_DEV" 2>/dev/null || true
            udevadm settle
            sleep 2
            log_ok "${NVME_DEV} formatted to native 4096-byte sectors"
        else
            log_skip "${NVME_DEV} already at ${CUR_LBA}B sectors (or 4Kn LBA index not advertised)"
        fi
    fi
fi

# 3. Provision LVM (vg_braker/lv_pgdata with 15% snapshot reserve) & Format XFS/ext4
if [[ -n "$EXISTING_FS_DEV" && "$EXISTING_FS_TYPE" == "$NVME_FSTYPE" && "$FORCE_WIPE" == "false" ]]; then
    TARGET_BLOCK_DEV="$EXISTING_FS_DEV"
    log_skip "${NVME_FSTYPE^^} volume '${FS_LABEL}' already converged at ${TARGET_BLOCK_DEV}"
else
    umount -f "$MOUNT_POINT" 2>/dev/null || true

    if [[ -b "/dev/${VG_NAME}/${LV_NAME}" && "$FORCE_WIPE" == "false" ]]; then
        TARGET_BLOCK_DEV="/dev/${VG_NAME}/${LV_NAME}"
        log_warn "Reformatting existing LVM volume ${TARGET_BLOCK_DEV} to ${NVME_FSTYPE}..."
        wipefs -af "$TARGET_BLOCK_DEV" >/dev/null 2>&1 || true
    elif [[ "$USE_LVM" == "true" ]]; then
        log_info "Building LVM Volume Group (${VG_NAME}/${LV_NAME} @ ${LV_PCT}) on ${NVME_DEV}..."
        vgremove -ff -y "$VG_NAME" 2>/dev/null || true
        pvremove -ff -y "$NVME_DEV" 2>/dev/null || true
        for p in "${NVME_DEV}"p*; do [[ -b "$p" ]] && wipefs -af "$p" >/dev/null 2>&1 || true; done
        wipefs -af "$NVME_DEV"
        partprobe "$NVME_DEV" 2>/dev/null || true

        pvcreate --dataalignment 4m -f -y "$NVME_DEV"
        vgcreate -s 4m "$VG_NAME" "$NVME_DEV"
        lvcreate -l "$LV_PCT" -n "$LV_NAME" -y "$VG_NAME"
        TARGET_BLOCK_DEV="/dev/${VG_NAME}/${LV_NAME}"
        log_ok "Created LVM Logical Volume ${TARGET_BLOCK_DEV} (15% VG reserved for CoW snapshots)"
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

    SECTOR_SZ="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
    if [[ "$NVME_FSTYPE" == "xfs" ]]; then
        mkfs.xfs -f -s "size=${SECTOR_SZ}" -b size=4096 -L "$FS_LABEL" "$TARGET_BLOCK_DEV"
    else
        mkfs.ext4 -F -b 4096 -L "$FS_LABEL" "$TARGET_BLOCK_DEV"
    fi
    udevadm settle
    log_ok "Formatted ${TARGET_BLOCK_DEV} as ${NVME_FSTYPE^^} (label: ${FS_LABEL}, sector: ${SECTOR_SZ}B)"
fi

# 4. Persist in /etc/fstab (No inline discard; nofail protection) & Mount
mkdir -p "$MOUNT_POINT"
if [[ "$NVME_FSTYPE" == "xfs" ]]; then
    FSTAB_ENTRY="LABEL=${FS_LABEL}  ${MOUNT_POINT}  xfs  rw,noatime,nodiratime,attr2,inode64,logbsize=256k,noquota,nofail,x-systemd.device-timeout=15s  0  2"
else
    FSTAB_ENTRY="LABEL=${FS_LABEL}  ${MOUNT_POINT}  ext4  rw,noatime,nodiratime,data=ordered,nofail,x-systemd.device-timeout=15s  0  2"
fi

if ! grep -qE "^LABEL=${FS_LABEL}[[:space:]]+${MOUNT_POINT}[[:space:]]+${NVME_FSTYPE}[[:space:]]" /etc/fstab; then
    sed -i "\|LABEL=${FS_LABEL}|d" /etc/fstab 2>/dev/null || true
    sed -i "\|[[:space:]]${MOUNT_POINT}[[:space:]]|d" /etc/fstab 2>/dev/null || true
    echo "$FSTAB_ENTRY" >> /etc/fstab
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
