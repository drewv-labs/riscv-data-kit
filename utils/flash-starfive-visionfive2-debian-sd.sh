#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // StarFive VisionFive 2 (JH7110) SD/eMMC Image Flasher
# Description: Validates target removable media, resolves a custom (--image),
#              cached (~/.rvdk/cache/), or remote (rvdk.drewv-labs.dev) StarFive
#              JH7110 OS image with SHA-256 verification, unmounts active
#              partitions, and flashes the raw block device (/dev/rdiskX on
#              macOS or /dev/sdX on Linux).
#
# Usage (Default RVDK Cache / Auto-Download):
#   diskutil list external physical
#   ./utils/flash-starfive-visionfive2-debian-sd.sh 4
#   ./utils/flash-starfive-visionfive2-debian-sd.sh --device /dev/sdX
#   curl -fsSL https://rvdk.drewv-labs.dev/utils/flash-starfive-visionfive2-debian-sd.sh | sudo zsh -s -- 4
#
# Usage (Custom Local Image Override):
#   ./utils/flash-starfive-visionfive2-debian-sd.sh 4 --image /path/to/custom.img.zst
#   ./utils/flash-starfive-visionfive2-debian-sd.sh --device 4 --image /path/to/custom.img
# ==============================================================================

# Ensure compatibility when invoked via `zsh` or `bash` (including `curl ... | sudo zsh -s -- ...`)
if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L ksh
    setopt PIPE_FAIL ERR_RETURN NO_UNSET
else
    set -Eeuo pipefail
fi

log_info()  { printf "\033[1;36m[INFO]\033[0m %s\n" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

TARGET_ARG=""
IMAGE_PATH=""
FORCE_LARGE_DISK="false"
SKIP_CONFIRM="false"
MAX_SAFE_BYTES=$((256 * 1024 * 1024 * 1024)) # 256 GiB guard against wiping backup drives

# Resolve invoking user's home directory even if script is called via sudo
REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
REAL_HOME="$(eval echo "~${REAL_USER}")"

DEFAULT_IMG_NAME="starfive-jh7110-202510-minimal-desktop-wayland.img.zst"
CACHE_DIR="${RVDK_CACHE_DIR:-${REAL_HOME}/.rvdk/cache}"
RVDK_MIRROR_URL="${RVDK_MIRROR_URL:-https://rvdk.drewv-labs.dev/releases/latest/download}"

usage() {
    cat << 'EOF'
Usage:
  ./flash-starfive-visionfive2-debian-sd.sh <disk_number_or_path> [--image /path/to/img] [--yes] [--force]
  ./flash-starfive-visionfive2-debian-sd.sh --device <N|/dev/diskN|/dev/sdX> [--image /path/to/img] [--yes] [--force]

Image Resolution Order:
  1. --image /path/to/img (if provided)
  2. ~/.rvdk/cache/starfive-jh7110-202510-minimal-desktop-wayland.img.zst
  3. https://rvdk.drewv-labs.dev/releases/latest/download/starfive-jh7110-202510-minimal-desktop-wayland.img.zst
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

[[ -z "$TARGET_ARG" ]] && log_fatal "Missing target disk identifier. Run 'diskutil list external physical' and pass the disk number (e.g., 4)."

# ==============================================================================
# 1. PLATFORM-SPECIFIC DEVICE RESOLUTION & HARDWARE SAFETY INTERLOCKS
# ==============================================================================
OS_TYPE="$(uname -s)"

if [[ "$OS_TYPE" == "Darwin" ]]; then
    # Normalize "4", "disk4", "/dev/disk4", or "/dev/rdisk4" -> DISK_NUM="4" (portable across bash & zsh)
    DISK_NUM="$TARGET_ARG"
    DISK_NUM="${DISK_NUM#/dev/}"
    DISK_NUM="${DISK_NUM#r}"
    DISK_NUM="${DISK_NUM#disk}"
    case "$DISK_NUM" in
        ""|*[!0-9]*)
            log_fatal "Invalid macOS disk identifier '$TARGET_ARG' (expected disk number like '4' or '/dev/disk4')."
            ;;
    esac

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
    [[ -z "$DISK_BYTES" ]] && DISK_BYTES=0

    if [[ "$IS_INTERNAL" == "Internal" && "$IS_REMOVABLE" != "Removable" ]]; then
        log_fatal "Safety Interlock: $BLOCK_DEV ($MEDIA_NAME) is marked as an INTERNAL non-removable drive! Aborting."
    fi

    if (( DISK_BYTES > MAX_SAFE_BYTES )) && [[ "$FORCE_LARGE_DISK" != "true" ]]; then
        log_fatal "Safety Interlock: $BLOCK_DEV ($MEDIA_NAME) is larger than 256 GiB ($DISK_SIZE_LINE). Pass --force if this is intentional."
    fi

    log_info "Target macOS Media : ${BLOCK_DEV} -> ${RAW_DEV} (${MEDIA_NAME} | ${DISK_SIZE_LINE})"
else
    # Linux workstation support (e.g., BabbageBox-RTX)
    case "$TARGET_ARG" in
        ""|*[!0-9]*) ;;
        *) log_fatal "On Linux, specify the full block device path (e.g., --device /dev/sdX or /dev/mmcblkX)." ;;
    esac
    BLOCK_DEV="$TARGET_ARG"
    RAW_DEV="$TARGET_ARG"

    [[ ! -b "$BLOCK_DEV" ]] && log_fatal "Block device not found: $BLOCK_DEV"

    if lsblk -no MOUNTPOINT "$BLOCK_DEV" 2>/dev/null | grep -qE "^(/|/boot|/boot/efi|/home)$"; then
        log_fatal "Safety Interlock: $BLOCK_DEV contains a critical system mountpoint! Aborting."
    fi

    DISK_BYTES="$(lsblk -b -dn -o SIZE "$BLOCK_DEV" 2>/dev/null | head -n1 | tr -dc '0-9' || echo 0)"
    [[ -z "$DISK_BYTES" ]] && DISK_BYTES=0
    MEDIA_NAME="$(lsblk -dn -o VENDOR,MODEL,SIZE "$BLOCK_DEV" 2>/dev/null | xargs)"

    if (( DISK_BYTES > MAX_SAFE_BYTES )) && [[ "$FORCE_LARGE_DISK" != "true" ]]; then
        log_fatal "Safety Interlock: $BLOCK_DEV ($MEDIA_NAME) exceeds 256 GiB. Pass --force if this is intentional."
    fi

    log_info "Target Linux Media : ${RAW_DEV} (${MEDIA_NAME})"
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
        curl -fL --retry 3 -C - "$REMOTE_IMG_URL" -o "${IMAGE_PATH}.part"
        mv -f "${IMAGE_PATH}.part" "$IMAGE_PATH"
        chown "${REAL_USER}" "$IMAGE_PATH" 2>/dev/null || true
        log_ok "Downloaded and cached ${IMAGE_PATH}"
    fi

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

