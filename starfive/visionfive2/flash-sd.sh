#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // StarFive VisionFive 2 (JH7110) SD/eMMC Image Flasher
# Path: drewv-labs/riscv-data-kit/starfive/visionfive2/flash-sd.sh
# Description: Validates target removable media, unmounts active partitions,
#              and flashes a raw (.img) or compressed (.bz2/.xz/.gz/.zst)
#              StarFive JH7110 OS image to the raw block device (/dev/rdiskX
#              on macOS or /dev/sdX on Linux) with hardware safety guards.
#
# Usage (Shorthand macOS):
#   diskutil list external physical
#   export VF2IMG="/path/to/starfive-jh7110-VF2-SD.img"
#   ./starfive/visionfive2/flash-sd.sh 4
#
# Usage (Explicit Flags - macOS or Linux):
#   ./starfive/visionfive2/flash-sd.sh --device 4 --image /path/to/image.img.bz2
#   ./starfive/visionfive2/flash-sd.sh --device /dev/sdX --image /path/to/image.img
# ==============================================================================

set -Eeuo pipefail

log_info()  { printf "\033[1;36m[INFO]\033[0m %s\n" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

TARGET_ARG=""
IMAGE_PATH="${VF2IMG:-}"
FORCE_LARGE_DISK="false"
SKIP_CONFIRM="false"
MAX_SAFE_BYTES=$((256 * 1024 * 1024 * 1024)) # 256 GiB guard against wiping backup drives

usage() {
    cat << 'EOF'
Usage:
  export VF2IMG="/path/to/starfive-jh7110-VF2-SD.img"
  ./flash-sd.sh <disk_number_or_path> [image_path]

  ./flash-sd.sh --device <N|/dev/diskN|/dev/sdX> --image </path/to/image.img[.bz2|.xz|.gz|.zst]> [--yes] [--force]
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device) TARGET_ARG="${2:-}"; shift 2 ;;
        -i|--image)  IMAGE_PATH="${2:-}"; shift 2 ;;
        -y|--yes)    SKIP_CONFIRM="true"; shift ;;
        --force)     FORCE_LARGE_DISK="true"; shift ;;
        -h|--help)   usage ;;
        -*)          log_fatal "Unknown flag: $1" ;;
        *)
            if [[ -z "$TARGET_ARG" ]]; then
                TARGET_ARG="$1"
            elif [[ -z "$IMAGE_PATH" ]]; then
                IMAGE_PATH="$1"
            else
                log_fatal "Unexpected positional argument: $1"
            fi
            shift
            ;;
    esac
done

# Expand leading tilde if present
IMAGE_PATH="${IMAGE_PATH/#\~/$HOME}"

[[ -z "$TARGET_ARG" ]] && log_fatal "Missing target disk identifier. Run 'diskutil list external physical' and pass the disk number (e.g., 4)."
[[ -z "$IMAGE_PATH" ]] && log_fatal "Missing image path. Export VF2IMG=/path/to/image.img or pass --image /path/to/image.img."
[[ ! -f "$IMAGE_PATH" ]] && log_fatal "Image file not found: $IMAGE_PATH"

OS_TYPE="$(uname -s)"

# ==============================================================================
# 1. PLATFORM-SPECIFIC DEVICE RESOLUTION & HARDWARE SAFETY INTERLOCKS
# ==============================================================================
if [[ "$OS_TYPE" == "Darwin" ]]; then
    # Normalize "4", "disk4", "/dev/disk4", or "/dev/rdisk4" -> DISK_NUM="4"
    if [[ "$TARGET_ARG" =~ ^(/dev/r?disk|r?disk)?([0-9]+)$ ]]; then
        DISK_NUM="${BASH_REMATCH[2]}"
    else
        log_fatal "Invalid macOS disk identifier '$TARGET_ARG' (expected disk number like '4' or '/dev/disk4')."
    fi

    if (( DISK_NUM == 0 || DISK_NUM == 1 )); then
        log_fatal "Disk ${DISK_NUM} (/dev/disk${DISK_NUM}) is reserved for macOS internal system storage. Aborting!"
    fi

    BLOCK_DEV="/dev/disk${DISK_NUM}"
    RAW_DEV="/dev/rdisk${DISK_NUM}"

    DISK_INFO="$(diskutil info "$BLOCK_DEV" 2>/dev/null || true)"
    [[ -z "$DISK_INFO" ]] && log_fatal "Device $BLOCK_DEV does not exist. Check 'diskutil list external physical'."

    IS_INTERNAL="$(awk -F': *' '/Device Location:/ {print $2}' <<< "$DISK_INFO" | xargs)"
    IS_REMOVABLE="$(awk -F': *' '/Removable Media:/ {print $2}' <<< "$DISK_INFO" | xargs)"
    MEDIA_NAME="$(awk -F': *' '/Device \/ Media Name:/ {print $2}' <<< "$DISK_INFO" | xargs)"
    DISK_SIZE_LINE="$(awk -F': *' '/Disk Size:/ {print $2}' <<< "$DISK_INFO" | xargs)"
    DISK_BYTES="$(grep -oE '\([0-9]+ Bytes\)' <<< "$DISK_SIZE_LINE" | tr -dc '0-9' || echo 0)"

    if [[ "$IS_INTERNAL" == "Internal" && "$IS_REMOVABLE" != "Removable" ]]; then
        log_fatal "Safety Interlock: $BLOCK_DEV ($MEDIA_NAME) is marked as an INTERNAL non-removable drive! Aborting."
    fi

    if (( DISK_BYTES > MAX_SAFE_BYTES )) && [[ "$FORCE_LARGE_DISK" != "true" ]]; then
        log_fatal "Safety Interlock: $BLOCK_DEV ($MEDIA_NAME) is larger than 256 GiB ($DISK_SIZE_LINE). Pass --force if this is intentional."
    fi

    log_info "Target macOS Media : ${BLOCK_DEV} -> ${RAW_DEV} (${MEDIA_NAME} | ${DISK_SIZE_LINE})"
