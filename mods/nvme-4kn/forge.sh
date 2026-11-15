#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: NVMe 4Kn + LVM (Single or Dual PG/NFS) Provisioner
# Path: riscv-data-kit/mods/nvme-4kn/forge.sh
#
# Layouts:
#   • Default (Single-LV):
#       lv_pgdata   (85%VG) -> 4Kn XFS/ext4 at /mnt/nvme_pgdata
#       Free Pool   (15%VG) -> CoW snapshot & growth reserve
#   • Dual-LV (--with-nfs-lv | WITH_NFS_LV=true):
#       lv_pgdata   (45%VG) -> 4Kn XFS/ext4 at /mnt/nvme_pgdata (ENOSPC-isolated PG18)
#       lv_nfsvault (30%VG) -> Btrfs zstd:3 at /mnt/nfs_vault   (grow+shrink elastic NFS)
#       Free Pool   (25%VG) -> Shared elastic VG reserve + CoW snapshots
#
# Usage:
#   sudo rvdk mods/nvme-4kn [--device /dev/nvme0n1] [--mount /mnt/nvme_pgdata] [--vg vg_rvdk] [--lv lv_pgdata] [--with-nfs-lv] [--nfs-mount /mnt/nfs_vault] [--force-wipe] [--no-apt-update] [--noprogbar]
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
ENV_FILE="${RVDK_ENV_FILE:-${REAL_HOME}/.rvdk/config.env}"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

NVME_DEV="${NVME_DEV:-/dev/nvme0n1}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/nvme_pgdata}"
FS_LABEL="${FS_LABEL:-PGDATA_NVME}"
VG_NAME="${VG_NAME:-vg_rvdk}"
LV_NAME="${LV_NAME:-lv_pgdata}"
LV_PCT="${LV_PCT:-85%VG}"

WITH_NFS_LV="${WITH_NFS_LV:-false}"
NFS_LV_NAME="${NFS_LV_NAME:-lv_nfsvault}"
NFS_FS_LABEL="${NFS_FS_LABEL:-NFS_VAULT}"
NFS_MOUNT_POINT="${NFS_MOUNT_POINT:-/mnt/nfs_vault}"
DUAL_PG_PCT="${DUAL_PG_PCT:-45%VG}"
DUAL_NFS_PCT="${DUAL_NFS_PCT:-30%VG}"

USE_LVM="${USE_LVM:-true}"
FORCE_WIPE="${FORCE_WIPE_NVME:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)                        NVME_DEV="${2:-}"; shift 2 ;;
        --mount)                         MOUNT_POINT="${2:-}"; shift 2 ;;
        --label)                         FS_LABEL="${2:-}"; shift 2 ;;
        --vg|--vg-name)                  VG_NAME="${2:-vg_rvdk}"; shift 2 ;;
        --lv|--lv-name)                  LV_NAME="${2:-lv_pgdata}"; shift 2 ;;
        --with-nfs-lv|--dual-lvm)        WITH_NFS_LV="true"; shift ;;
        --no-nfs-lv)                     WITH_NFS_LV="false"; shift ;;
        --nfs-mount)                     NFS_MOUNT_POINT="${2:-/mnt/nfs_vault}"; shift 2 ;;
        --nfs-lv)                        NFS_LV_NAME="${2:-lv_nfsvault}"; shift 2 ;;
        --nfs-label)                     NFS_FS_LABEL="${2:-NFS_VAULT}"; shift 2 ;;
        --pg-pct)                        DUAL_PG_PCT="${2:-45%VG}"; shift 2 ;;
        --nfs-pct)                       DUAL_NFS_PCT="${2:-30%VG}"; shift 2 ;;
        --no-lvm)                        USE_LVM="false"; shift ;;
        --force-wipe|--force-wipe-nvme)  FORCE_WIPE="true"; shift ;;
        --no-apt-update|--skip-apt-update) export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)        export RVDK_NO_PROGBAR="1"; shift ;;
        *) shift ;;
    esac
