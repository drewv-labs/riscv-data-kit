#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // SiFive HiFive Premier P550 (EIC7700X) Recovery USB Builder
# Path: drewv-labs/riscv-data-kit/sifive/hifive-premier-p550/flash-recovery-usb.sh
# Description: Validates removable USB media, resolves a custom (--image),
#              cached (~/.rvdk/cache/), or remote (rvdk.drewv-labs.dev) SiFive
#              P550 Ubuntu 24.04 image with SHA-256 verification, decompresses
#              to a staging payload, and builds a U-Boot compatible ext4
#              recovery stick (usb 0 -> mmc 0 es_fs write).
#
# Usage (Default RVDK Cache / Auto-Download):
#   diskutil list external physical
#   ./sifive/hifive-premier-p550/flash-recovery-usb.sh 4
#   ./sifive/hifive-premier-p550/flash-recovery-usb.sh --device /dev/sdX
#
# Usage (Custom Local Image Override):
#   ./sifive/hifive-premier-p550/flash-recovery-usb.sh 4 --image /path/to/custom.img.zst
#   ./sifive/hifive-premier-p550/flash-recovery-usb.sh --device /dev/sdX --image /path/to/custom.img
# ==============================================================================

set -Eeuo pipefail

log_info()  { printf "\033[1;36m[INFO]\033[0m %s\n" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

TARGET_ARG=""
IMAGE_PATH=""
FORCE_LARGE_DISK="false"
SKIP_CONFIRM="false"
MAX_SAFE_BYTES=$((256 * 1024 * 1024 * 1024)) # 256 GiB guard against wiping backup drives
MIN_USB_BYTES=$((8 * 1024 * 1024 * 1024))    # 8 GiB minimum for uncompressed .img

# Resolve invoking user's home directory even if script is called via sudo
REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
REAL_HOME="$(eval echo "~${REAL_USER}")"

DEFAULT_IMG_NAME="sifive-p550-ubuntu-24.04-preinstalled-server-riscv64.img.zst"
UBOOT_PAYLOAD_NAME="ubuntu-24.04-preinstalled-server-riscv64.img"
CACHE_DIR="${RVDK_CACHE_DIR:-${REAL_HOME}/.rvdk/cache}"
STAGE_DIR="${CACHE_DIR}/p550-usb-stage"
RVDK_MIRROR_URL="${RVDK_MIRROR_URL:-https://rvdk.drewv-labs.dev/releases/latest/download}"
UPSTREAM_FALLBACK_URL="https://github.com/sifiveinc/hifive-premier-p550-ubuntu/releases/download/2025.11.00/ubuntu-24.04-preinstalled-server-riscv64.img.xz"

usage() {
    cat << 'EOF'
Usage:
  ./flash-recovery-usb.sh <disk_number_or_path> [--image /path/to/img] [--yes] [--force]
  ./flash-recovery-usb.sh --device <N|/dev/diskN|/dev/sdX> [--image /path/to/img] [--yes] [--force]

Image Resolution Order:
  1. --image /path/to/img (if provided)
  2. ~/.rvdk/cache/sifive-p550-ubuntu-24.04-preinstalled-server-riscv64.img.zst
  3. https://rvdk.drewv-labs.dev/sifive-p550-ubuntu-24.04-preinstalled-server-riscv64.img.zst
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
            else
                log_fatal "Unexpected positional argument: $1 (use --image /path/to/img for custom images)"
            fi
            shift
            ;;
    esac
done

[[ -z "$TARGET_ARG" ]] && log_fatal "Missing target USB identifier. Run 'diskutil list external physical' (macOS) or 'lsblk' (Linux)."

# ==============================================================================
# 1. PLATFORM-SPECIFIC USB DEVICE RESOLUTION & HARDWARE SAFETY INTERLOCKS
# ==============================================================================
OS_TYPE="$(uname -s)"

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

    BREW_E2FS_PREFIX="$(brew --prefix e2fsprogs 2>/dev/null || true)"
    MKFS_EXT4="${BREW_E2FS_PREFIX}/sbin/mkfs.ext4"
    [[ ! -x "$MKFS_EXT4" ]] && log_fatal "macOS requires Homebrew e2fsprogs to build U-Boot ext4 media. Run: brew install e2fsprogs"

    log_info "Target macOS USB   : ${BLOCK_DEV} -> ${RAW_DEV} (${MEDIA_NAME} | ${DISK_SIZE_LINE})"
else
    # Linux workstation support (e.g., BabbageBox-RTX)
    if [[ "$TARGET_ARG" =~ ^[0-9]+$ ]]; then
        log_fatal "On Linux, specify the full block device path (e.g., --device /dev/sdX)."
    fi
    BLOCK_DEV="$TARGET_ARG"
    RAW_DEV="$TARGET_ARG"

    [[ ! -b "$BLOCK_DEV" ]] && log_fatal "Block device not found: $BLOCK_DEV"

    if lsblk -no MOUNTPOINT "$BLOCK_DEV" 2>/dev/null | grep -qE "^(/|/boot|/boot/efi|/home)$"; then
        log_fatal "Safety Interlock: $BLOCK_DEV contains a critical system mountpoint! Aborting."
    fi

    DISK_BYTES="$(lsblk -b -dn -o SIZE "$BLOCK_DEV" 2>/dev/null | head -n1 | tr -dc '0-9' || echo 0)"
    MEDIA_NAME="$(lsblk -dn -o VENDOR,MODEL,SIZE "$BLOCK_DEV" 2>/dev/null | xargs)"
    MKFS_EXT4="$(command -v mkfs.ext4 || echo /sbin/mkfs.ext4)"

    log_info "Target Linux USB   : ${RAW_DEV} (${MEDIA_NAME})"
fi

if (( DISK_BYTES < MIN_USB_BYTES )); then
    log_fatal "Target USB device ($MEDIA_NAME) is smaller than 8 GiB. Use a >= 16 GB USB flash drive."
fi

if (( DISK_BYTES > MAX_SAFE_BYTES )) && [[ "$FORCE_LARGE_DISK" != "true" ]]; then
    log_fatal "Safety Interlock: $BLOCK_DEV ($MEDIA_NAME) exceeds 256 GiB. Pass --force if this is intentional."
fi

# ==============================================================================
# 2. RESOLVE IMAGE (--image -> ~/.rvdk/cache/ -> https://rvdk.drewv-labs.dev/)
# ==============================================================================
if [[ -n "$IMAGE_PATH" ]]; then
    IMAGE_PATH="${IMAGE_PATH/#\~/$REAL_HOME}"
    [[ ! -f "$IMAGE_PATH" ]] && log_fatal "Custom image file not found: $IMAGE_PATH"
    log_info "Using custom image : ${IMAGE_PATH}"
else
    mkdir -p "$CACHE_DIR"
    IMAGE_PATH="${CACHE_DIR}/${DEFAULT_IMG_NAME}"
    SHA_PATH="${IMAGE_PATH}.sha256"
    REMOTE_IMG_URL="${RVDK_MIRROR_URL}/${DEFAULT_IMG_NAME}"

    if [[ -f "$IMAGE_PATH" ]]; then
        log_ok "Found cached RVDK image: ${IMAGE_PATH}"
    else
        log_info "No cached image at ${IMAGE_PATH}; pulling from ${REMOTE_IMG_URL}..."
        if curl -fL --retry 3 -C - "$REMOTE_IMG_URL" -o "${IMAGE_PATH}.part"; then
            mv -f "${IMAGE_PATH}.part" "$IMAGE_PATH"
            chown "${REAL_USER}" "$IMAGE_PATH" 2>/dev/null || true
            log_ok "Downloaded and cached ${IMAGE_PATH}"
        else
            log_warn "RVDK mirror unreachable; falling back to official SiFive GitHub Release..."
            IMAGE_PATH="${CACHE_DIR}/ubuntu-24.04-preinstalled-server-riscv64.img.xz"
            curl -fL --retry 3 -C - "$UPSTREAM_FALLBACK_URL" -o "${IMAGE_PATH}.part"
            mv -f "${IMAGE_PATH}.part" "$IMAGE_PATH"
            chown "${REAL_USER}" "$IMAGE_PATH" 2>/dev/null || true
            log_ok "Downloaded upstream ${IMAGE_PATH}"
        fi
    fi

    if [[ "$IMAGE_PATH" == *"${DEFAULT_IMG_NAME}" ]]; then
        if [[ ! -f "$SHA_PATH" ]]; then
            curl -fsSL "${REMOTE_IMG_URL}.sha256" -o "$SHA_PATH" 2>/dev/null || true
            chown "${REAL_USER}" "$SHA_PATH" 2>/dev/null || true
        fi

        if [[ -f "$SHA_PATH" ]]; then
            EXPECTED_SHA="$(awk '{print $1}' "$SHA_PATH")"
            if command -v shasum >/dev/null 2>&1; then
                ACTUAL_SHA="$(shasum -a 256 "$IMAGE_PATH" | awk '{print $1}')"
            else
                ACTUAL_SHA="$(sha256sum "$IMAGE_PATH" | awk '{print $1}')"
            fi
            if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
                rm -f "$IMAGE_PATH" "$SHA_PATH"
                log_fatal "SHA-256 mismatch on ${IMAGE_PATH}! Expected ${EXPECTED_SHA}, got ${ACTUAL_SHA}. Deleted corrupt cache file."
            fi
            log_ok "Verified SHA-256   : ${ACTUAL_SHA}"
        fi
    fi
fi

IMG_SIZE_BYTES="$(wc -c < "$IMAGE_PATH" | tr -dc '0-9')"
if (( IMG_SIZE_BYTES < 104857600 )); then
    log_fatal "Safety Interlock: ${IMAGE_PATH} is only ${IMG_SIZE_BYTES} bytes (< 100 MiB). Refusing to stage!"
fi

if [[ "$SKIP_CONFIRM" != "true" ]]; then
    printf "\033[1;33m[CONFIRM]\033[0m Format %s (%s) as ext4 and stage %s? [y/N]: " "$BLOCK_DEV" "$MEDIA_NAME" "$(basename "$IMAGE_PATH")"
    read -r reply
    [[ ! "$reply" =~ ^[Yy]$ ]] && log_fatal "Aborted by user."
fi

# ==============================================================================
# 3. DECOMPRESS PAYLOAD TO STAGING DIR (FOR U-BOOT es_fs write)
# ==============================================================================
mkdir -p "$STAGE_DIR"
STAGED_IMG="${STAGE_DIR}/${UBOOT_PAYLOAD_NAME}"

if [[ "$IMAGE_PATH" == "$STAGED_IMG" ]]; then
    log_info "Using existing uncompressed payload at ${STAGED_IMG}"
elif [[ -f "$STAGED_IMG" && "$STAGED_IMG" -nt "$IMAGE_PATH" ]]; then
    log_ok "Reusing already-decompressed staging payload: ${STAGED_IMG}"
else
    log_info "Decompressing U-Boot payload to ${STAGED_IMG}..."
    rm -f "${STAGE_DIR}"/*
    case "$IMAGE_PATH" in
        *.zst) zstd -dc "$IMAGE_PATH" > "$STAGED_IMG" ;;
        *.xz)  xz -dc "$IMAGE_PATH" > "$STAGED_IMG" ;;
        *.bz2) bzip2 -dc "$IMAGE_PATH" > "$STAGED_IMG" ;;
        *.gz)  gzip -dc "$IMAGE_PATH" > "$STAGED_IMG" ;;
        *)     cp -v "$IMAGE_PATH" "$STAGED_IMG" ;;
    esac
    chown -R "${REAL_USER}" "$STAGE_DIR" 2>/dev/null || true
    log_ok "Staged $(ls -lh "$STAGED_IMG" | awk '{print $5}') payload: ${STAGED_IMG}"
fi

# ==============================================================================
# 4. FORMAT EXT4 (U-BOOT COMPATIBLE) & POPULATE RECOVERY USB
# ==============================================================================
sudo -v

if [[ "$OS_TYPE" == "Darwin" ]]; then
    log_info "Unmounting ${BLOCK_DEV} and injecting ext4 recovery filesystem via e2fsprogs (-d)..."
    diskutil unmountDisk "$BLOCK_DEV"
    sudo "$MKFS_EXT4" -F -b 4096 -L P550_RECOVERY \
        -O ^metadata_csum_seed,^orphan_file \
        -d "$STAGE_DIR" \
        "$RAW_DEV"
    sync
    diskutil eject "$BLOCK_DEV"
else
    log_info "Unmounting ${BLOCK_DEV}, formatting ext4, and copying payload..."
    for part in "${BLOCK_DEV}"*; do
        sudo umount "$part" 2>/dev/null || true
    done
    sudo wipefs -a "$BLOCK_DEV"
    sudo "$MKFS_EXT4" -F -b 4096 -L P550_RECOVERY \
        -O ^metadata_csum_seed,^orphan_file \
        "$BLOCK_DEV"

    MNT_TMP="$(mktemp -d /tmp/p550_usb.XXXXXX)"
    sudo mount "$BLOCK_DEV" "$MNT_TMP"
    sudo cp -v "$STAGED_IMG" "${MNT_TMP}/${UBOOT_PAYLOAD_NAME}"
    sync
    sudo umount "$MNT_TMP"
    rmdir "$MNT_TMP"
    sudo eject "$BLOCK_DEV" 2>/dev/null || true
fi

log_ok "SiFive HiFive Premier P550 recovery USB is ready!"
cat << 'EOF'

======================================================================
 U-Boot eMMC Recovery Procedure (115200 8N1 on /dev/ttyUSB2):
   1. Unplug USB JBOD enclosures so recovery stick enumerates as usb 0
   2. Halt autoboot in U-Boot and run:
      => usb reset
      => ls usb 0
      => es_fs write usb 0 ubuntu-24.04-preinstalled-server-riscv64.img mmc 0
      => reset
======================================================================
EOF
