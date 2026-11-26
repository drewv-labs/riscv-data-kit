#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Waveshare ESP32-P4-WIFI6-DEV-KIT SD Card Provisioner & Flasher
# Path: riscv-data-kit/boards/waveshare/esp32-p4-wifi6/flash-sd.sh
#
# Workflows:
#   1. Default FAT32 SD Provisioning (4 MiB-aligned MBR + FAT32 RVDK_P4_SD, 32 KB
#      clusters, /config /firmware /models /telemetry /ota scaffold):
#        rvdk flash p4 sd <disk> [--tune iot|ai] [--hostname <name>] [-y]
#        boards/waveshare/esp32-p4-wifi6/flash-sd.sh --stage-only <dir> [--tune iot|ai]
#   2. Optional Raw riscv32 SD Image Mode:
#        boards/waveshare/esp32-p4-wifi6/flash-sd.sh <disk> --image <local.img[.zst|.xz|.gz|.bz2]> [-y]
# ==============================================================================

if [[ -n "${ZSH_VERSION:-}" ]]; then
    case "${0:-}" in
        zsh|-zsh|*/zsh|*/-zsh|zsh[0-9]*|*/zsh[0-9]*) ;;
        *)
            if [[ -f "${0:-}" ]]; then
                exec bash "$0" "$@"
            fi
            ;;
    esac
    printf '[FAIL] %s\n' "This script requires bash. When piping over stdin, run: curl ... | sudo bash" >&2
    exit 1
fi
set -Eeuo pipefail

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