done

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

_PROGBAR_CANDIDATE="${RVDK_PROGBAR_LIB:-}"
[[ -z "$_PROGBAR_CANDIDATE" && -n "$_SCRIPT_DIR" && -f "${_SCRIPT_DIR}/../../lib/progbar.sh" ]] && _PROGBAR_CANDIDATE="${_SCRIPT_DIR}/../../lib/progbar.sh"
if [[ -n "$_PROGBAR_CANDIDATE" && -f "$_PROGBAR_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    source "$_PROGBAR_CANDIDATE"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

_APT_CANDIDATE="${RVDK_APT_LIB:-}"
[[ -z "$_APT_CANDIDATE" && -n "$_SCRIPT_DIR" && -f "${_SCRIPT_DIR}/../../lib/apt.sh" ]] && _APT_CANDIDATE="${_SCRIPT_DIR}/../../lib/apt.sh"
if [[ -n "$_APT_CANDIDATE" && -f "$_APT_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    source "$_APT_CANDIDATE"
else
    rvdk_apt_ensure() {
        local m=() p
        for p in "$@"; do dpkg-query -W -f='${Status}\n' "$p" 2>/dev/null | grep -qx "install ok installed" || m+=("$p"); done
        [[ ${#m[@]} -eq 0 ]] && return 0
        if [[ "${RVDK_NO_APT_UPDATE:-0}" != "1" ]] || ! compgen -G "/var/lib/apt/lists/*Packages*" >/dev/null 2>&1; then
            apt-get update -q
            export RVDK_NO_APT_UPDATE="1"
            [[ -n "${RVDK_APT_STAMP_FILE:-}" ]] && touch "$RVDK_APT_STAMP_FILE" 2>/dev/null || true
        fi
        apt-get install "${APT_FLAGS[@]}" "${m[@]}"
    }
fi

rvdk_prog_init "NVMe 4Kn: validating ${NVME_DEV}..."

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

REQ_PKGS=(nvme-cli lvm2 xfsprogs e2fsprogs parted util-linux)
if [[ "$WITH_NFS_LV" == "true" && "$USE_LVM" == "true" ]]; then
    REQ_PKGS+=(btrfs-progs)
fi
rvdk_prog 15 "NVMe 4Kn: verifying storage prerequisites..."
rvdk_apt_ensure "${REQ_PKGS[@]}"

# 1. Detect Kernel Filesystem Support
#    • PostgreSQL volume (`lv_pgdata`)  : XFS preferred (4Kn, logbsize=256k); ext4 fallback
#    • Dedicated NFS LV (`lv_nfsvault`) : Btrfs preferred (zstd:3, online grow+shrink); XFS/ext4 fallback
if modprobe xfs 2>/dev/null || grep -qw xfs /proc/filesystems; then
    NVME_FSTYPE="xfs"
else
    NVME_FSTYPE="ext4"
fi

if modprobe btrfs 2>/dev/null || grep -qw btrfs /proc/filesystems; then
    NFS_FSTYPE="btrfs"
else
    NFS_FSTYPE="$NVME_FSTYPE"
fi

NVME_SHORT="$(basename "$NVME_DEV")"
EXISTING_FS_DEV="$(blkid -L "$FS_LABEL" || true)"
EXISTING_FS_TYPE=""
[[ -n "$EXISTING_FS_DEV" ]] && EXISTING_FS_TYPE="$(blkid -s TYPE -o value "$EXISTING_FS_DEV" 2>/dev/null || true)"

# 2. Verify or Convert to Native 4096-Byte (4Kn) Hardware LBA Sectors
rvdk_prog 35 "NVMe 4Kn: checking 4096B LBA sector geometry..."
CUR_LBA="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
if [[ -n "$EXISTING_FS_DEV" && "$CUR_LBA" == "4096" && "$FORCE_WIPE" == "false" ]]; then
    log_skip "Existing 4Kn volume '${FS_LABEL}' found on ${EXISTING_FS_DEV} (4096B sectors)"
else
    if [[ "$CUR_LBA" != "4096" || "$FORCE_WIPE" == "true" ]]; then
        umount -f "$MOUNT_POINT" 2>/dev/null || true
        umount -f "$NFS_MOUNT_POINT" 2>/dev/null || true
        vgchange -an "$VG_NAME" 2>/dev/null || true

        LBA_4K_IDX="$(nvme id-ns "$NVME_DEV" 2>/dev/null | awk '/lbads:12/ {print $2}' | tr -dc '0-9' | head -n1 || true)"
        if [[ -n "$LBA_4K_IDX" && "$CUR_LBA" != "4096" ]]; then
            rvdk_prog 45 "NVMe 4Kn: formatting ${NVME_DEV} to 4096B LBA..."
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

# 3. Provision Primary PostgreSQL Volume (${VG_NAME}/${LV_NAME}) & Format XFS/ext4
EFFECTIVE_PG_PCT="$LV_PCT"
if [[ "$WITH_NFS_LV" == "true" && "$USE_LVM" == "true" ]]; then
    EFFECTIVE_PG_PCT="$DUAL_PG_PCT"
fi

rvdk_prog 55 "NVMe 4Kn: converging primary volume (${VG_NAME}/${LV_NAME}) & ${NVME_FSTYPE^^}..."
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
        umount -f "$NFS_MOUNT_POINT" 2>/dev/null || true
        log_info "Building LVM Volume Group (${VG_NAME}/${LV_NAME} @ ${EFFECTIVE_PG_PCT}) on ${NVME_DEV}..."
        vgremove -ff -y "$VG_NAME" 2>/dev/null || true
        pvremove -ff -y "$NVME_DEV" 2>/dev/null || true
        for p in "${NVME_DEV}"p*; do [[ -b "$p" ]] && wipefs -af "$p" >/dev/null 2>&1 || true; done
        wipefs -af "$NVME_DEV"
        partprobe "$NVME_DEV" 2>/dev/null || true

        pvcreate --dataalignment 4m -f -y "$NVME_DEV"
        vgcreate -s 4m "$VG_NAME" "$NVME_DEV"
        lvcreate -l "$EFFECTIVE_PG_PCT" -n "$LV_NAME" -y "$VG_NAME"
        TARGET_BLOCK_DEV="/dev/${VG_NAME}/${LV_NAME}"
        log_ok "Created LVM Logical Volume ${TARGET_BLOCK_DEV} (${EFFECTIVE_PG_PCT})"
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
    if [[ "$NVME_FSTYPE" == "xfs" ]]; then
        mkfs.xfs -f -s "size=${SECTOR_SZ}" -b size=4096 -L "$FS_LABEL" "$TARGET_BLOCK_DEV"
    else
        mkfs.ext4 -F -b 4096 -L "$FS_LABEL" "$TARGET_BLOCK_DEV"
    fi
    udevadm settle
    log_ok "Formatted ${TARGET_BLOCK_DEV} as ${NVME_FSTYPE^^} (label: ${FS_LABEL}, sector: ${SECTOR_SZ}B)"
fi

# 4. Persist Primary Volume in /etc/fstab & Mount
rvdk_prog 80 "NVMe 4Kn: persisting /etc/fstab & mounting ${MOUNT_POINT}..."
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

# 5. Optional Dual-LVM Dedicated NFS Vault (${VG_NAME}/${NFS_LV_NAME} -> Btrfs zstd:3)
if [[ "$WITH_NFS_LV" == "true" && "$USE_LVM" == "true" ]]; then
    rvdk_prog 90 "NVMe 4Kn: converging Dual-LVM NFS vault (${VG_NAME}/${NFS_LV_NAME} -> ${NFS_FSTYPE^^})..."
    EXISTING_NFS_DEV="$(blkid -L "$NFS_FS_LABEL" || true)"
    EXISTING_NFS_TYPE=""
    [[ -n "$EXISTING_NFS_DEV" ]] && EXISTING_NFS_TYPE="$(blkid -s TYPE -o value "$EXISTING_NFS_DEV" 2>/dev/null || true)"

    NFS_BLOCK_DEV=""
    if [[ -n "$EXISTING_NFS_DEV" && "$EXISTING_NFS_TYPE" == "$NFS_FSTYPE" && "$FORCE_WIPE" == "false" ]]; then
        NFS_BLOCK_DEV="$EXISTING_NFS_DEV"
        log_skip "Dual-LVM ${NFS_FSTYPE^^} vault '${NFS_FS_LABEL}' already converged at ${NFS_BLOCK_DEV}"
    elif [[ -b "/dev/${VG_NAME}/${NFS_LV_NAME}" ]]; then
        umount -f "$NFS_MOUNT_POINT" 2>/dev/null || true
        NFS_BLOCK_DEV="/dev/${VG_NAME}/${NFS_LV_NAME}"
        wipefs -af "$NFS_BLOCK_DEV" >/dev/null 2>&1 || true
        if [[ "$NFS_FSTYPE" == "btrfs" ]]; then
            mkfs.btrfs -f -L "$NFS_FS_LABEL" "$NFS_BLOCK_DEV"
            btrfs device scan >/dev/null 2>&1 || true
        elif [[ "$NFS_FSTYPE" == "xfs" ]]; then
            SECTOR_SZ="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
            mkfs.xfs -f -s "size=${SECTOR_SZ}" -b size=4096 -L "$NFS_FS_LABEL" "$NFS_BLOCK_DEV"
        else
            mkfs.ext4 -F -b 4096 -L "$NFS_FS_LABEL" "$NFS_BLOCK_DEV"
        fi
        udevadm settle
        log_ok "Formatted existing LV ${NFS_BLOCK_DEV} as ${NFS_FSTYPE^^} (${NFS_FS_LABEL})"
    elif vgs "$VG_NAME" >/dev/null 2>&1; then
        VG_TOTAL_EXT="$(vgs --noheadings --nosuffix -o vg_extent_count "$VG_NAME" 2>/dev/null | tr -dc '0-9' || echo 0)"
        VG_FREE_EXT="$(vgs --noheadings --nosuffix -o vg_free_count "$VG_NAME" 2>/dev/null | tr -dc '0-9' || echo 0)"
        WANT_PCT_NUM="${DUAL_NFS_PCT%%%*}"
        [[ "$WANT_PCT_NUM" =~ ^[0-9]+$ ]] || WANT_PCT_NUM=30
        WANT_EXT=$(( (VG_TOTAL_EXT * WANT_PCT_NUM) / 100 ))

        if (( VG_FREE_EXT >= WANT_EXT && WANT_EXT > 0 )); then
            lvcreate -l "$DUAL_NFS_PCT" -n "$NFS_LV_NAME" -y "$VG_NAME"
            NFS_BLOCK_DEV="/dev/${VG_NAME}/${NFS_LV_NAME}"
            log_ok "Created Dual-LVM NFS Logical Volume ${NFS_BLOCK_DEV} (${DUAL_NFS_PCT}; elastic reserve retained in ${VG_NAME})"
        elif (( VG_FREE_EXT >= 64 )); then
            # Live persona flip from an earlier 85%VG single-LV build: carve 80% of remaining free VG
            # without touching lv_pgdata, still keeping 20% of free space for CoW snapshots.
            lvcreate -l "80%FREE" -n "$NFS_LV_NAME" -y "$VG_NAME"
            NFS_BLOCK_DEV="/dev/${VG_NAME}/${NFS_LV_NAME}"
            log_ok "Carved live Dual-LVM NFS volume ${NFS_BLOCK_DEV} from free ${VG_NAME} extents (80%FREE; zero PG downtime)"
        else
            log_warn "Volume Group ${VG_NAME} has insufficient free extents (${VG_FREE_EXT}) for ${NFS_LV_NAME}; NFS will fall back to ${MOUNT_POINT}/nfs_vault unless --force-wipe is used."
        fi

        if [[ -n "$NFS_BLOCK_DEV" ]]; then
            if [[ "$NFS_FSTYPE" == "btrfs" ]]; then
                mkfs.btrfs -f -L "$NFS_FS_LABEL" "$NFS_BLOCK_DEV"
                btrfs device scan >/dev/null 2>&1 || true
            elif [[ "$NFS_FSTYPE" == "xfs" ]]; then
                SECTOR_SZ="$(cat "/sys/block/${NVME_SHORT}/queue/logical_block_size")"
                mkfs.xfs -f -s "size=${SECTOR_SZ}" -b size=4096 -L "$NFS_FS_LABEL" "$NFS_BLOCK_DEV"
            else
                mkfs.ext4 -F -b 4096 -L "$NFS_FS_LABEL" "$NFS_BLOCK_DEV"
            fi
            udevadm settle
            log_ok "Formatted ${NFS_BLOCK_DEV} as ${NFS_FSTYPE^^} (label: ${NFS_FS_LABEL})"
        fi
    fi

    if [[ -n "$NFS_BLOCK_DEV" ]]; then
        mkdir -p "$NFS_MOUNT_POINT"
        if [[ "$NFS_FSTYPE" == "btrfs" ]]; then
            FSTAB_NFS="LABEL=${NFS_FS_LABEL}  ${NFS_MOUNT_POINT}  btrfs  rw,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=15s  0  2"
        elif [[ "$NFS_FSTYPE" == "xfs" ]]; then
            FSTAB_NFS="LABEL=${NFS_FS_LABEL}  ${NFS_MOUNT_POINT}  xfs  rw,noatime,nodiratime,attr2,inode64,logbsize=256k,noquota,nofail,x-systemd.device-timeout=15s  0  2"
        else
            FSTAB_NFS="LABEL=${NFS_FS_LABEL}  ${NFS_MOUNT_POINT}  ext4  rw,noatime,nodiratime,data=ordered,nofail,x-systemd.device-timeout=15s  0  2"
        fi

        if ! grep -qE "^LABEL=${NFS_FS_LABEL}[[:space:]]+${NFS_MOUNT_POINT}[[:space:]]+${NFS_FSTYPE}[[:space:]]" /etc/fstab; then
            sed -i "\|LABEL=${NFS_FS_LABEL}|d" /etc/fstab 2>/dev/null || true
            sed -i "\|[[:space:]]${NFS_MOUNT_POINT}[[:space:]]|d" /etc/fstab 2>/dev/null || true
            echo "$FSTAB_NFS" >> /etc/fstab
            systemctl daemon-reload
            log_ok "Persisted ${NFS_FS_LABEL} -> ${NFS_MOUNT_POINT} (${NFS_FSTYPE}) in /etc/fstab"
        else
            log_skip "${NFS_MOUNT_POINT} (${NFS_FSTYPE}) already in /etc/fstab"
        fi

        if ! mountpoint -q "$NFS_MOUNT_POINT"; then
            mount "$NFS_MOUNT_POINT"
            chown "${REAL_USER}:${REAL_GRP}" "$NFS_MOUNT_POINT"
            chmod 0775 "$NFS_MOUNT_POINT"
            log_ok "Mounted Dual-LVM NFS vault at ${NFS_MOUNT_POINT} (${NFS_FSTYPE})"
        else
            log_skip "${NFS_MOUNT_POINT} is already mounted"
        fi
    fi
fi

if vgs "$VG_NAME" >/dev/null 2>&1; then
    VG_SUMMARY="$(vgs --noheadings -o vg_free,vg_size "$VG_NAME" 2>/dev/null | awk '{print $1 " free of " $2}' || true)"
    [[ -n "$VG_SUMMARY" ]] && log_info "LVM Elastic Pool (${VG_NAME}): ${VG_SUMMARY}"
fi

rvdk_prog 100 "NVMe 4Kn storage converged (${MOUNT_POINT})"
