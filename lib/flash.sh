#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Metadata-Driven Removable Media Flasher (macOS & Linux)
# Path: riscv-data-kit/lib/flash.sh
#
# Reads board flash specifications from `boards/<vendor>/<board>/media.json` and
# executes hardware-interlocked, cryptographically verified media preparation:
#   • mode = "raw"        : Stream-decompresses (.zst/.xz/.bz2/.gz/raw) to block dev
#   • mode = "uboot_ext4" : Builds U-Boot compatible ext4 stick (-O ^metadata_csum_seed,^orphan_file)
#
# Security & Safety Interlocks:
#   • Fail-closed SHA-256 verification on all downloaded images (unless --insecure-skip-sha256)
#   • Blocks macOS disk0/disk1 and Internal non-removable storage
#   • Blocks Linux OS/swap disks and non-removable/non-USB/MMC disks (unless --allow-non-removable)
#   • Enforces minimum capacity and 256 GiB backup-drive ceiling (unless --force)
#   • Trap-guarded temporary mount cleanup on Linux ext4 staging
# ==============================================================================

if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L ksh
    setopt PIPE_FAIL ERR_RETURN NO_UNSET
else
    set -Eeuo pipefail
fi

_FLASH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_FLASH_REPO_ROOT="$(cd "${_FLASH_LIB_DIR}/.." && pwd)"

# shellcheck source=lib/common.sh
source "${_FLASH_LIB_DIR}/common.sh"
rvdk_log_init "RVDK:FLASH"

_RVDK_FLASH_TMP_MNT=""
_rvdk_flash_cleanup() {
    if [[ -n "${_RVDK_FLASH_TMP_MNT:-}" && -d "${_RVDK_FLASH_TMP_MNT}" ]]; then
        if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null; then
            sudo umount "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null || sudo umount -l "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null || true
        else
            sudo umount "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null || true
        fi
        rmdir "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null || true
    fi
}