IMG_SIZE_BYTES="$(wc -c < "$IMAGE_PATH" | tr -dc '0-9')"
if (( IMG_SIZE_BYTES < 104857600 )); then
    log_fatal "Safety Interlock: ${IMAGE_PATH} is only ${IMG_SIZE_BYTES} bytes (< 100 MiB). Refusing to flash!"
fi

if [[ "$SKIP_CONFIRM" != "true" ]]; then
    printf "\033[1;33m[CONFIRM]\033[0m Destroy all data on %s (%s) and flash %s? [y/N]: " "$BLOCK_DEV" "$MEDIA_NAME" "$(basename "$IMAGE_PATH")"
    reply=""
    if [[ -r /dev/tty ]]; then
        read -r reply < /dev/tty || true
    else
        read -r reply || true
    fi
    case "$reply" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *) log_fatal "Flash aborted by user." ;;
    esac
fi

# ==============================================================================
# 3. UNMOUNT TARGET PARTITIONS
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
# 4. FLASH IMAGE (RAW OR STREAM-DECOMPRESSED) & SYNC
# ==============================================================================
DD_BS="4m"
[[ "$OS_TYPE" != "Darwin" ]] && DD_BS="4M"

log_info "Flashing image to ${RAW_DEV} (bs=${DD_BS})..."
sudo -v

case "$IMAGE_PATH" in
    *.zst)
        zstd -dc "$IMAGE_PATH" | sudo dd of="$RAW_DEV" bs="$DD_BS" status=progress
        ;;
    *.bz2)
        bzip2 -dc "$IMAGE_PATH" | sudo dd of="$RAW_DEV" bs="$DD_BS" status=progress
        ;;
    *.xz)
        xz -dc "$IMAGE_PATH" | sudo dd of="$RAW_DEV" bs="$DD_BS" status=progress
        ;;
    *.gz)
        gzip -dc "$IMAGE_PATH" | sudo dd of="$RAW_DEV" bs="$DD_BS" status=progress
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