# @RVDK_INLINE_LIBS: common kit progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:P4-SD]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_register_cleanup() { :; }
        rvdk_validate_hostname() {
            local h="${1:-}"
            [[ ${#h} -ge 1 && ${#h} -le 253 ]] || return 1
            [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
        }
        rvdk_atomic_write() {
            local _dst="$1" _mode="${2:-0644}" _tmp
            mkdir -p "$(dirname "$_dst")"
            _tmp="$(mktemp "$(dirname "$_dst")/.$(basename "$_dst").rvdk.XXXXXX")"
            cat > "$_tmp"
            chmod "$_mode" "$_tmp"
            mv -f "$_tmp" "$_dst"
        }
    fi
fi
if [[ -z "${_RVDK_KIT_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/kit.sh" ]]; then
        # shellcheck source=lib/kit.sh
        source "${_REPO_ROOT}/lib/kit.sh"
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

rvdk_log_init "RVDK:P4-SD"

_RVDK_P4_TMP_MNT=""
_RVDK_P4_STAGE_TMP=""
_rvdk_p4_flash_cleanup() {
    if [[ -n "${_RVDK_P4_TMP_MNT:-}" && -d "${_RVDK_P4_TMP_MNT}" ]]; then
        if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "${_RVDK_P4_TMP_MNT}" 2>/dev/null; then
            if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
                umount "${_RVDK_P4_TMP_MNT}" 2>/dev/null || umount -l "${_RVDK_P4_TMP_MNT}" 2>/dev/null || true
            else
                sudo umount "${_RVDK_P4_TMP_MNT}" 2>/dev/null || sudo umount -l "${_RVDK_P4_TMP_MNT}" 2>/dev/null || true
            fi
        fi
        rmdir "${_RVDK_P4_TMP_MNT}" 2>/dev/null || true
        _RVDK_P4_TMP_MNT=""
    fi
    if [[ -n "${_RVDK_P4_STAGE_TMP:-}" && -d "${_RVDK_P4_STAGE_TMP}" ]]; then
        rm -rf "${_RVDK_P4_STAGE_TMP}" 2>/dev/null || true
        _RVDK_P4_STAGE_TMP=""
    fi
    if typeset -f _rvdk_cleanup_tmpfiles >/dev/null 2>&1; then
        _rvdk_cleanup_tmpfiles || true
    fi
}

if typeset -f rvdk_register_cleanup >/dev/null 2>&1; then
    rvdk_register_cleanup _rvdk_p4_flash_cleanup
elif [[ -z "$(trap -p EXIT 2>/dev/null || true)" ]]; then
    trap '_rvdk_p4_flash_cleanup' EXIT
    trap '_rvdk_p4_flash_cleanup; trap - EXIT INT; kill -INT $$' INT
    trap '_rvdk_p4_flash_cleanup; trap - EXIT TERM; kill -TERM $$' TERM
fi

usage() {
    cat <<'EOF'
Usage:
  rvdk flash p4 sd [<disk>] [--tune <iot|ai>] [--hostname <name>] [--stage-only <dir>] [--stage-dir <dir>] [--dry-run] [-y]
  boards/waveshare/esp32-p4-wifi6/flash-sd.sh [<disk>] [options]

Options:
  -d, --device <disk>          Target disk number (macOS: 4 or /dev/disk4) or block device (Linux: /dev/sdX, /dev/mmcblk0)
  -t, --tune <iot|ai|data>     ESP32-P4 profile to stage (default: iot)
  -H, --hostname <name>        Optional RFC-1123 hostname to stage in /config/hostname
      --root-label <label>     FAT32 volume label (default: RVDK_P4_SD; max 11 chars)
      --no-root-label          Omit custom root label in raw image mode
      --stage-dir <dir>        Stage config & directory scaffold into <dir>
      --stage-only [<dir>]     Stage payload into <dir> with zero disk operations
  -i, --image <path>           Delegate raw riscv32 SD image (.img[.zst|.xz|.gz|.bz2]) to lib/flash.sh
      --sha256 <hex64>         Expected SHA-256 digest for --image
      --allow-remote-sha256    Trust same-origin .sha256 sidecar in --image mode
      --insecure-skip-sha256   Bypass SHA-256 verification in --image mode
      --allow-non-removable    Allow non-USB/MMC drives on Linux (still refuses OS/boot/swap disks)
      --force                  Override 256 GiB large-drive safety ceiling
  -n, --dry-run                Run safety interlocks and print plan without modifying disks
  -y, --yes                    Skip interactive confirmation prompt
      --noprogbar              Disable persistent bottom progress bar
  -h, --help                   Show this help message and exit
EOF
}

TARGET_DISK=""
TUNE_REQUEST="${RVDK_TUNE:-iot}"
TARGET_HOSTNAME=""
ROOT_LABEL="RVDK_P4_SD"
SKIP_ROOT_LABEL="false"
STAGE_DIR=""
STAGE_ONLY="false"
IMAGE_PATH=""
CLI_SHA256=""
ALLOW_REMOTE_SHA256="false"
SKIP_SHA256="false"
ALLOW_NON_REMOVABLE="false"
FORCE_LARGE_DISK="false"
DRY_RUN="false"
SKIP_CONFIRM="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires a disk argument."
            TARGET_DISK="$2"; shift 2 ;;
        --device=*)
            TARGET_DISK="${1#*=}"; shift ;;
        -t|--tune)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument: iot | ai | data"
            TUNE_REQUEST="$2"; shift 2 ;;
        --tune=*)
            TUNE_REQUEST="${1#*=}"; shift ;;
        -H|--hostname)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires a hostname argument."
            TARGET_HOSTNAME="$2"; shift 2 ;;
        --hostname=*)
            TARGET_HOSTNAME="${1#*=}"; shift ;;
        --root-label)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires a label argument."
            ROOT_LABEL="$2"; shift 2 ;;
        --root-label=*)
            ROOT_LABEL="${1#*=}"; shift ;;
        --no-root-label)
            SKIP_ROOT_LABEL="true"; shift ;;
        --stage-dir)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires a directory argument."
            STAGE_DIR="$2"; shift 2 ;;
        --stage-dir=*)
            STAGE_DIR="${1#*=}"; shift ;;
        --stage-only)
            STAGE_ONLY="true"
            if [[ -n "${2:-}" && "${2:-}" != -* && "${2:-}" != /dev/* && ! "${2:-}" =~ ^[0-9]+$ && -z "$STAGE_DIR" ]]; then
                STAGE_DIR="$2"
                shift 2
            else
                shift
            fi
            ;;
        --stage-only=*)
            STAGE_ONLY="true"
            STAGE_DIR="${1#*=}"
            shift ;;
        -i|--image)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an image path."
            IMAGE_PATH="$2"; shift 2 ;;
        --image=*)
            IMAGE_PATH="${1#*=}"; shift ;;
        --sha256)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires a SHA-256 hex digest."
            CLI_SHA256="$2"; shift 2 ;;
        --sha256=*)
            CLI_SHA256="${1#*=}"; shift ;;
        --allow-remote-sha256)
            ALLOW_REMOTE_SHA256="true"; shift ;;
        --insecure-skip-sha256)
            SKIP_SHA256="true"; shift ;;
        --allow-non-removable)
            ALLOW_NON_REMOVABLE="true"; shift ;;
        --force)
            FORCE_LARGE_DISK="true"; shift ;;
        -n|--dry-run)
            DRY_RUN="true"; shift ;;
        -y|--yes)
            SKIP_CONFIRM="true"; shift ;;
        --no-apt-update|--skip-apt-update)
            export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)
            export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        -*)
            log_fatal "Unknown flag: $1 (try --help)" ;;
        *)
            if [[ -z "$TARGET_DISK" ]]; then
                TARGET_DISK="$1"
                shift
            else
                log_fatal "Unexpected positional argument: $1 (try --help)"
            fi
            ;;
    esac
done

TUNE_REQUEST="$(tr '[:upper:]' '[:lower:]' <<< "$TUNE_REQUEST")"
case "$TUNE_REQUEST" in
    iot|edge-iot|sensor|mcu) TUNE_LABEL="iot" ;;
    ai|ml|edge-ai|edge-ml)   TUNE_LABEL="ai" ;;
    data)
        log_warn "Waveshare ESP32-P4 is riscv32 nommu; mapping '--tune data' to 'iot' SD staging profile"
        TUNE_LABEL="iot"
        ;;
    *) log_fatal "Invalid --tune '${TUNE_REQUEST}' (expected: iot | ai | data)" ;;
esac

if [[ -n "$TARGET_HOSTNAME" ]]; then
    rvdk_validate_hostname "$TARGET_HOSTNAME" || log_fatal "Invalid RFC-1123 --hostname '${TARGET_HOSTNAME}'."
fi

if [[ "$STAGE_ONLY" == "true" && -z "$STAGE_DIR" ]]; then
    log_fatal "--stage-only requires a staging directory (pass --stage-only <dir> or --stage-dir <dir>)."
fi

if [[ -z "$IMAGE_PATH" && "$SKIP_ROOT_LABEL" != "true" ]]; then
    if [[ ! "$ROOT_LABEL" =~ ^[A-Za-z0-9_.-]{1,11}$ ]]; then
        log_fatal "Invalid FAT32 volume label '${ROOT_LABEL}' (max 11 chars: [A-Za-z0-9_.-])."
    fi
fi

_run_priv() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

_stage_p4_tree() {
    local dest_root="$1"
    [[ -n "$dest_root" && "$dest_root" != "/" ]] || log_fatal "Unsafe staging root '${dest_root}'."

    local sub
    for sub in config firmware models telemetry ota; do
        mkdir -p "${dest_root}/${sub}"
    done

    local bsp_forge="${_REPO_ROOT}/bsp/espressif/esp32p4/forge.sh"
    local bsp_dt="${_REPO_ROOT}/bsp/espressif/esp32p4/deeptune.sh"
    local brd_dt="${_REPO_ROOT}/boards/waveshare/esp32-p4-wifi6/deeptune.sh"
    local c6_quirk="${_REPO_ROOT}/boards/waveshare/esp32-p4-wifi6/quirks/c6-sdio.sh"

    [[ -f "$bsp_forge" ]] || log_fatal "Missing ESP32-P4 BSP forge script: ${bsp_forge}"
    [[ -f "$bsp_dt" ]]    || log_fatal "Missing ESP32-P4 BSP DeepTune script: ${bsp_dt}"
    [[ -f "$brd_dt" ]]    || log_fatal "Missing Waveshare ESP32-P4 DeepTune script: ${brd_dt}"
    [[ -f "$c6_quirk" ]]  || log_fatal "Missing Waveshare c6-sdio quirk script: ${c6_quirk}"

    bash "$bsp_forge" --stage-dir "$dest_root" --noprogbar
    bash "$bsp_dt" --tune "$TUNE_LABEL" --stage-dir "$dest_root" --noprogbar
    if [[ ! -f "${dest_root}/config/c6-sdio.env" ]]; then
        bash "$c6_quirk" enable --stage-dir "$dest_root" --quiet --noprogbar
    fi
    bash "$brd_dt" --tune "$TUNE_LABEL" --stage-dir "$dest_root" --noprogbar

    if [[ -n "$TARGET_HOSTNAME" ]]; then
        local host_file="${dest_root}/config/hostname"
        if [[ -f "$host_file" && ! -L "$host_file" ]] && printf '%s\n' "$TARGET_HOSTNAME" | cmp -s - "$host_file" 2>/dev/null; then
            log_skip "Hostname already staged (${host_file} = ${TARGET_HOSTNAME})"
        else
            printf '%s\n' "$TARGET_HOSTNAME" | rvdk_atomic_write "$host_file" 0644
            log_ok "Staged hostname -> ${TARGET_HOSTNAME} (${host_file})"
        fi
    fi
}

_resolve_linux_parent_disk() {
    local dev_node="${1:-}"
    [[ -n "$dev_node" ]] || return 0
    local pk=""
    if command -v lsblk >/dev/null 2>&1; then
        pk="$(lsblk -no PKNAME "$dev_node" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
    fi
    if [[ -n "$pk" ]]; then
        printf '/dev/%s\n' "$pk"
    else
        printf '%s\n' "$dev_node"
    fi
}

_validate_target_disk() {
    local os_type="$1"
    local arg="$2"
    local min_bytes=$(( 4 * 1024 * 1024 * 1024 ))
    local max_safe_bytes=$(( 256 * 1024 * 1024 * 1024 ))

    RESOLVED_BLOCK_DEV=""
    RESOLVED_RAW_DEV=""
    RESOLVED_MEDIA_NAME=""

    if [[ "$os_type" == "Darwin" ]]; then
        local dnum="$arg"
        dnum="${dnum#/dev/}"
        dnum="${dnum#r}"
        dnum="${dnum#disk}"
        case "$dnum" in
            ""|*[!0-9]*)
                log_fatal "Invalid macOS disk identifier '${arg}' (expected disk number like '4' or '/dev/disk4')."
                ;;
        esac
        if (( dnum == 0 || dnum == 1 )); then
            log_fatal "Safety Interlock: /dev/disk${dnum} is reserved for macOS internal system storage. Aborting!"
        fi

        RESOLVED_BLOCK_DEV="/dev/disk${dnum}"
        RESOLVED_RAW_DEV="/dev/rdisk${dnum}"

        local disk_info=""
        disk_info="$(diskutil info "$RESOLVED_BLOCK_DEV" 2>/dev/null || true)"
        [[ -n "$disk_info" ]] || log_fatal "Device ${RESOLVED_BLOCK_DEV} does not exist. Check 'diskutil list external physical'."

        local is_internal is_removable is_virtual io_content disk_size_line disk_bytes=0
        is_internal="$(awk '/^[[:space:]]*Device Location:[[:space:]]*/ { sub(/^[[:space:]]*Device Location:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' <<< "$disk_info")"
        is_removable="$(awk '/^[[:space:]]*Removable Media:[[:space:]]*/ { sub(/^[[:space:]]*Removable Media:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' <<< "$disk_info")"
        is_virtual="$(awk '/^[[:space:]]*Virtual:[[:space:]]*/ { sub(/^[[:space:]]*Virtual:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' <<< "$disk_info")"
        io_content="$(awk '/^[[:space:]]*Content \(IOContent\):[[:space:]]*/ { sub(/^[[:space:]]*Content \(IOContent\):[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' <<< "$disk_info")"
        RESOLVED_MEDIA_NAME="$(awk '/^[[:space:]]*Device \/ Media Name:[[:space:]]*/ { sub(/^[[:space:]]*Device \/ Media Name:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' <<< "$disk_info")"
        disk_size_line="$(awk '/^[[:space:]]*Disk Size:[[:space:]]*/ { sub(/^[[:space:]]*Disk Size:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' <<< "$disk_info")"
        disk_bytes="$(grep -oE '\([0-9]+ Bytes\)' <<< "$disk_size_line" | tr -dc '0-9' || echo 0)"
        [[ -z "$disk_bytes" ]] && disk_bytes=0

        if [[ "$io_content" == *APFS* || "$RESOLVED_MEDIA_NAME" == *APFS* || "$RESOLVED_MEDIA_NAME" == *Synthesized* ]]; then
            log_fatal "Safety Interlock: ${RESOLVED_BLOCK_DEV} (${RESOLVED_MEDIA_NAME:-unknown}) appears to be an APFS/synthesized container; rejected!"
        fi
        if [[ "$is_internal" != "External" || "$is_virtual" == "Yes" || "$is_removable" != "Removable" ]]; then
            log_fatal "Safety Interlock: ${RESOLVED_BLOCK_DEV} (${RESOLVED_MEDIA_NAME:-unknown}) rejected (location=${is_internal:-unknown}, removable=${is_removable:-unknown}, virtual=${is_virtual:-unknown}); requires External, non-Virtual, Removable media! Aborting."
        fi
        if (( disk_bytes > 0 && disk_bytes < min_bytes )); then
            log_fatal "Target media (${RESOLVED_MEDIA_NAME}) is smaller than minimum 4 GiB required for Waveshare ESP32-P4."
        fi
        if (( disk_bytes > max_safe_bytes )) && [[ "$FORCE_LARGE_DISK" != "true" ]]; then
            log_fatal "Safety Interlock: ${RESOLVED_BLOCK_DEV} (${RESOLVED_MEDIA_NAME}) exceeds 256 GiB. Pass --force if wiping a large drive is intentional."
        fi
        return 0
    fi

    case "$arg" in
        ""|*[!0-9]*) ;;
        *) log_fatal "On Linux, specify the full block device path (e.g., /dev/sdX or /dev/mmcblk0)." ;;
    esac
    case "$arg" in
        *boot[0-9]|*rpmb)
            log_fatal "Specify the parent MMC block device (e.g., /dev/mmcblk0), not hardware sub-partition '${arg}'."
            ;;
    esac

    # Fail-closed check against live OS /boot /swap backing devices even before -b stat
    if command -v findmnt >/dev/null 2>&1; then
        local crit_mp crit_src crit_parent
        for crit_mp in / /boot /boot/efi /usr /var /home; do
            crit_src="$(findmnt -n -o SOURCE "$crit_mp" 2>/dev/null || true)"
            [[ -n "$crit_src" ]] || continue
            crit_parent="$(_resolve_linux_parent_disk "$crit_src")"
            if [[ "$arg" == "$crit_src" || "$arg" == "$crit_parent" || "$crit_src" == "${arg}"* ]]; then
                log_fatal "Safety Interlock: ${arg} backs critical system mount '${crit_mp}' (${crit_src})! Aborting."
            fi
        done
    fi
    if [[ -r /proc/swaps ]]; then
        local sw_dev sw_parent
        while IFS= read -r sw_dev; do
            [[ -n "$sw_dev" ]] || continue
            sw_parent="$(_resolve_linux_parent_disk "$sw_dev")"
            if [[ "$arg" == "$sw_dev" || "$arg" == "$sw_parent" || "$sw_dev" == "${arg}"* ]]; then
                log_fatal "Safety Interlock: ${arg} backs active swap device (${sw_dev})! Aborting."
            fi
        done < <(awk 'NR>1 {print $1}' /proc/swaps 2>/dev/null || true)
    fi
    if command -v lsblk >/dev/null 2>&1; then
        local mnt
        while IFS= read -r mnt; do
            [[ -z "$mnt" ]] && continue
            case "$mnt" in
                /|/boot|/boot/*|/usr|/var|/home|"[SWAP]")
                    log_fatal "Safety Interlock: ${arg} backs critical system mount/swap (${mnt})! Aborting."
                    ;;
            esac
        done < <(lsblk -rn -o MOUNTPOINTS "$arg" 2>/dev/null || lsblk -rn -o MOUNTPOINT "$arg" 2>/dev/null || true)
    fi

    [[ -b "$arg" ]] || log_fatal "Block device not found: ${arg}"

    local dev_type=""
    dev_type="$(lsblk -dn -o TYPE "$arg" 2>/dev/null | head -n1 | xargs || true)"
    [[ "$dev_type" == "part" ]] && log_fatal "Specify a whole-disk block device, not partition '${arg}'."

    if [[ "$ALLOW_NON_REMOVABLE" != "true" ]]; then
        local rm_flag hotplug_flag tran_type dev_base is_mmc_target="false"
        rm_flag="$(lsblk -dn -o RM "$arg" 2>/dev/null | head -n1 | tr -dc '0-9' || echo 0)"
        hotplug_flag="$(lsblk -dn -o HOTPLUG "$arg" 2>/dev/null | head -n1 | tr -dc '0-9' || echo 0)"
        tran_type="$(lsblk -dn -o TRAN "$arg" 2>/dev/null | head -n1 | tr '[:upper:]' '[:lower:]' | xargs || true)"
        dev_base="$(basename "$arg")"
        [[ "$dev_base" == mmcblk[0-9]* ]] && is_mmc_target="true"
        if [[ "${rm_flag:-0}" != "1" && "${hotplug_flag:-0}" != "1" && "$tran_type" != "usb" && "$tran_type" != "mmc" && "$is_mmc_target" != "true" ]]; then
            log_fatal "Safety Interlock: ${arg} is not flagged as removable/USB/MMC (RM=${rm_flag:-0}, HOTPLUG=${hotplug_flag:-0}, TRAN=${tran_type:-none}). Pass --allow-non-removable if intentional."
        fi
    fi

    local disk_bytes=0
    disk_bytes="$(lsblk -b -dn -o SIZE "$arg" 2>/dev/null | head -n1 | tr -dc '0-9' || echo 0)"
    [[ -z "$disk_bytes" ]] && disk_bytes=0
    RESOLVED_MEDIA_NAME="$(lsblk -dn -o VENDOR,MODEL,SIZE "$arg" 2>/dev/null | xargs || echo "$arg")"
    RESOLVED_BLOCK_DEV="$arg"
    RESOLVED_RAW_DEV="$arg"

    if (( disk_bytes > 0 && disk_bytes < min_bytes )); then
        log_fatal "Target media (${RESOLVED_MEDIA_NAME}) is smaller than minimum 4 GiB required for Waveshare ESP32-P4."
    fi
    if (( disk_bytes > max_safe_bytes )) && [[ "$FORCE_LARGE_DISK" != "true" ]]; then
        log_fatal "Safety Interlock: ${arg} (${RESOLVED_MEDIA_NAME}) exceeds 256 GiB. Pass --force if wiping a large drive is intentional."
    fi
}

OS_TYPE="$(uname -s)"

# ------------------------------------------------------------------------------
# Workflow 2: Optional Raw riscv32 SD Image Delegation (`--image <path>`)
# ------------------------------------------------------------------------------
if [[ -n "$IMAGE_PATH" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        [[ -f "$IMAGE_PATH" ]] || log_fatal "Custom image file not found: ${IMAGE_PATH}"
        min_image_mib=4
        if [[ -n "$_SCRIPT_DIR" && -f "${_SCRIPT_DIR}/media.json" ]] && command -v python3 >/dev/null 2>&1; then
            _json_min="$(python3 - "${_SCRIPT_DIR}/media.json" <<'PY' 2>/dev/null || true
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)
val = ((doc.get("media") or {}).get("sd") or {}).get("min_image_mib", 4)
if isinstance(val, int) and not isinstance(val, bool) and val > 0:
    print(val)
PY
            )"
            [[ "$_json_min" =~ ^[0-9]+$ && "$_json_min" -gt 0 ]] && min_image_mib="$_json_min"
        fi
        min_img_bytes=$(( min_image_mib * 1048576 ))
        img_size_bytes="$(wc -c < "$IMAGE_PATH" | tr -dc '0-9')"
        [[ -z "$img_size_bytes" ]] && img_size_bytes=0
        if (( img_size_bytes < min_img_bytes )); then
            log_fatal "Safety Interlock: ${IMAGE_PATH} is only ${img_size_bytes} bytes (< ${min_image_mib} MiB). Refusing to write!"
        fi
        if [[ -n "$TARGET_DISK" ]]; then
            _validate_target_disk "$OS_TYPE" "$TARGET_DISK"
        fi
        log_ok "[DRY-RUN] Verified raw riscv32 image '${IMAGE_PATH}' (${img_size_bytes} bytes >= ${min_image_mib} MiB) for waveshare/esp32-p4-wifi6 (target=${TARGET_DISK:-unspecified}); no disk writes performed."
        exit 0
    fi

    [[ -f "${_REPO_ROOT}/lib/flash.sh" ]] || log_fatal "Missing RVDK flash library: ${_REPO_ROOT}/lib/flash.sh"
    raw_args=("--board" "waveshare/esp32-p4-wifi6" "--medium" "sd" "--image" "$IMAGE_PATH")
    [[ -n "$TARGET_DISK" ]]                  && raw_args+=("--device" "$TARGET_DISK")
    [[ -n "$CLI_SHA256" ]]                   && raw_args+=("--sha256" "$CLI_SHA256")
    [[ "$ALLOW_REMOTE_SHA256" == "true" ]]   && raw_args+=("--allow-remote-sha256")
    [[ "$SKIP_SHA256" == "true" ]]           && raw_args+=("--insecure-skip-sha256")
    [[ "$ALLOW_NON_REMOVABLE" == "true" ]]   && raw_args+=("--allow-non-removable")
    [[ "$SKIP_ROOT_LABEL" == "true" ]]       && raw_args+=("--no-root-label")
    [[ "$SKIP_ROOT_LABEL" != "true" && -n "$ROOT_LABEL" ]] && raw_args+=("--root-label" "$ROOT_LABEL")
    [[ "$FORCE_LARGE_DISK" == "true" ]]      && raw_args+=("--force")
    [[ "$SKIP_CONFIRM" == "true" ]]          && raw_args+=("--yes")

    RVDK_FLASH_FORCE_RAW=1 exec bash "${_REPO_ROOT}/lib/flash.sh" "${raw_args[@]}"
fi

# ------------------------------------------------------------------------------
# Workflow 1A: Host-Safe Staging Mode (`--stage-only <dir>`)
# ------------------------------------------------------------------------------
if [[ "$STAGE_ONLY" == "true" ]]; then
    rvdk_prog_init "Waveshare ESP32-P4 SD staging (--tune ${TUNE_LABEL})..."
    log_info "Staging ESP32-P4 SD payload tree (--stage-only ${STAGE_DIR} | tune=${TUNE_LABEL})..."
    _stage_p4_tree "$STAGE_DIR"
    rvdk_prog 100 "ESP32-P4 SD payload staged in ${STAGE_DIR}"
    log_ok "Staged ESP32-P4 FAT32 SD tree at ${STAGE_DIR} (/config, /firmware, /models, /telemetry, /ota; zero disk writes)"
    exit 0
fi

# ------------------------------------------------------------------------------
# Workflow 1B: Dry-Run or Live FAT32 SD Provisioning (`RVDK_P4_SD`)
# ------------------------------------------------------------------------------
if [[ -z "$TARGET_DISK" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log_ok "[DRY-RUN] Waveshare ESP32-P4 SD provisioner plan (tune=${TUNE_LABEL}, label=${ROOT_LABEL}, 4 MiB-aligned MBR + FAT32 32KB clusters, /config /firmware /models /telemetry /ota); pass <disk> to validate removable media."
        exit 0
    fi
    log_fatal "Missing target disk identifier for Waveshare ESP32-P4 SD provisioning. Pass <disk> (macOS: 4 or /dev/disk4; Linux: /dev/sdX or /dev/mmcblk0), or use --stage-only <dir>."
fi

_validate_target_disk "$OS_TYPE" "$TARGET_DISK"

if [[ "$DRY_RUN" == "true" ]]; then
    log_ok "[DRY-RUN] Safety interlocks passed for ${RESOLVED_BLOCK_DEV} (${RESOLVED_MEDIA_NAME}); would format 4 MiB-aligned MBR + FAT32 (${ROOT_LABEL}, 32KB clusters) and stage tune=${TUNE_LABEL}."
    exit 0
fi

if [[ "$SKIP_CONFIRM" != "true" ]]; then
    printf "\033[1;33m[CONFIRM]\033[0m Erase %s (%s) and format MBR + FAT32 '%s' (32KB clusters, tune=%s)? [y/N]: " \
        "$RESOLVED_BLOCK_DEV" "$RESOLVED_MEDIA_NAME" "$ROOT_LABEL" "$TUNE_LABEL"
    reply=""
    if [[ -r /dev/tty ]]; then
        read -r reply < /dev/tty || true
    else
        read -r reply || true
    fi
    case "$reply" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *) log_fatal "Aborted by user." ;;
    esac
fi

rvdk_prog_init "Waveshare ESP32-P4 SD: preparing FAT32 ${ROOT_LABEL} on ${RESOLVED_BLOCK_DEV}..."

STAGE_SOURCE="$STAGE_DIR"
if [[ -z "$STAGE_SOURCE" ]]; then
    _RVDK_P4_STAGE_TMP="$(mktemp -d "/tmp/rvdk_p4_sd_stage.XXXXXX")"
    STAGE_SOURCE="$_RVDK_P4_STAGE_TMP"
fi
rvdk_prog 25 "ESP32-P4 SD: generating staged config & directory tree..."
_stage_p4_tree "$STAGE_SOURCE"

if [[ "$OS_TYPE" == "Darwin" ]]; then
    rvdk_prog 55 "ESP32-P4 SD: partitioning & formatting FAT32 (${ROOT_LABEL}, 32KB clusters)..."
    diskutil unmountDisk "$RESOLVED_BLOCK_DEV"
    diskutil partitionDisk "$RESOLVED_BLOCK_DEV" 1 MBR FAT32 "$ROOT_LABEL" 100% >/dev/null

    PART_NODE="${RESOLVED_BLOCK_DEV}s1"
    PART_RAW="${RESOLVED_RAW_DEV}s1"
    diskutil unmount "$PART_NODE" >/dev/null 2>&1 || true
    newfs_msdos -F 32 -b 32768 -v "$ROOT_LABEL" "$PART_RAW" >/dev/null
    diskutil mount "$PART_NODE" >/dev/null

    VOL_MNT=""
    VOL_MNT="$(diskutil info "$PART_NODE" 2>/dev/null | awk '/^[[:space:]]*Mount Point:[[:space:]]*/ { sub(/^[[:space:]]*Mount Point:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }')"
    [[ -n "$VOL_MNT" && -d "$VOL_MNT" ]] || log_fatal "Failed to locate mounted FAT32 volume for ${PART_NODE}."

    rvdk_prog 85 "ESP32-P4 SD: copying staged payload to ${VOL_MNT}..."
    cp -R "${STAGE_SOURCE}/." "${VOL_MNT}/"
    sync
    diskutil eject "$RESOLVED_BLOCK_DEV" >/dev/null
    log_ok "Provisioned ${RESOLVED_BLOCK_DEV} (${ROOT_LABEL} FAT32, 32KB clusters) and ejected safely"
else
    for req_cmd in parted mkfs.vfat; do
        command -v "$req_cmd" >/dev/null 2>&1 || log_fatal "Required utility '${req_cmd}' is not installed."
    done

    rvdk_prog 55 "ESP32-P4 SD: partitioning 4 MiB-aligned MBR + FAT32 (${ROOT_LABEL}, 32KB clusters)..."
    for part_cand in "${RESOLVED_BLOCK_DEV}"*; do
        [[ "$part_cand" == "$RESOLVED_BLOCK_DEV" ]] && continue
        _run_priv umount "$part_cand" 2>/dev/null || _run_priv umount -l "$part_cand" 2>/dev/null || true
    done

    command -v wipefs >/dev/null 2>&1 && _run_priv wipefs -af "$RESOLVED_BLOCK_DEV" >/dev/null 2>&1 || true
    _run_priv parted -s "$RESOLVED_BLOCK_DEV" -- mklabel msdos
    # 8192 * 512B = 4 MiB alignment for SDMMC erase-block & page health
    _run_priv parted -s "$RESOLVED_BLOCK_DEV" -- mkpart primary fat32 8192s 100%
    _run_priv partprobe "$RESOLVED_BLOCK_DEV" 2>/dev/null || _run_priv blockdev --rereadpt "$RESOLVED_BLOCK_DEV" 2>/dev/null || true
    if command -v udevadm >/dev/null 2>&1; then
        _run_priv udevadm settle 2>/dev/null || sleep 1
    else
        sleep 1
    fi

    if [[ "$RESOLVED_BLOCK_DEV" == *mmcblk* || "$RESOLVED_BLOCK_DEV" == *nvme* || "$RESOLVED_BLOCK_DEV" == *loop* ]]; then
        PART_DEV="${RESOLVED_BLOCK_DEV}p1"
    else
        PART_DEV="${RESOLVED_BLOCK_DEV}1"
    fi
    [[ -b "$PART_DEV" ]] || log_fatal "Expected FAT32 partition '${PART_DEV}' did not appear after partitioning."

    # 64 sectors/cluster * 512B = 32 KB clusters for 4-bit SDMMC throughput
    _run_priv mkfs.vfat -F 32 -s 64 -n "$ROOT_LABEL" "$PART_DEV" >/dev/null

    _RVDK_P4_TMP_MNT="$(mktemp -d "/tmp/rvdk_p4_sd_mnt.XXXXXX")"
    _run_priv mount "$PART_DEV" "$_RVDK_P4_TMP_MNT"
    rvdk_prog 85 "ESP32-P4 SD: copying staged payload to ${PART_DEV}..."
    _run_priv cp -a "${STAGE_SOURCE}/." "${_RVDK_P4_TMP_MNT}/"
    sync
    _run_priv umount "$_RVDK_P4_TMP_MNT"
    rmdir "$_RVDK_P4_TMP_MNT"
    _RVDK_P4_TMP_MNT=""
    if [[ "$(basename "$RESOLVED_BLOCK_DEV")" != mmcblk* ]]; then
        _run_priv eject "$RESOLVED_BLOCK_DEV" 2>/dev/null || true
    fi
    log_ok "Provisioned ${PART_DEV} (${ROOT_LABEL} FAT32, 4 MiB-aligned, 32KB clusters)"
fi

rvdk_prog 100 "Waveshare ESP32-P4 SD provisioning complete"