rvdk_flash_list() {
    local boards_root="${_FLASH_REPO_ROOT}/boards"
    if ! command -v python3 >/dev/null 2>&1; then
        log_fatal "python3 is required to inspect board media manifests."
    fi
    python3 - "$boards_root" << 'PY'
import glob, json, os, sys

boards_root = sys.argv[1]
paths = sorted(glob.glob(os.path.join(boards_root, "*", "*", "media.json")))
print("RVDK Board Media Catalog (boards/*/*/media.json):")
print("  {:<12} {:<22} {:<10} {:<12} {}".format("TAG", "BOARD", "MEDIUM", "MODE", "DESCRIPTION"))
print("  " + "-" * 86)
for p in paths:
    with open(p, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    tag = data.get("tag", "-")
    board = data.get("board", "-")
    media = data.get("media") or {}
    if not media:
        print("  {:<12} {:<22} {:<10} {:<12} {}".format(tag, board, "-", "-", "(Vendor / onboard storage)"))
        continue
    for m_name, spec in sorted(media.items()):
        mode = spec.get("mode", "uboot_ext4" if spec.get("uboot_payload") else "raw")
        desc = spec.get("description", "")
        print("  {:<12} {:<22} {:<10} {:<12} {}".format(tag, board, m_name, mode, desc))
PY
}

_rvdk_flash_resolve_manifest() {
    local query="$1"
    local boards_root="${_FLASH_REPO_ROOT}/boards"
    if [[ -f "${boards_root}/${query}/media.json" ]]; then
        printf '%s\n' "${boards_root}/${query}/media.json"
        return 0
    fi
    python3 - "$boards_root" "$query" << 'PY'
import glob, json, os, sys
boards_root, q = sys.argv[1], sys.argv[2].strip().lower()
aliases = {
    "premier-p550": "sifive/p550",
    "visionfive2": "starfive/vf2",
    "visionfive2-lite": "starfive/vf2-lite",
}
target = aliases.get(q, q)
for p in sorted(glob.glob(os.path.join(boards_root, "*", "*", "media.json"))):
    with open(p, "r", encoding="utf-8") as fh:
        d = json.load(fh)
    if d.get("board", "").lower() == target or d.get("tag", "").lower() == target:
        print(p)
        sys.exit(0)
sys.exit(1)
PY
}

_rvdk_flash_verify_sha256() {
    local img_file="$1"
    local sha_file="$2"
    local remote_sha_url="$3"
    local pinned_sha="$4"
    local skip_sha="$5"
    local owner_user="$6"

    local expected=""
    if [[ -n "$pinned_sha" ]]; then
        expected="$(printf '%s' "$pinned_sha" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')"
    else
        if [[ ! -s "$sha_file" && -n "$remote_sha_url" ]]; then
            log_info "Fetching cryptographic digest from ${remote_sha_url}..."
            if ! curl -fsSL --retry 3 "$remote_sha_url" -o "${sha_file}.tmp"; then
                rm -f "${sha_file}.tmp"
                if [[ "$skip_sha" == "true" ]]; then
                    log_warn "SHA-256 manifest unavailable at ${remote_sha_url}; proceeding ONLY because --insecure-skip-sha256 was set."
                    return 0
                fi
                log_fatal "Fail-closed security check: unable to fetch SHA-256 digest from ${remote_sha_url}. Supply --sha256 <hex> or --insecure-skip-sha256."
            fi
            mv -f "${sha_file}.tmp" "$sha_file"
            chown "$owner_user" "$sha_file" 2>/dev/null || true
        fi
        if [[ -s "$sha_file" ]]; then
            expected="$(awk '{print tolower($1); exit}' "$sha_file")"
        fi
    fi

    if [[ -z "$expected" ]]; then
        if [[ "$skip_sha" == "true" ]]; then
            log_warn "Skipping SHA-256 verification (--insecure-skip-sha256 enabled)."
            return 0
        fi
        log_fatal "Fail-closed security check: no SHA-256 digest available for ${img_file}. Pass --sha256 <hex> or --insecure-skip-sha256."
    fi

    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        rm -f "$sha_file" 2>/dev/null || true
        log_fatal "Invalid SHA-256 digest format '${expected}' for ${img_file}."
    fi

    local actual
    actual="$(rvdk_sha256_file "$img_file")"
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$img_file" "$sha_file" 2>/dev/null || true
        log_fatal "SHA-256 MISMATCH on ${img_file}! Expected ${expected}, got ${actual}. Purged untrusted image."
    fi
    log_ok "Verified SHA-256   : ${actual}"
}

rvdk_flash_usage() {
    cat << 'EOF'
Usage:
  rvdk flash list
  rvdk flash <board_tag_or_vendor/board> <medium> <disk_number_or_path> [options]

Options:
  -d, --device <disk>          Target disk number (macOS: 4 or /dev/disk4) or block path (Linux: /dev/sdX)
  -i, --image <path>           Flash a local image file instead of cached/mirror image
      --sha256 <hex64>         Expected SHA-256 digest for custom or remote image
      --insecure-skip-sha256   Bypass mandatory SHA-256 verification (NOT recommended)
      --allow-non-removable    Allow targeting non-USB/MMC drives on Linux (still blocks OS/swap disks)
      --force                  Override the 256 GiB large-drive safety ceiling
  -y, --yes                    Skip interactive confirmation prompt
  -h, --help                   Show this help message
EOF
}

rvdk_flash_main() {
    if [[ "${1:-}" == "list" || "${1:-}" == "--list" ]]; then
        rvdk_flash_list
        return 0
    fi

    local board_query=""
    local medium=""
    local target_arg=""
    local image_path=""
    local cli_sha256=""
    local skip_sha256="false"
    local allow_non_removable="false"
    local force_large_disk="false"
    local skip_confirm="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --board)               board_query="${2:-}"; shift 2 ;;
            --medium)              medium="${2:-}"; shift 2 ;;
            -d|--device)           target_arg="${2:-}"; shift 2 ;;
            -i|--image)            image_path="${2:-}"; shift 2 ;;
            --sha256)              cli_sha256="${2:-}"; shift 2 ;;
            --insecure-skip-sha256) skip_sha256="true"; shift ;;
            --allow-non-removable) allow_non_removable="true"; shift ;;
            --force)               force_large_disk="true"; shift ;;
            -y|--yes)              skip_confirm="true"; shift ;;
            -h|--help)             rvdk_flash_usage; return 0 ;;
            -*)                    log_fatal "Unknown flag: $1" ;;
            *)
                if [[ -z "$board_query" ]]; then
                    board_query="$1"
                elif [[ -z "$medium" ]]; then
                    medium="$1"
                elif [[ -z "$target_arg" ]]; then
                    target_arg="$1"
                else
                    log_fatal "Unexpected positional argument: $1 (use --image /path/to/img for custom images)"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$board_query" || -z "$medium" ]]; then
        rvdk_flash_usage
        exit 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        log_fatal "python3 is required to parse board media manifests."
    fi

    local manifest_path=""
    if ! manifest_path="$(_rvdk_flash_resolve_manifest "$board_query")"; then
        log_fatal "Unknown board '${board_query}'. Run 'rvdk flash list' to view supported boards."
    fi

    local parsed_spec
    if ! parsed_spec="$(python3 - "$manifest_path" "$medium" << 'PY'