else
    # Linux workstation support (e.g., BabbageBox-RTX)
    if [[ "$TARGET_ARG" =~ ^[0-9]+$ ]]; then
        log_fatal "On Linux, specify the full block device path (e.g., --device /dev/sdX or /dev/mmcblkX)."
    fi
    BLOCK_DEV="$TARGET_ARG"
    RAW_DEV="$TARGET_ARG"

    [[ ! -b "$BLOCK_DEV" ]] && log_fatal "Block device not found: $BLOCK_DEV"

    if lsblk -no MOUNTPOINT "$BLOCK_DEV" 2>/dev/null | grep -qE "^(/|/boot|/boot/efi|/home)$"; then
        log_fatal "Safety Interlock: $BLOCK_DEV contains a critical system mountpoint! Aborting."
    fi

    DISK_BYTES="$(lsblk -b -dn -o SIZE "$BLOCK_DEV" 2>/dev/null | head -n1 | tr -dc '0-9' || echo 0)"
    MEDIA_NAME="$(lsblk -dn -o VENDOR,MODEL,SIZE "$BLOCK_DEV" 2>/dev/null | xargs)"

    if (( DISK_BYTES > MAX_SAFE_BYTES )) && [[ "$FORCE_LARGE_DISK" != "true" ]]; then
        log_fatal "Safety Interlock: $BLOCK_DEV ($MEDIA_NAME) exceeds 256 GiB. Pass --force if this is intentional."
    fi

    log_info "Target Linux Media : ${RAW_DEV} (${MEDIA_NAME})"
fi

log_info "Source OS Image    : ${IMAGE_PATH}"

if [[ "$SKIP_CONFIRM" != "true" ]]; then
    printf "\033[1;33m[CONFIRM]\033[0m Destroy all data on %s (%s) and flash image? [y/N]: " "$BLOCK_DEV" "$MEDIA_NAME"
    read -r reply
    [[ ! "$reply" =~ ^[Yy]$ ]] && log_fatal "Flash aborted by user."
fi

# ==============================================================================
# 2. UNMOUNT TARGET PARTITIONS
# ==============================================================================
if [[ "$OS_TYPE" == "Darwin" ]]; then
    log_info "Unmounting ${BLOCK_DEV} via diskutil..."
    diskutil unmountDisk "$BLOCK_DEV"
else
    log_info "Unmounting any active partitions on ${BLOCK_DEV}..."
    for part in "${BLOCK_DEV}"*; do
        umount "$part" 2>/dev/null || true
    done
fi

# ==============================================================================
# 3. FLASH IMAGE (RAW OR STREAM-DECOMPRESSED) & SYNC
# ==============================================================================
DD_BS="4m"
[[ "$OS_TYPE" != "Darwin" ]] && DD_BS="4M"

log_info "Flashing image to ${RAW_DEV} (bs=${DD_BS})..."
sudo -v

case "$IMAGE_PATH" in
    *.bz2)
        bzip2 -dc "$IMAGE_PATH" | sudo dd of="$RAW_DEV" bs="$DD_BS" status=progress
        ;;
    *.xz)
        xz -dc "$IMAGE_PATH" | sudo dd of="$RAW_DEV" bs="$DD_BS" status=progress
        ;;
    *.gz)
        gzip -dc "$IMAGE_PATH" | sudo dd of="$RAW_DEV" bs="$DD_BS" status=progress
        ;;
    *.zst)
        zstd -dc "$IMAGE_PATH" | sudo dd of="$RAW_DEV" bs="$DD_BS" status=progress
        ;;
    *)
        sudo dd if="$IMAGE_PATH" of="$RAW_DEV" bs="$DD_BS" status=progress
        ;;
esac

log_info "Flushing write buffers (sync)..."
sync

if [[ "$OS_TYPE" == "Darwin" ]]; then
    diskutil eject "$BLOCK_DEV"
    log_ok "Flashed and safely ejected ${BLOCK_DEV}. Card is ready for VisionFive 2!"
else
    sudo eject "$BLOCK_DEV" 2>/dev/null || true
    log_ok "Flashed and synced ${BLOCK_DEV}. Card is ready for VisionFive 2!"
fi