import json, sys
path, med = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    doc = json.load(fh)
media = doc.get("media") or {}
if med not in media:
    avail = ", ".join(sorted(media.keys())) if media else "none"
    sys.stderr.write(f"Unsupported medium '{med}' for {doc.get('board')}. Available: {avail}\n")
    sys.exit(2)
m = media[med]
mode = m.get("mode") or ("uboot_ext4" if m.get("uboot_payload") else "raw")
fields = [
    doc.get("board", ""),
    doc.get("tag", ""),
    doc.get("name", ""),
    mode,
    m.get("image", ""),
    m.get("sha256", ""),
    m.get("url", ""),
    m.get("fallback_url", ""),
    m.get("fallback_sha256", ""),
    m.get("uboot_payload", ""),
    m.get("fs_label", ""),
    str(m.get("min_size_gib", 8)),
    "\n".join(m.get("post_flash_notes") or []),
]
for item in fields[:-1]:
    print(item.replace("\n", " "))
print("---NOTES---")
if fields[-1]:
    print(fields[-1])
PY
)"; then
        log_fatal "Failed to resolve medium '${medium}' in ${manifest_path}."
    fi

    local board_id board_tag board_name flash_mode default_img manifest_sha custom_url fallback_url fallback_sha uboot_payload fs_label min_size_gib
    {
        IFS= read -r board_id
        IFS= read -r board_tag
        IFS= read -r board_name
        IFS= read -r flash_mode
        IFS= read -r default_img
        IFS= read -r manifest_sha
        IFS= read -r custom_url
        IFS= read -r fallback_url
        IFS= read -r fallback_sha
        IFS= read -r uboot_payload
        IFS= read -r fs_label
        IFS= read -r min_size_gib
    } <<< "$parsed_spec"
    local post_notes="${parsed_spec#*---NOTES---}"
    post_notes="${post_notes#$'\n'}"

    if [[ -z "$target_arg" ]]; then
        log_fatal "Missing target disk identifier for ${board_name} (${medium}). Run 'diskutil list external physical' (macOS) or 'lsblk' (Linux), then pass <disk>."
    fi

    rvdk_resolve_caller
    local os_type
    os_type="$(uname -s)"
    local cache_dir="${RVDK_CACHE_DIR:-}"
    if [[ -z "$cache_dir" ]]; then
        if [[ "${EUID:-$(id -u)}" -eq 0 ]] || [[ -d /var/cache/rvdk && -w /var/cache/rvdk ]]; then
            cache_dir="/var/cache/rvdk"
        elif [[ "$os_type" == "Darwin" ]]; then
            cache_dir="${REAL_HOME}/Library/Caches/rvdk"
        else
            cache_dir="${XDG_CACHE_HOME:-${REAL_HOME}/.cache}/rvdk"
        fi
    fi
    local mirror_url="${RVDK_MIRROR_URL:-https://github.com/drewv-labs/riscv-data-kit/releases/download/rvdk-v1}"
    [[ "$min_size_gib" =~ ^[0-9]+$ ]] || min_size_gib=8
    local min_bytes=$(( min_size_gib * 1024 * 1024 * 1024 ))
    local max_safe_bytes=$(( 256 * 1024 * 1024 * 1024 ))

    # ==========================================================================
    # 1. PLATFORM-SPECIFIC DEVICE RESOLUTION & HARDWARE SAFETY INTERLOCKS
    # ==========================================================================
    local block_dev="" raw_dev="" media_name="" disk_bytes=0 mkfs_ext4=""

    if [[ "$os_type" == "Darwin" ]]; then
        local disk_num="$target_arg"
        disk_num="${disk_num#/dev/}"
        disk_num="${disk_num#r}"
        disk_num="${disk_num#disk}"
        case "$disk_num" in
            ""|*[!0-9]*)
                log_fatal "Invalid macOS disk identifier '${target_arg}' (expected disk number like '4' or '/dev/disk4')."
                ;;
        esac
        if (( disk_num == 0 || disk_num == 1 )); then
            log_fatal "Safety Interlock: /dev/disk${disk_num} is reserved for macOS internal system storage. Aborting!"
        fi

        block_dev="/dev/disk${disk_num}"
        raw_dev="/dev/rdisk${disk_num}"

        local disk_info
        disk_info="$(diskutil info "$block_dev" 2>/dev/null || true)"
        [[ -z "$disk_info" ]] && log_fatal "Device ${block_dev} does not exist. Check 'diskutil list external physical'."

        local is_internal is_removable disk_size_line
        is_internal="$(awk -F': *' '/Device Location:/ {print $2}' <<< "$disk_info" | xargs)"
        is_removable="$(awk -F': *' '/Removable Media:/ {print $2}' <<< "$disk_info" | xargs)"
        media_name="$(awk -F': *' '/Device \/ Media Name:/ {print $2}' <<< "$disk_info" | xargs)"
        disk_size_line="$(awk -F': *' '/Disk Size:/ {print $2}' <<< "$disk_info" | xargs)"
        disk_bytes="$(grep -oE '\([0-9]+ Bytes\)' <<< "$disk_size_line" | tr -dc '0-9' || echo 0)"
        [[ -z "$disk_bytes" ]] && disk_bytes=0

        if [[ "$is_internal" == "Internal" && "$is_removable" != "Removable" ]]; then
            log_fatal "Safety Interlock: ${block_dev} (${media_name}) is an INTERNAL non-removable drive! Aborting."
        fi

        if [[ "$flash_mode" == "uboot_ext4" ]]; then
            local brew_e2fs=""
            brew_e2fs="$(brew --prefix e2fsprogs 2>/dev/null || true)"
            if [[ -z "$brew_e2fs" ]]; then
                if [[ -x /opt/homebrew/opt/e2fsprogs/sbin/mkfs.ext4 ]]; then
                    brew_e2fs="/opt/homebrew/opt/e2fsprogs"
                elif [[ -x /usr/local/opt/e2fsprogs/sbin/mkfs.ext4 ]]; then
                    brew_e2fs="/usr/local/opt/e2fsprogs"
                fi
            fi
            mkfs_ext4="${brew_e2fs}/sbin/mkfs.ext4"
            [[ ! -x "$mkfs_ext4" ]] && log_fatal "macOS requires Homebrew e2fsprogs to build U-Boot ext4 media. Run: brew install e2fsprogs"
        fi

        log_info "Target macOS Media : ${block_dev} -> ${raw_dev} (${media_name} | ${disk_size_line})"
    else
        case "$target_arg" in
            ""|*[!0-9]*) ;;
            *) log_fatal "On Linux, specify the full block device path (e.g., /dev/sdX)." ;;
        esac
        block_dev="$target_arg"
        raw_dev="$target_arg"
        [[ ! -b "$block_dev" ]] && log_fatal "Block device not found: ${block_dev}"

        local mnt
        while IFS= read -r mnt; do
            [[ -z "$mnt" ]] && continue
            case "$mnt" in
                /|/boot|/boot/*|/usr|/var|/home|"[SWAP]")
                    log_fatal "Safety Interlock: ${block_dev} backs critical system mount/swap (${mnt})! Aborting."
                    ;;
            esac
        done < <(lsblk -rn -o MOUNTPOINTS "$block_dev" 2>/dev/null || lsblk -rn -o MOUNTPOINT "$block_dev" 2>/dev/null || true)

        if [[ "$allow_non_removable" != "true" ]]; then
            local rm_flag hotplug_flag tran_type
            rm_flag="$(lsblk -dn -o RM "$block_dev" 2>/dev/null | head -n1 | tr -dc '0-9' || echo 0)"
            hotplug_flag="$(lsblk -dn -o HOTPLUG "$block_dev" 2>/dev/null | head -n1 | tr -dc '0-9' || echo 0)"
            tran_type="$(lsblk -dn -o TRAN "$block_dev" 2>/dev/null | head -n1 | tr '[:upper:]' '[:lower:]' | xargs || true)"
            if [[ "${rm_flag:-0}" != "1" && "${hotplug_flag:-0}" != "1" && "$tran_type" != "usb" && "$tran_type" != "mmc" ]]; then
                log_fatal "Safety Interlock: ${block_dev} is not flagged as removable/USB/MMC (RM=${rm_flag:-0}, HOTPLUG=${hotplug_flag:-0}, TRAN=${tran_type:-none}). Pass --allow-non-removable if intentional."
            fi
        fi

        disk_bytes="$(lsblk -b -dn -o SIZE "$block_dev" 2>/dev/null | head -n1 | tr -dc '0-9' || echo 0)"
        [[ -z "$disk_bytes" ]] && disk_bytes=0
        media_name="$(lsblk -dn -o VENDOR,MODEL,SIZE "$block_dev" 2>/dev/null | xargs || echo "$block_dev")"
        if [[ "$flash_mode" == "uboot_ext4" ]]; then
            mkfs_ext4="$(command -v mkfs.ext4 || echo /sbin/mkfs.ext4)"
            [[ ! -x "$mkfs_ext4" ]] && log_fatal "mkfs.ext4 (e2fsprogs) is required to build U-Boot ext4 media."
        fi

        log_info "Target Linux Media : ${raw_dev} (${media_name})"
    fi

    if (( disk_bytes > 0 && disk_bytes < min_bytes )); then
        log_fatal "Target media (${media_name}) is smaller than minimum ${min_size_gib} GiB required for ${board_name}."
    fi

    if (( disk_bytes > max_safe_bytes )) && [[ "$force_large_disk" != "true" ]]; then
        log_fatal "Safety Interlock: ${block_dev} (${media_name}) exceeds 256 GiB. Pass --force if wiping a large drive is intentional."
    fi

    # ==========================================================================
    # 2. RESOLVE IMAGE & FAIL-CLOSED SHA-256 VERIFICATION
    # ==========================================================================
    if [[ -n "$image_path" ]]; then
        image_path="${image_path/#\~/$REAL_HOME}"
        [[ ! -f "$image_path" ]] && log_fatal "Custom image file not found: ${image_path}"
        log_info "Using custom image : ${image_path}"
        if [[ -n "$cli_sha256" ]]; then
            _rvdk_flash_verify_sha256 "$image_path" "" "" "$cli_sha256" "$skip_sha256" "$REAL_USER"
        fi
    else
        [[ -z "$default_img" ]] && log_fatal "No default image configured for ${board_id} (${medium}). Pass --image /path/to/img."
        mkdir -p "$cache_dir"
        image_path="${cache_dir}/${default_img}"
        local sha_path="${image_path}.sha256"
        local primary_url="${custom_url:-${mirror_url}/${default_img}}"
        local active_url="$primary_url"
        local active_pinned_sha="${cli_sha256:-$manifest_sha}"

        if [[ -f "$image_path" ]]; then
            log_ok "Found cached image : ${image_path}"
        elif [[ -n "$fallback_url" && -f "${cache_dir}/$(basename "$fallback_url")" ]]; then
            image_path="${cache_dir}/$(basename "$fallback_url")"
            sha_path="${image_path}.sha256"
            active_url="$fallback_url"
            active_pinned_sha="${cli_sha256:-$fallback_sha}"
            log_ok "Found cached upstream image: ${image_path}"
        else
            log_info "Downloading ${primary_url}..."
            if curl -fL --retry 3 -C - "$primary_url" -o "${image_path}.part"; then
                mv -f "${image_path}.part" "$image_path"
                chown "$REAL_USER" "$image_path" 2>/dev/null || true
                log_ok "Cached ${image_path}"
            elif [[ -n "$fallback_url" ]]; then
                rm -f "${image_path}.part" 2>/dev/null || true
                log_warn "Primary mirror unreachable; falling back to ${fallback_url}..."
                image_path="${cache_dir}/$(basename "$fallback_url")"
                sha_path="${image_path}.sha256"
                active_url="$fallback_url"
                active_pinned_sha="${cli_sha256:-$fallback_sha}"
                curl -fL --retry 3 -C - "$fallback_url" -o "${image_path}.part"
                mv -f "${image_path}.part" "$image_path"
                chown "$REAL_USER" "$image_path" 2>/dev/null || true
                log_ok "Cached fallback image ${image_path}"
            else
                rm -f "${image_path}.part" 2>/dev/null || true
                log_fatal "Failed to download ${primary_url}."
            fi
        fi

        _rvdk_flash_verify_sha256 "$image_path" "$sha_path" "${active_url}.sha256" "$active_pinned_sha" "$skip_sha256" "$REAL_USER"
    fi

    local img_size_bytes
    img_size_bytes="$(wc -c < "$image_path" | tr -dc '0-9')"
    if (( img_size_bytes < 104857600 )); then
        log_fatal "Safety Interlock: ${image_path} is only ${img_size_bytes} bytes (< 100 MiB). Refusing to write!"
    fi

    if [[ "$skip_confirm" != "true" ]]; then
        printf "\033[1;33m[CONFIRM]\033[0m Erase %s (%s) and write %s (%s)? [y/N]: " \
            "$block_dev" "$media_name" "$(basename "$image_path")" "$flash_mode"
        local reply=""
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

    # ==========================================================================
    # 3. EXECUTE FLASH STRATEGY (raw vs uboot_ext4)
    # ==========================================================================
    trap '_rvdk_flash_cleanup' EXIT INT TERM

    if [[ "$flash_mode" == "uboot_ext4" ]]; then
        [[ -z "$uboot_payload" ]] && log_fatal "uboot_ext4 mode requires 'uboot_payload' in ${manifest_path}."
        if [[ -z "$fs_label" ]]; then
            local upper_tag
            upper_tag="$(printf '%s' "$board_tag" | tr '[:lower:]-' '[:upper:]_')"
            fs_label="${upper_tag:0:8}_REC"
        fi

        local stage_dir="${cache_dir}/${board_tag}-${medium}-stage"
        mkdir -p "$stage_dir"
        local staged_img="${stage_dir}/${uboot_payload}"

        if [[ "$image_path" == "$staged_img" ]]; then
            log_info "Using uncompressed payload at ${staged_img}"
        elif [[ -f "$staged_img" && "$staged_img" -nt "$image_path" ]]; then
            log_ok "Reusing decompressed staging payload: ${staged_img}"
        else
            log_info "Decompressing U-Boot payload to ${staged_img}..."
            find "$stage_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
            case "$image_path" in
                *.zst) zstd -dc "$image_path" > "$staged_img" ;;
                *.xz)  xz -dc "$image_path" > "$staged_img" ;;
                *.bz2) bzip2 -dc "$image_path" > "$staged_img" ;;
                *.gz)  gzip -dc "$image_path" > "$staged_img" ;;
                *)     cp "$image_path" "$staged_img" ;;
            esac
            chown -R "$REAL_USER" "$stage_dir" 2>/dev/null || true
            log_ok "Staged payload: ${staged_img}"
        fi

        sudo -v
        if [[ "$os_type" == "Darwin" ]]; then
            log_info "Unmounting ${block_dev} and building U-Boot ext4 filesystem (${fs_label})..."
            diskutil unmountDisk "$block_dev"
            sudo "$mkfs_ext4" -F -b 4096 -L "$fs_label" \
                -O ^metadata_csum_seed,^orphan_file \
                -d "$stage_dir" \
                "$raw_dev"
            sync
            diskutil eject "$block_dev"
        else
            log_info "Unmounting ${block_dev}, formatting U-Boot ext4 (${fs_label}), and staging payload..."
            local part
            for part in "${block_dev}"*; do
                sudo umount "$part" 2>/dev/null || true
            done
            sudo wipefs -a "$block_dev"
            sudo "$mkfs_ext4" -F -b 4096 -L "$fs_label" \
                -O ^metadata_csum_seed,^orphan_file \
                "$block_dev"

            _RVDK_FLASH_TMP_MNT="$(mktemp -d "/tmp/rvdk_${board_tag}_usb.XXXXXX")"
            sudo mount "$block_dev" "$_RVDK_FLASH_TMP_MNT"
            sudo cp -v "$staged_img" "${_RVDK_FLASH_TMP_MNT}/${uboot_payload}"
            sync
            sudo umount "$_RVDK_FLASH_TMP_MNT"
            rmdir "$_RVDK_FLASH_TMP_MNT"
            _RVDK_FLASH_TMP_MNT=""
            sudo eject "$block_dev" 2>/dev/null || true
        fi
    elif [[ "$flash_mode" == "raw" ]]; then
        if [[ "$os_type" == "Darwin" ]]; then
            log_info "Unmounting ${block_dev} via diskutil..."
            diskutil unmountDisk "$block_dev"
        else
            log_info "Unmounting active partitions on ${block_dev}..."
            local part
            for part in "${block_dev}"*; do
                sudo umount "$part" 2>/dev/null || true
            done
        fi

        local dd_bs="4M"
        [[ "$os_type" == "Darwin" ]] && dd_bs="4m"

        log_info "Streaming image to ${raw_dev} (bs=${dd_bs})..."
        sudo -v
        case "$image_path" in
            *.zst) zstd -dc "$image_path" | sudo dd of="$raw_dev" bs="$dd_bs" status=progress ;;
            *.bz2) bzip2 -dc "$image_path" | sudo dd of="$raw_dev" bs="$dd_bs" status=progress ;;
            *.xz)  xz -dc "$image_path" | sudo dd of="$raw_dev" bs="$dd_bs" status=progress ;;
            *.gz)  gzip -dc "$image_path" | sudo dd of="$raw_dev" bs="$dd_bs" status=progress ;;
            *)     sudo dd if="$image_path" of="$raw_dev" bs="$dd_bs" status=progress ;;
        esac

        log_info "Flushing write buffers (sync)..."
        sync
        if [[ "$os_type" == "Darwin" ]]; then
            diskutil eject "$block_dev"
        else
            sudo eject "$block_dev" 2>/dev/null || true
        fi
    else
        log_fatal "Unsupported flash mode '${flash_mode}' in ${manifest_path}."
    fi

    log_ok "${board_name} (${medium}) media is ready on ${block_dev}!"
    if [[ -n "$post_notes" ]]; then
        printf "\n%s\n" "$post_notes"
    fi
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    rvdk_flash_main "$@"
fi
