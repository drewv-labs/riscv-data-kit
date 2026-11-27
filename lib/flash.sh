#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Metadata-Driven Removable Media Flasher (macOS & Linux)
# Path: riscv-data-kit/lib/flash.sh
#
# Reads board flash specifications from `boards/<vendor>/<board>/media.json` and
# executes hardware-interlocked, cryptographically verified media preparation:
#   • mode = "raw"          : Stream-decompresses (.zst/.xz/.bz2/.gz/raw) to block dev,
#                             wipes stale backup GPT headers on reused cards, seeds
#                             cold-RTC clock floor (/usr/lib/clock-epoch +
#                             /etc/fake-hwclock.data + timesync), applies deterministic
#                             ext4 rootfs labels (rvdk_sd_root / rvdk_emmc_root),
#                             de-collides dual-media UUID + PARTUUID, and provisions
#                             SpacemiT/Ky eMMC hardware boot0 SPL.
#   • mode = "uboot_ext4"   : Builds U-Boot compatible ext4 stick (-O ^metadata_csum_seed,^orphan_file)
#   • mode = "sd_bootstrap" : Delegates on-board SD -> eMMC bootstrap to board script
#
# Security & Safety Interlocks:
#   • Fail-closed SHA-256 verification on all downloaded images (requires pinned
#     digest in media.json / --sha256, or explicit --allow-remote-sha256)
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

[[ -n "${_RVDK_FLASH_SH_LOADED:-}" ]] && return 0
_RVDK_FLASH_SH_LOADED=1

_FLASH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_FLASH_REPO_ROOT="$(cd "${_FLASH_LIB_DIR}/.." && pwd)"

# @RVDK_INLINE_LIBS: common storage_guard
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_FLASH_LIB_DIR" && -f "${_FLASH_LIB_DIR}/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_FLASH_LIB_DIR}/common.sh"
    fi
fi
if [[ -z "${_RVDK_STORAGE_GUARD_SH_LOADED:-}" ]]; then
    if [[ -n "$_FLASH_LIB_DIR" && -f "${_FLASH_LIB_DIR}/storage_guard.sh" ]]; then
        # shellcheck source=lib/storage_guard.sh
        source "${_FLASH_LIB_DIR}/storage_guard.sh"
    fi
fi
rvdk_log_init "RVDK:FLASH"

if [[ "$(uname -s)" == "Darwin" ]]; then
    for _rvdk_hb_dir in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin; do
        if [[ -d "$_rvdk_hb_dir" && ":${PATH}:" != *":${_rvdk_hb_dir}:"* ]]; then
            PATH="${PATH}:${_rvdk_hb_dir}"
        fi
    done
    unset _rvdk_hb_dir
    export PATH
fi

_rvdk_require_decompressor() {
    local img_file="$1"
    local os_type="$2"
    local req_bin="" brew_pkg="" apt_pkg=""
    case "$img_file" in
        *.zst) req_bin="zstd";  brew_pkg="zstd";  apt_pkg="zstd" ;;
        *.xz)  req_bin="xz";    brew_pkg="xz";    apt_pkg="xz-utils" ;;
        *.bz2) req_bin="bzip2"; brew_pkg="bzip2"; apt_pkg="bzip2" ;;
        *.gz)  req_bin="gzip";  brew_pkg="gzip";  apt_pkg="gzip" ;;
        *)     return 0 ;;
    esac
    if ! command -v "$req_bin" >/dev/null 2>&1; then
        if [[ "$os_type" == "Darwin" ]]; then
            log_fatal "Missing '${req_bin}' required to decompress $(basename "$img_file"). Run: brew install ${brew_pkg}"
        else
            log_fatal "Missing '${req_bin}' required to decompress $(basename "$img_file"). Install '${apt_pkg}'."
        fi
    fi
}

_rvdk_run_priv() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

_rvdk_dev_priv() {
    local dev="$1"
    shift
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$@"
    elif [[ "$(uname -s)" == "Darwin" && -r "$dev" && -w "$dev" ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

_RVDK_FLASH_TMP_MNT="${_RVDK_FLASH_TMP_MNT:-}"
_RVDK_FLASH_PART_FILE="${_RVDK_FLASH_PART_FILE:-}"
_RVDK_FLASH_BOOT0_SYS="${_RVDK_FLASH_BOOT0_SYS:-}"

_rvdk_flash_cleanup() {
    if [[ -n "${_RVDK_FLASH_BOOT0_SYS:-}" && -f "${_RVDK_FLASH_BOOT0_SYS}" ]]; then
        printf '1\n' | _rvdk_run_priv tee "${_RVDK_FLASH_BOOT0_SYS}" >/dev/null 2>&1 || true
        _RVDK_FLASH_BOOT0_SYS=""
    fi
    if [[ -n "${_RVDK_FLASH_PART_FILE:-}" && -f "${_RVDK_FLASH_PART_FILE}" ]]; then
        rm -f "${_RVDK_FLASH_PART_FILE}" 2>/dev/null || true
        _RVDK_FLASH_PART_FILE=""
    fi
    if [[ -n "${_RVDK_FLASH_TMP_MNT:-}" && -d "${_RVDK_FLASH_TMP_MNT}" ]]; then
        local _tf
        for _tf in ${_RVDK_TMPFILES[@]+"${_RVDK_TMPFILES[@]}"}; do
            if [[ -n "$_tf" && "$_tf" == "${_RVDK_FLASH_TMP_MNT}/"* ]]; then
                _rvdk_run_priv rm -f "$_tf" 2>/dev/null || true
            fi
        done
        if [[ -d "${_RVDK_FLASH_TMP_MNT}/boot" ]]; then
            _rvdk_run_priv umount "${_RVDK_FLASH_TMP_MNT}/boot" 2>/dev/null || true
        fi
        if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null; then
            _rvdk_run_priv umount "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null || _rvdk_run_priv umount -l "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null || true
        else
            _rvdk_run_priv umount "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null || true
        fi
        rmdir "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null || true
        _RVDK_FLASH_TMP_MNT=""
    fi
    if [[ "${_RVDK_CLEANUP_RUNNING:-0}" != "1" ]]; then
        if typeset -f _rvdk_cleanup_tmpfiles >/dev/null 2>&1; then
            _rvdk_cleanup_tmpfiles || true
        fi
    fi
}

_rvdk_flash_register_cleanup() {
    if typeset -f rvdk_register_cleanup >/dev/null 2>&1; then
        rvdk_register_cleanup _rvdk_flash_cleanup
    elif [[ -z "$(trap -p EXIT 2>/dev/null || true)" ]]; then
        trap '_rvdk_flash_cleanup' EXIT
        trap '_rvdk_flash_cleanup; trap - EXIT INT; kill -INT $$' INT
        trap '_rvdk_flash_cleanup; trap - EXIT TERM; kill -TERM $$' TERM
    fi
}

_rvdk_flash_curl() {
    local url="$1"
    shift
    if [[ "$url" == https://* ]]; then
        curl --proto '=https' --tlsv1.2 "$@" "$url"
    else
        curl "$@" "$url"
    fi
}

_rvdk_flash_download_to_part() {
    local url="$1"
    local part_file="$2"

    _RVDK_FLASH_PART_FILE="$part_file"
    if [[ -f "$part_file" && ! -L "$part_file" ]]; then
        if _rvdk_flash_curl "$url" -fL --retry 3 -C - -o "$part_file"; then
            return 0
        fi
        log_warn "Resumed download failed for ${url}; purging stale ${part_file} and retrying from byte 0..."
        rm -f "$part_file" 2>/dev/null || true
    elif [[ -e "$part_file" || -L "$part_file" ]]; then
        rm -f "$part_file" 2>/dev/null || true
    fi
    _rvdk_flash_curl "$url" -fL --retry 3 -o "$part_file"
}

# Backwards-compatible wrapper delegating to unified helper in lib/common.sh.
_rvdk_flash_rewrite_label_token() { _rvdk_rewrite_label_token "$@"; }

_rvdk_udev_settle() {
    if command -v udevadm >/dev/null 2>&1; then
        _rvdk_run_priv udevadm settle 2>/dev/null || sleep 1
    else
        sleep 1
    fi
}

_rvdk_flash_unmount_dev_children() {
    local dev="$1"
    local include_base="${2:-false}"
    local child_part
    while IFS= read -r child_part; do
        [[ -n "$child_part" ]] || continue
        _rvdk_run_priv umount "$child_part" 2>/dev/null || true
    done < <(rvdk_list_child_partitions "$dev")
    if [[ "$include_base" == "true" ]]; then
        _rvdk_run_priv umount "$dev" 2>/dev/null || true
    fi
}

_rvdk_flash_dev_in_target_set() {
    local cand="$1"
    local base_dev="$2"
    shift 2
    local cand_real base_real item item_real
    cand_real="$(readlink -f "$cand" 2>/dev/null || printf '%s' "$cand")"
    base_real="$(readlink -f "$base_dev" 2>/dev/null || printf '%s' "$base_dev")"
    if [[ "$cand" == "$base_dev" || ( -n "$cand_real" && -n "$base_real" && "$cand_real" == "$base_real" ) ]]; then
        return 0
    fi
    for item in "$@"; do
        [[ -n "$item" ]] || continue
        if [[ "$cand" == "$item" ]]; then
            return 0
        fi
        item_real="$(readlink -f "$item" 2>/dev/null || printf '%s' "$item")"
        if [[ -n "$cand_real" && -n "$item_real" && "$cand_real" == "$item_real" ]]; then
            return 0
        fi
    done
    return 1
}

rvdk_flash_list() {
    local boards_root="${RVDK_BOARDS_DIR:-${_FLASH_REPO_ROOT}/boards}"
    if ! command -v python3 >/dev/null 2>&1; then
        log_fatal "python3 is required to inspect board media manifests."
    fi
    python3 - "$boards_root" << 'PY'
import glob, json, os, sys

boards_root = sys.argv[1]
paths = sorted(glob.glob(os.path.join(boards_root, "*", "*", "media.json")))
print("RVDK Board Media Catalog (boards/*/*/media.json):")
print("  {:<12} {:<26} {:<10} {:<12} {}".format("TAG", "BOARD", "MEDIUM", "MODE", "DESCRIPTION"))
print("  " + "-" * 90)
for p in paths:
    with open(p, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    tag = data.get("tag", "-")
    board = data.get("board", "-")
    media = data.get("media") or {}
    if not media:
        print("  {:<12} {:<26} {:<10} {:<12} {}".format(tag, board, "-", "-", "(Vendor / onboard storage)"))
        continue
    for m_name, spec in sorted(media.items()):
        mode = spec.get("mode", "uboot_ext4" if spec.get("uboot_payload") else "raw")
        desc = spec.get("description", "")
        print("  {:<12} {:<26} {:<10} {:<12} {}".format(tag, board, m_name, mode, desc))
PY
}

_rvdk_flash_resolve_manifest() {
    local query="$1"
    local boards_root="${RVDK_BOARDS_DIR:-${_FLASH_REPO_ROOT}/boards}"
    if typeset -f rvdk_normalize_board_id >/dev/null 2>&1; then
        query="$(rvdk_normalize_board_id "$query")"
    fi
    if [[ "$query" != *".."* && -f "${boards_root}/${query}/media.json" ]]; then
        printf '%s\n' "${boards_root}/${query}/media.json"
        return 0
    fi
    python3 - "$boards_root" "$query" << 'PY'
import glob, json, os, sys
boards_root, q = sys.argv[1], sys.argv[2].strip().lower()
aliases = {
    "p550": "sifive/p550",
    "premier-p550": "sifive/p550",
    "hifive-premier-p550": "sifive/p550",
    "sifive-p550": "sifive/p550",
    "sifive/p550": "sifive/p550",
    "sifive/hifive-premier-p550": "sifive/p550",
    "unmatched": "sifive/unmatched",
    "unmatchedb": "sifive/unmatched",
    "unmatched-b": "sifive/unmatched",
    "fu740": "sifive/unmatched",
    "hifive-unmatched": "sifive/unmatched",
    "sifive-unmatched": "sifive/unmatched",
    "sifive/unmatched": "sifive/unmatched",
    "megrez": "milkv/megrez",
    "milkv-megrez": "milkv/megrez",
    "milkv/megrez": "milkv/megrez",
    "milk-v/megrez": "milkv/megrez",
    "starpro64": "pine64/starpro64",
    "pine64/starpro64": "pine64/starpro64",
    "vf2-lite": "starfive/vf2-lite",
    "vf2lite": "starfive/vf2-lite",
    "visionfive2-lite": "starfive/vf2-lite",
    "visionfive-2-lite": "starfive/vf2-lite",
    "starfive-vf2-lite": "starfive/vf2-lite",
    "starfive/vf2-lite": "starfive/vf2-lite",
    "vf2": "starfive/vf2",
    "visionfive2": "starfive/vf2",
    "visionfive-2": "starfive/vf2",
    "starfive-vf2": "starfive/vf2",
    "starfive/vf2": "starfive/vf2",
    "starfive/visionfive2": "starfive/vf2",
    "mars": "milkv/mars",
    "milkv-mars": "milkv/mars",
    "milkv/mars": "milkv/mars",
    "milk-v/mars": "milkv/mars",
    "rv2": "orangepi/rv2",
    "opirv2": "orangepi/rv2",
    "orangepi-rv2": "orangepi/rv2",
    "orangepi/rv2": "orangepi/rv2",
    "r2s": "orangepi/r2s",
    "opir2s": "orangepi/r2s",
    "orangepi-r2s": "orangepi/r2s",
    "orangepi/r2s": "orangepi/r2s",
    "rv": "orangepi/rv",
    "opirv": "orangepi/rv",
    "orangepi-rv": "orangepi/rv",
    "orangepi/rv": "orangepi/rv",
    "f3": "bananapi/f3",
    "bpif3": "bananapi/f3",
    "bpi-f3": "bananapi/f3",
    "bananapi-f3": "bananapi/f3",
    "bananapi/f3": "bananapi/f3",
    "bananapi/bpi-f3": "bananapi/f3",
    "banana-pi/f3": "bananapi/f3",
    "cm6": "bananapi/cm6",
    "bpicm6": "bananapi/cm6",
    "bpi-cm6": "bananapi/cm6",
    "bananapi-cm6": "bananapi/cm6",
    "bananapi/cm6": "bananapi/cm6",
    "bananapi/bpi-cm6": "bananapi/cm6",
    "banana-pi/cm6": "bananapi/cm6",
    "jupiter2": "milkv/jupiter2",
    "jptr2": "milkv/jupiter2",
    "milkv-jupiter2": "milkv/jupiter2",
    "milkv/jupiter2": "milkv/jupiter2",
    "milk-v/jupiter2": "milkv/jupiter2",
    "jupiter": "milkv/jupiter",
    "jptr1": "milkv/jupiter",
    "jupiter1": "milkv/jupiter",
    "milkv-jupiter": "milkv/jupiter",
    "milkv/jupiter": "milkv/jupiter",
    "milk-v/jupiter": "milkv/jupiter",
    "aibox-k3": "firefly/aibox-k3",
    "aiboxk3": "firefly/aibox-k3",
    "firefly-k3": "firefly/aibox-k3",
    "firefly-aibox-k3": "firefly/aibox-k3",
    "firefly/aibox-k3": "firefly/aibox-k3",
    "titan": "milkv/titan",
    "dp1000": "milkv/titan",
    "milkv-titan": "milkv/titan",
    "milkv/titan": "milkv/titan",
    "milk-v/titan": "milkv/titan",
    "ultrarisc-titan": "milkv/titan",
    "ultrarisc/titan": "milkv/titan",
    "espressif-esp32p4": "waveshare/esp32-p4-wifi6",
    "espressif/esp32p4": "waveshare/esp32-p4-wifi6",
    "waveshare-esp32-p4-wifi6": "waveshare/esp32-p4-wifi6",
    "waveshare/esp32-p4-wifi6": "waveshare/esp32-p4-wifi6",
    "waveshare-esp32-p4": "waveshare/esp32-p4-wifi6",
    "waveshare/esp32-p4": "waveshare/esp32-p4-wifi6",
    "waveshare-p4": "waveshare/esp32-p4-wifi6",
    "waveshare/p4": "waveshare/esp32-p4-wifi6",
    "esp32-p4-wifi6": "waveshare/esp32-p4-wifi6",
    "esp32-p4-wifi6-dev-kit": "waveshare/esp32-p4-wifi6",
    "esp32-p4": "waveshare/esp32-p4-wifi6",
    "esp32p4": "waveshare/esp32-p4-wifi6",
    "p4": "waveshare/esp32-p4-wifi6",
    "atlantis": "tenstorrent/atlantis",
    "tt-atlantis": "tenstorrent/atlantis",
    "ascalon": "tenstorrent/atlantis",
    "tenstorrent-atlantis": "tenstorrent/atlantis",
    "tenstorrent/atlantis": "tenstorrent/atlantis",
    "blackhole": "tenstorrent/blackhole",
    "tt-blackhole": "tenstorrent/blackhole",
    "tenstorrent-blackhole": "tenstorrent/blackhole",
    "tenstorrent/blackhole": "tenstorrent/blackhole",
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
    local allow_remote_sha="${7:-false}"
    local allow_purge="${8:-false}"

    local expected=""
    if [[ -n "$pinned_sha" ]]; then
        expected="$(printf '%s' "$pinned_sha" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')"
    elif [[ "$allow_remote_sha" == "true" ]]; then
        if [[ ! -s "$sha_file" && -n "$remote_sha_url" ]]; then
            log_info "Fetching same-origin SHA-256 sidecar (${remote_sha_url}) (--allow-remote-sha256)..."
            _rvdk_flash_register_cleanup
            _RVDK_TMPFILES+=("${sha_file}.tmp")
            if ! _rvdk_flash_curl "$remote_sha_url" -fsSL --retry 3 -o "${sha_file}.tmp"; then
                rm -f "${sha_file}.tmp"
                if typeset -f _rvdk_untrack_tmpfile >/dev/null 2>&1; then
                    _rvdk_untrack_tmpfile "${sha_file}.tmp"
                fi
                if [[ "$skip_sha" == "true" ]]; then
                    log_warn "SHA-256 manifest unavailable at ${remote_sha_url}; proceeding ONLY because --insecure-skip-sha256 was set."
                    return 0
                fi
                log_fatal "Fail-closed security check: unable to fetch SHA-256 digest from ${remote_sha_url}. Supply --sha256 <hex> or --insecure-skip-sha256."
            fi
            mv -f "${sha_file}.tmp" "$sha_file"
            if typeset -f _rvdk_untrack_tmpfile >/dev/null 2>&1; then
                _rvdk_untrack_tmpfile "${sha_file}.tmp"
            fi
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
        if [[ -n "$remote_sha_url" ]]; then
            log_fatal "Fail-closed security check: no pinned SHA-256 digest for ${img_file}. Pass --sha256 <hex>, --allow-remote-sha256 (to trust ${remote_sha_url}), or --insecure-skip-sha256."
        fi
        log_fatal "Fail-closed security check: no SHA-256 digest available for ${img_file}. Pass --sha256 <hex> or --insecure-skip-sha256."
    fi

    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        if [[ "$allow_purge" == "true" && -n "$sha_file" ]]; then
            rm -f "$sha_file" 2>/dev/null || true
        fi
        log_fatal "Invalid SHA-256 digest format '${expected}' for ${img_file}."
    fi

    local actual
    actual="$(rvdk_sha256_file "$img_file")"
    if [[ "$actual" != "$expected" ]]; then
        if [[ "$allow_purge" == "true" ]]; then
            rm -f "$img_file" 2>/dev/null || true
            if [[ -n "$sha_file" ]]; then
                rm -f "$sha_file" 2>/dev/null || true
            fi
            log_fatal "SHA-256 MISMATCH on ${img_file}! Expected ${expected}, got ${actual}. Purged untrusted image."
        fi
        log_fatal "SHA-256 MISMATCH on ${img_file}! Expected ${expected}, got ${actual}. Leaving source file untouched."
    fi
    log_ok "Verified SHA-256   : ${actual}"
}

_rvdk_find_macos_e2fs_dir() {
    local brew_e2fs=""
    brew_e2fs="$(brew --prefix e2fsprogs 2>/dev/null || true)"
    if [[ -n "$brew_e2fs" && -d "${brew_e2fs}/sbin" ]]; then
        printf '%s\n' "${brew_e2fs}/sbin"
        return 0
    fi
    if [[ -d /opt/homebrew/opt/e2fsprogs/sbin ]]; then
        printf '%s\n' "/opt/homebrew/opt/e2fsprogs/sbin"
        return 0
    fi
    if [[ -d /usr/local/opt/e2fsprogs/sbin ]]; then
        printf '%s\n' "/usr/local/opt/e2fsprogs/sbin"
        return 0
    fi
    return 1
}

# Inspect a candidate partition device with tune2fs -l and print "<vol_name>|<fs_bytes>" if valid ext4
_rvdk_probe_ext4_superblock() {
    local tune2fs_bin="$1"
    local part_dev="$2"
    local info=""
    info="$(_rvdk_dev_priv "$part_dev" "$tune2fs_bin" -l "$part_dev" 2>/dev/null || true)"
    [[ -z "$info" ]] && return 1
    if ! grep -qiE 'Filesystem magic number:[[:space:]]*0xEF53' <<< "$info"; then
        return 1
    fi
    local vol_name block_cnt block_sz fs_bytes
    vol_name="$(awk -F': *' '/^Filesystem volume name:/ {print $2; exit}' <<< "$info" | xargs || true)"
    [[ "$vol_name" == "<none>" ]] && vol_name=""
    block_cnt="$(awk -F': *' '/^Block count:/ {print $2; exit}' <<< "$info" | tr -dc '0-9' || echo 0)"
    block_sz="$(awk -F': *' '/^Block size:/ {print $2; exit}' <<< "$info" | tr -dc '0-9' || echo 4096)"
    [[ -z "$block_cnt" ]] && block_cnt=0
    [[ -z "$block_sz" ]] && block_sz=4096
    fs_bytes=$(( block_cnt * block_sz ))
    printf '%s|%s\n' "$vol_name" "$fs_bytes"
    return 0
}

# Select the true ext4 rootfs partition across 1-part (p1 opi_root/armbi_root),
# 2-part (p1 boot + p2 rootfs), 4-part (VF2 p4), or 6-part (SpacemiT p5 bootfs + p6 rootfs) layouts.
_rvdk_select_ext4_root_slice() {
    local tune2fs_bin="$1"
    local preferred_idx="$2"
    shift 2

    local min_root_bytes=$(( 256 * 1024 * 1024 ))
    local best_pref_dev=""
    local best_size_dev=""
    local best_size_bytes=0
    local cand probe vol_lc fs_bytes

    if [[ "$preferred_idx" =~ ^[0-9]+$ && "$preferred_idx" -gt 0 ]]; then
        for cand in "$@"; do
            if [[ "$cand" =~ (s|p)?${preferred_idx}$ ]]; then
                if probe="$(_rvdk_probe_ext4_superblock "$tune2fs_bin" "$cand")"; then
                    vol_lc="$(tr '[:upper:]' '[:lower:]' <<< "${probe%%|*}")"
                    fs_bytes="${probe#*|}"
                    case "$vol_lc" in
                        boot|bootfs|opi_boot|armbi_boot|efi) ;;
                        *)
                            if (( fs_bytes >= min_root_bytes )); then
                                printf '%s\n' "$cand"
                                return 0
                            fi
                            ;;
                    esac
                fi
            fi
        done
    fi

    for cand in "$@"; do
        [[ -e "$cand" ]] || continue
        if ! probe="$(_rvdk_probe_ext4_superblock "$tune2fs_bin" "$cand")"; then
            continue
        fi
        vol_lc="$(tr '[:upper:]' '[:lower:]' <<< "${probe%%|*}")"
        fs_bytes="${probe#*|}"
        case "$vol_lc" in
            boot|bootfs|opi_boot|armbi_boot|efi)
                continue
                ;;
            opi_root|armbi_root|rootfs|cloudimg-rootfs|rvdk_*_root)
                if (( fs_bytes >= min_root_bytes )); then
                    best_pref_dev="$cand"
                fi
                ;;
        esac
        if (( fs_bytes >= min_root_bytes && fs_bytes > best_size_bytes )); then
            best_size_bytes="$fs_bytes"
            best_size_dev="$cand"
        fi
    done

    if [[ -n "$best_pref_dev" ]]; then
        printf '%s\n' "$best_pref_dev"
        return 0
    fi
    if [[ -n "$best_size_dev" ]]; then
        printf '%s\n' "$best_size_dev"
        return 0
    fi
    return 1
}

# Harden vendor raw ext4 superblocks & fstab before first boot on reused media
_rvdk_harden_ext4_superblock() {
    local tune2fs_bin="$1"
    local e2fsck_bin="$2"
    local debugfs_bin="$3"
    local root_slice="$4"

    [[ -n "$tune2fs_bin" && -x "$tune2fs_bin" ]] || return 0

    local sb_info=""
    sb_info="$(_rvdk_dev_priv "$root_slice" "$tune2fs_bin" -l "$root_slice" 2>/dev/null || true)"
    [[ -z "$sb_info" ]] && return 0

    local feats="" def_opts="" sb_changed="false" notes=()
    feats="$(awk -F': *' '/^Filesystem features:/ {print $2; exit}' <<< "$sb_info" || true)"
    def_opts="$(awk -F': *' '/^Default mount options:/ {print $2; exit}' <<< "$sb_info" || true)"

    if [[ -n "$feats" && " $feats " != *" metadata_csum "* && " $feats " != *" uninit_bg "* ]]; then
        if _rvdk_dev_priv "$root_slice" "$tune2fs_bin" -O uninit_bg "$root_slice" >/dev/null 2>&1; then
            sb_changed="true"
            notes+=("+uninit_bg")
        fi
    fi

    if [[ " $def_opts " == *" journal_data_writeback "* ]]; then
        if _rvdk_dev_priv "$root_slice" "$tune2fs_bin" -o ^journal_data_writeback,journal_data_ordered "$root_slice" >/dev/null 2>&1; then
            sb_changed="true"
            notes+=("data=ordered")
        fi
    fi

    if [[ -n "$debugfs_bin" && -x "$debugfs_bin" ]]; then
        local cur_fstab=""
        cur_fstab="$(_rvdk_dev_priv "$root_slice" "$debugfs_bin" -R "cat /etc/fstab" "$root_slice" 2>/dev/null || true)"
        if grep -Eq '^[[:space:]]*[^#[:space:]]+[[:space:]]+/[[:space:]]+ext4[[:space:]]+[^[:space:]]*commit=[0-9]{2,}' <<< "$cur_fstab"; then
            local stripped_fstab=""
            stripped_fstab="$(_rvdk_strip_fstab_commit <<< "$cur_fstab")"
            if [[ "$stripped_fstab" != "$cur_fstab" ]]; then
                _rvdk_flash_register_cleanup
                local tmp_fstab tmp_fcmds
                tmp_fstab="$(mktemp "/tmp/rvdk_fstab.XXXXXX")"
                tmp_fcmds="$(mktemp "/tmp/rvdk_fcmds.XXXXXX")"
                _RVDK_TMPFILES+=("$tmp_fstab" "$tmp_fcmds")
                printf '%s\n' "$stripped_fstab" > "$tmp_fstab"
                cat <<EOF > "$tmp_fcmds"
rm /etc/fstab
write ${tmp_fstab} /etc/fstab
sif /etc/fstab uid 0
sif /etc/fstab gid 0
sif /etc/fstab mode 0100644
EOF
                chmod 0644 "$tmp_fstab" "$tmp_fcmds"
                if _rvdk_dev_priv "$root_slice" "$debugfs_bin" -w -f "$tmp_fcmds" "$root_slice" >/dev/null 2>&1; then
                    sb_changed="true"
                    notes+=("-commit=600")
                fi
                rm -f "$tmp_fstab" "$tmp_fcmds"
                if typeset -f _rvdk_untrack_tmpfile >/dev/null 2>&1; then
                    _rvdk_untrack_tmpfile "$tmp_fstab"
                    _rvdk_untrack_tmpfile "$tmp_fcmds"
                fi
            fi
        fi
    fi

    if [[ "$sb_changed" == "true" ]]; then
        if [[ -n "$e2fsck_bin" && -x "$e2fsck_bin" ]]; then
            local fsck_rc=0
            _rvdk_dev_priv "$root_slice" "$e2fsck_bin" -pf "$root_slice" >/dev/null 2>&1 || fsck_rc=$?
            if (( fsck_rc > 1 )); then
                log_warn "e2fsck returned ${fsck_rc} while hardening ${root_slice}; verify media health."
            fi
        fi
        log_ok "Hardened ext4 rootfs : ${root_slice} (${notes[*]})"
    fi
}

# Seed host UTC timestamp into unmounted ext4 `/usr/lib/clock-epoch` (consumed by
# systemd PID 1 `clock_apply_epoch` at t=0 even without fake-hwclock or timesyncd),
# `/etc/fake-hwclock.data`, `/var/lib/systemd/timesync/clock`, and superblock
# check-time so batteryless RISC-V SBCs boot inside the valid TLS certificate window.
_rvdk_seed_ext4_rtc_floor() {
    local debugfs_bin="$1"
    local tune2fs_bin="$2"
    local root_slice="$3"

    local now_epoch=""
    now_epoch="$(date -u +%s 2>/dev/null || echo 0)"
    [[ "$now_epoch" =~ ^[0-9]+$ ]] && (( now_epoch >= 1767225600 )) || return 0

    local utc_now ts_fmt
    utc_now="$(date -u '+%Y-%m-%d %H:%M:%S')"
    ts_fmt="$(date -u '+%Y%m%d%H%M%S')"
    local seeded="false"

    if [[ -n "$debugfs_bin" && -x "$debugfs_bin" ]]; then
        local has_etc="" has_usr_lib="" has_timesync=""
        has_etc="$(_rvdk_dev_priv "$root_slice" "$debugfs_bin" -R "stat /etc" "$root_slice" 2>/dev/null || true)"
        has_usr_lib="$(_rvdk_dev_priv "$root_slice" "$debugfs_bin" -R "stat /usr/lib" "$root_slice" 2>/dev/null || true)"
        has_timesync="$(_rvdk_dev_priv "$root_slice" "$debugfs_bin" -R "stat /var/lib/systemd/timesync" "$root_slice" 2>/dev/null || true)"

        if grep -q "Type: directory" <<< "$has_etc" \
           || grep -q "Type: directory" <<< "$has_usr_lib" \
           || grep -q "Type: directory" <<< "$has_timesync"; then
            _rvdk_flash_register_cleanup
            local tmp_rtc tmp_empty tmp_cmds
            tmp_rtc="$(mktemp "/tmp/rvdk_rtc.XXXXXX")"
            tmp_empty="$(mktemp "/tmp/rvdk_ts.XXXXXX")"
            tmp_cmds="$(mktemp "/tmp/rvdk_dbg.XXXXXX")"
            _RVDK_TMPFILES+=("$tmp_rtc" "$tmp_empty" "$tmp_cmds")
            printf '%s\n' "$utc_now" > "$tmp_rtc"
            : > "$tmp_empty"
            : > "$tmp_cmds"
            if grep -q "Type: directory" <<< "$has_usr_lib"; then
                cat <<EOF >> "$tmp_cmds"
rm /usr/lib/clock-epoch
write ${tmp_empty} /usr/lib/clock-epoch
sif /usr/lib/clock-epoch uid 0
sif /usr/lib/clock-epoch gid 0
sif /usr/lib/clock-epoch mode 0100644
sif /usr/lib/clock-epoch mtime ${ts_fmt}
sif /usr/lib/clock-epoch ctime ${ts_fmt}
EOF
            fi
            if grep -q "Type: directory" <<< "$has_etc"; then
                cat <<EOF >> "$tmp_cmds"
rm /etc/fake-hwclock.data
write ${tmp_rtc} /etc/fake-hwclock.data
sif /etc/fake-hwclock.data uid 0
sif /etc/fake-hwclock.data gid 0
sif /etc/fake-hwclock.data mode 0100644
sif /etc/fake-hwclock.data mtime ${ts_fmt}
sif /etc/fake-hwclock.data ctime ${ts_fmt}
EOF
            fi
            if grep -q "Type: directory" <<< "$has_timesync"; then
                local ts_uid="0" ts_gid="0"
                ts_uid="$(awk '{for(i=1;i<=NF;i++) if($i=="User:") {print $(i+1); exit}}' <<< "$has_timesync" | tr -dc '0-9' || true)"
                ts_gid="$(awk '{for(i=1;i<=NF;i++) if($i=="Group:") {print $(i+1); exit}}' <<< "$has_timesync" | tr -dc '0-9' || true)"
                [[ "$ts_uid" =~ ^[0-9]+$ ]] || ts_uid="0"
                [[ "$ts_gid" =~ ^[0-9]+$ ]] || ts_gid="0"
                cat <<EOF >> "$tmp_cmds"
rm /var/lib/systemd/timesync/clock
write ${tmp_empty} /var/lib/systemd/timesync/clock
sif /var/lib/systemd/timesync/clock uid ${ts_uid}
sif /var/lib/systemd/timesync/clock gid ${ts_gid}
sif /var/lib/systemd/timesync/clock mode 0100644
sif /var/lib/systemd/timesync/clock mtime ${ts_fmt}
sif /var/lib/systemd/timesync/clock ctime ${ts_fmt}
EOF
            fi
            chmod 0644 "$tmp_rtc" "$tmp_empty" "$tmp_cmds"
            if _rvdk_dev_priv "$root_slice" "$debugfs_bin" -w -f "$tmp_cmds" "$root_slice" >/dev/null 2>&1; then
                seeded="true"
            fi
            rm -f "$tmp_rtc" "$tmp_empty" "$tmp_cmds"
            if typeset -f _rvdk_untrack_tmpfile >/dev/null 2>&1; then
                _rvdk_untrack_tmpfile "$tmp_rtc"
                _rvdk_untrack_tmpfile "$tmp_empty"
                _rvdk_untrack_tmpfile "$tmp_cmds"
            fi
        fi
    fi

    if [[ -n "$tune2fs_bin" && -x "$tune2fs_bin" ]]; then
        if _rvdk_dev_priv "$root_slice" "$tune2fs_bin" -T now "$root_slice" >/dev/null 2>&1; then
            seeded="true"
        fi
    fi

    if [[ "$seeded" == "true" ]]; then
        log_ok "Seeded cold-RTC floor: ${root_slice} -> ${utc_now} UTC"
    fi
}

_rvdk_flash_rewrite_target_configs() {
    local mnt_root="$1"
    local old_uuid="$2"
    local new_uuid="$3"
    local old_label="$4"
    local new_label="$5"
    local quiet="${6:-false}"

    local canon_root=""
    canon_root="$(readlink -f "$mnt_root" 2>/dev/null || true)"
    [[ -n "$canon_root" ]] || return 1

    local check_dir canon_dir
    for check_dir in etc boot boot/extlinux boot/boot boot/boot/extlinux boot/spacemit boot/efi; do
        if [[ -e "${mnt_root}/${check_dir}" || -L "${mnt_root}/${check_dir}" ]]; then
            canon_dir="$(readlink -f "${mnt_root}/${check_dir}" 2>/dev/null || true)"
            if [[ -z "$canon_dir" || ( "$canon_dir" != "$canon_root" && "$canon_dir" != "${canon_root}/"* ) ]]; then
                log_err "Refusing post-flash config rewrite: /${check_dir} escapes target rootfs mount (${canon_root})."
                return 1
            fi
        fi
    done

    local -a cfg_list=(
        etc/fstab
        boot/orangepiEnv.txt
        boot/armbianEnv.txt
        boot/env_k1-x.txt
        boot/spacemit/env_k1-x.txt
        boot/extlinux/extlinux.conf
        boot/boot/extlinux/extlinux.conf
        boot/efi/extlinux.conf
        boot/uEnv.txt
    )

    local cfg_rel cfg_full canon_cfg
    for cfg_rel in "${cfg_list[@]}"; do
        cfg_full="${mnt_root}/${cfg_rel}"
        if [[ -L "$cfg_full" ]]; then
            log_err "Refusing post-flash config rewrite: target /${cfg_rel} is a symbolic link."
            return 1
        fi
        if [[ -e "$cfg_full" ]]; then
            canon_cfg="$(readlink -f "$cfg_full" 2>/dev/null || true)"
            canon_dir="$(readlink -f "$(dirname "$cfg_full")" 2>/dev/null || true)"
            if [[ -z "$canon_cfg" || "$canon_cfg" != "${canon_root}/"* || -z "$canon_dir" || ( "$canon_dir" != "$canon_root" && "$canon_dir" != "${canon_root}/"* ) ]]; then
                log_err "Refusing post-flash config rewrite: target /${cfg_rel} resolves outside ${canon_root}."
                return 1
            fi
        fi
    done

    for cfg_rel in "${cfg_list[@]}"; do
        cfg_full="${mnt_root}/${cfg_rel}"
        [[ ! -L "$cfg_full" && -f "$cfg_full" ]] || continue
        canon_cfg="$(readlink -f "$cfg_full" 2>/dev/null || true)"
        if [[ -z "$canon_cfg" || "$canon_cfg" != "${canon_root}/"* || ! -f "$canon_cfg" || -L "$canon_cfg" ]]; then
            return 1
        fi

        if [[ -n "$old_uuid" && -n "$new_uuid" && "$old_uuid" != "$new_uuid" ]] && _rvdk_run_priv grep -qF "$old_uuid" "$canon_cfg" 2>/dev/null; then
            local cur_cfg="" new_cfg="" cfg_dir="" cfg_tmp=""
            cur_cfg="$(_rvdk_run_priv cat "$canon_cfg" 2>/dev/null || true)"
            if [[ -n "$cur_cfg" ]]; then
                new_cfg="$(_rvdk_rewrite_literal "$old_uuid" "$new_uuid" <<< "$cur_cfg")"
                if [[ "$new_cfg" != "$cur_cfg" ]]; then
                    cfg_dir="$(dirname "$canon_cfg")"
                    cfg_tmp="$(_rvdk_run_priv mktemp "${cfg_dir}/.$(basename "$canon_cfg").rvdk.XXXXXX")"
                    _RVDK_TMPFILES+=("$cfg_tmp")
                    if printf '%s\n' "$new_cfg" | _rvdk_run_priv tee "$cfg_tmp" >/dev/null; then
                        _rvdk_run_priv chmod --reference="$canon_cfg" "$cfg_tmp" 2>/dev/null || _rvdk_run_priv chmod 0644 "$cfg_tmp" 2>/dev/null || true
                        _rvdk_run_priv mv -f "$cfg_tmp" "$canon_cfg"
                        if typeset -f _rvdk_untrack_tmpfile >/dev/null 2>&1; then
                            _rvdk_untrack_tmpfile "$cfg_tmp"
                        fi
                        if [[ "$quiet" != "true" ]]; then
                            log_ok "Updated root UUID in target /${cfg_rel}"
                        fi
                    else
                        _rvdk_run_priv rm -f "$cfg_tmp" 2>/dev/null || true
                        if typeset -f _rvdk_untrack_tmpfile >/dev/null 2>&1; then
                            _rvdk_untrack_tmpfile "$cfg_tmp"
                        fi
                        return 1
                    fi
                fi
            fi
        fi

        if [[ -n "$old_label" && -n "$new_label" && "$old_label" != "$new_label" ]] && _rvdk_run_priv grep -qF "LABEL=${old_label}" "$canon_cfg" 2>/dev/null; then
            local cur_cfg="" new_cfg="" cfg_dir="" cfg_tmp=""
            cur_cfg="$(_rvdk_run_priv cat "$canon_cfg" 2>/dev/null || true)"
            if [[ -n "$cur_cfg" ]]; then
                new_cfg="$(_rvdk_rewrite_label_token "$old_label" "$new_label" <<< "$cur_cfg")"
                if [[ "$new_cfg" != "$cur_cfg" ]]; then
                    cfg_dir="$(dirname "$canon_cfg")"
                    cfg_tmp="$(_rvdk_run_priv mktemp "${cfg_dir}/.$(basename "$canon_cfg").rvdk.XXXXXX")"
                    _RVDK_TMPFILES+=("$cfg_tmp")
                    if printf '%s\n' "$new_cfg" | _rvdk_run_priv tee "$cfg_tmp" >/dev/null; then
                        _rvdk_run_priv chmod --reference="$canon_cfg" "$cfg_tmp" 2>/dev/null || _rvdk_run_priv chmod 0644 "$cfg_tmp" 2>/dev/null || true
                        _rvdk_run_priv mv -f "$cfg_tmp" "$canon_cfg"
                        if typeset -f _rvdk_untrack_tmpfile >/dev/null 2>&1; then
                            _rvdk_untrack_tmpfile "$cfg_tmp"
                        fi
                        if [[ "$quiet" != "true" ]]; then
                            log_ok "Updated root LABEL in target /${cfg_rel} (${old_label} -> ${new_label})"
                        fi
                    else
                        _rvdk_run_priv rm -f "$cfg_tmp" 2>/dev/null || true
                        if typeset -f _rvdk_untrack_tmpfile >/dev/null 2>&1; then
                            _rvdk_untrack_tmpfile "$cfg_tmp"
                        fi
                        return 1
                    fi
                fi
            fi
        fi
    done
    return 0
}

_rvdk_flash_rollback_target_configs() {
    local root_slice="$1"
    local boot_slice="$2"
    local revert_from_uuid="$3"
    local revert_to_uuid="$4"
    local revert_from_lbl="$5"
    local revert_to_lbl="$6"

    _RVDK_FLASH_TMP_MNT="$(mktemp -d "/tmp/rvdk_postflash.XXXXXX")"
    if ! _rvdk_run_priv mount "$root_slice" "$_RVDK_FLASH_TMP_MNT"; then
        log_err "Rollback failed: unable to remount ${root_slice} to restore boot configs."
        rmdir "$_RVDK_FLASH_TMP_MNT" 2>/dev/null || true
        _RVDK_FLASH_TMP_MNT=""
        return 1
    fi
    if [[ -n "$boot_slice" ]]; then
        if [[ -L "${_RVDK_FLASH_TMP_MNT}/boot" || ! -d "${_RVDK_FLASH_TMP_MNT}/boot" ]] || ! _rvdk_run_priv mount "$boot_slice" "${_RVDK_FLASH_TMP_MNT}/boot"; then
            log_err "Rollback failed: unable to remount ${boot_slice} to restore /boot configs."
            _rvdk_run_priv umount "$_RVDK_FLASH_TMP_MNT" 2>/dev/null || true
            rmdir "$_RVDK_FLASH_TMP_MNT" 2>/dev/null || true
            _RVDK_FLASH_TMP_MNT=""
            return 1
        fi
    fi

    local rb_ok="true"
    if ! _rvdk_flash_rewrite_target_configs "$_RVDK_FLASH_TMP_MNT" "$revert_from_uuid" "$revert_to_uuid" "$revert_from_lbl" "$revert_to_lbl" "true"; then
        log_err "Rollback failed: unable to restore original boot configs on ${root_slice}."
        rb_ok="false"
    fi
    sync
    if [[ -n "$boot_slice" ]]; then
        if ! _rvdk_run_priv umount "${_RVDK_FLASH_TMP_MNT}/boot"; then
            log_err "Rollback warning: failed to unmount ${boot_slice} cleanly."
            rb_ok="false"
        fi
    fi
    if ! _rvdk_run_priv umount "$_RVDK_FLASH_TMP_MNT"; then
        log_err "Rollback warning: failed to unmount ${root_slice} cleanly."
        rb_ok="false"
    fi
    rmdir "$_RVDK_FLASH_TMP_MNT" 2>/dev/null || true
    _RVDK_FLASH_TMP_MNT=""
    [[ "$rb_ok" == "true" ]]
}

_rvdk_flash_postprocess_raw() {
    local os_type="$1"
    local block_dev="$2"
    local root_part_hint="$3"
    local root_label="$4"
    local regen_uuid="$5"
    local emmc_boot0="$6"
    local board_arch="${7:-}"

    if [[ -n "$root_label" && ! "$root_label" =~ ^[a-zA-Z0-9_.-]{1,16}$ ]]; then
        log_fatal "Invalid ext4 root label '${root_label}' (max 16 chars: [a-zA-Z0-9_.-])."
    fi

    if [[ "$os_type" == "Darwin" ]]; then
        local e2fs_sbin="" e2label_bin="" tune2fs_bin="" debugfs_bin="" e2fsck_bin=""
        if e2fs_sbin="$(_rvdk_find_macos_e2fs_dir)"; then
            e2label_bin="${e2fs_sbin}/e2label"
            tune2fs_bin="${e2fs_sbin}/tune2fs"
            debugfs_bin="${e2fs_sbin}/debugfs"
            e2fsck_bin="${e2fs_sbin}/e2fsck"
        else
            e2label_bin="$(command -v e2label || true)"
            tune2fs_bin="$(command -v tune2fs || true)"
            debugfs_bin="$(command -v debugfs || true)"
            e2fsck_bin="$(command -v e2fsck || true)"
        fi

        if [[ ! -x "$tune2fs_bin" ]]; then
            if [[ -n "$root_label" ]]; then
                log_warn "Homebrew e2fsprogs not found on macOS; skipping host e2label ('brew install e2fsprogs'). On-target 'sudo rvdk bsp' will apply '${root_label}'."
            fi
            return 0
        fi

        local slices=()
        local s_cand
        for _ in 1 2 3 4 5 6; do
            diskutil unmountDisk "$block_dev" >/dev/null 2>&1 || true
            slices=()
            for s_cand in "${block_dev}"s[0-9]*; do
                [[ -e "$s_cand" ]] && slices+=("$s_cand")
            done
            (( ${#slices[@]} > 0 )) && break
            sleep 1
        done

        if (( ${#slices[@]} == 0 )); then
            [[ -n "$root_label" && "$board_arch" != "riscv32" ]] && log_warn "No partition slices detected on ${block_dev} after image stream; skipping host ext4 hygiene."
            return 0
        fi

        local root_slice=""
        if ! root_slice="$(_rvdk_select_ext4_root_slice "$tune2fs_bin" "$root_part_hint" "${slices[@]}")"; then
            [[ -n "$root_label" && "$board_arch" != "riscv32" ]] && log_warn "Could not locate an ext4 rootfs slice on ${block_dev}; skipping host ext4 hygiene."
            return 0
        fi

        diskutil unmountDisk "$block_dev" >/dev/null 2>&1 || true
        _rvdk_harden_ext4_superblock "$tune2fs_bin" "$e2fsck_bin" "$debugfs_bin" "$root_slice"

        if [[ -n "$root_label" && -x "$e2label_bin" ]]; then
            local cur_mac_lbl=""
            cur_mac_lbl="$(_rvdk_dev_priv "$root_slice" "$e2label_bin" "$root_slice" 2>/dev/null | tr -d '[:space:]' || true)"
            if [[ "$cur_mac_lbl" == "$root_label" ]]; then
                log_skip "Ext4 rootfs label already '${root_label}' on ${root_slice}"
            else
                log_warn "Skipping host e2label on macOS (${root_slice}: '${cur_mac_lbl:-<none>}' -> '${root_label}'): offline /etc/fstab & /boot/* patching is unavailable on macOS. On-target 'sudo rvdk bsp' will converge labels safely."
            fi
        fi

        _rvdk_seed_ext4_rtc_floor "$debugfs_bin" "$tune2fs_bin" "$root_slice"
        if [[ -n "$e2fsck_bin" && -x "$e2fsck_bin" ]]; then
            _rvdk_dev_priv "$root_slice" "$e2fsck_bin" -pf "$root_slice" >/dev/null 2>&1 || true
        fi
        sync
        return 0
    fi

    # Linux post-flash processing (partition re-read, UUID/PARTUUID de-collision, eMMC boot0 SPL, RTC floor, e2label)
    _rvdk_flash_register_cleanup
    _rvdk_run_priv partprobe "$block_dev" 2>/dev/null || _rvdk_run_priv blockdev --rereadpt "$block_dev" 2>/dev/null || true
    _rvdk_udev_settle

    _rvdk_flash_unmount_dev_children "$block_dev" "false"

    # De-collide MBR 32-bit disk identifier when regenerating UUID so PARTUUID (`ubootpart=`) is unique across SD & eMMC
    if [[ "$regen_uuid" == "true" ]] && command -v sfdisk >/dev/null 2>&1; then
        local pt_type=""
        pt_type="$(_rvdk_run_priv blkid -s PTTYPE -o value "$block_dev" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
        if [[ "$pt_type" == "dos" ]]; then
            local new_mbr_id=""
            new_mbr_id="0x$(od -An -N4 -tx4 /dev/urandom 2>/dev/null | tr -d '[:space:]' || printf '7276646b')"
            if _rvdk_run_priv sfdisk --disk-id "$block_dev" "$new_mbr_id" >/dev/null 2>&1; then
                _rvdk_run_priv partprobe "$block_dev" 2>/dev/null || _rvdk_run_priv blockdev --rereadpt "$block_dev" 2>/dev/null || true
                _rvdk_udev_settle
                log_ok "Assigned unique MBR disk identifier on ${block_dev}: ${new_mbr_id} (de-colliding PARTUUID)"
            fi
        fi
    fi

    local e2label_bin tune2fs_bin e2fsck_bin debugfs_bin
    e2label_bin="$(command -v e2label || echo /sbin/e2label)"
    tune2fs_bin="$(command -v tune2fs || echo /sbin/tune2fs)"
    e2fsck_bin="$(command -v e2fsck || echo /sbin/e2fsck)"
    debugfs_bin="$(command -v debugfs || echo /sbin/debugfs)"

    local linux_parts=()
    local lp_path
    while IFS= read -r lp_path; do
        [[ -n "$lp_path" && -b "$lp_path" ]] && linux_parts+=("$lp_path")
    done < <(rvdk_list_child_partitions "$block_dev")

    if (( ${#linux_parts[@]} == 0 )); then
        [[ -n "$root_label" && "$board_arch" != "riscv32" ]] && log_warn "No child partitions detected on ${block_dev}; skipping post-flash filesystem hygiene."
        return 0
    fi

    local root_slice=""
    if [[ -x "$tune2fs_bin" ]]; then
        root_slice="$(_rvdk_select_ext4_root_slice "$tune2fs_bin" "$root_part_hint" "${linux_parts[@]}" || true)"
    fi
    if [[ -z "$root_slice" ]]; then
        [[ -n "$root_label" && "$board_arch" != "riscv32" ]] && log_warn "Could not locate ext4 rootfs partition on ${block_dev}; skipping post-flash filesystem hygiene."
        return 0
    fi

    local old_uuid="" old_label=""
    old_uuid="$(_rvdk_run_priv blkid -s UUID -o value "$root_slice" 2>/dev/null || true)"
    old_label="$(_rvdk_run_priv blkid -s LABEL -o value "$root_slice" 2>/dev/null || true)"

    # Automatically trigger UUID regeneration if another block device on the host already shares old_uuid
    local uuid_collision="false"
    if [[ -n "$old_uuid" ]]; then
        local other_dev
        while IFS= read -r other_dev; do
            [[ -z "$other_dev" || "$other_dev" == "$root_slice" ]] && continue
            if _rvdk_flash_dev_in_target_set "$other_dev" "$block_dev" "${linux_parts[@]}"; then
                continue
            fi
            uuid_collision="true"
            break
        done < <(_rvdk_run_priv blkid -t "UUID=${old_uuid}" -o device 2>/dev/null || true)
    fi

    local new_uuid=""
    if [[ "$regen_uuid" == "true" || "$uuid_collision" == "true" ]]; then
        if [[ -x "$tune2fs_bin" && -x "$e2fsck_bin" ]]; then
            local fsck_rc=0
            _rvdk_run_priv "$e2fsck_bin" -pf "$root_slice" >/dev/null 2>&1 || fsck_rc=$?
            if (( fsck_rc <= 1 )); then
                new_uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
                if [[ -z "$new_uuid" || "$new_uuid" == "$old_uuid" ]]; then
                    log_warn "Unable to generate unique UUID for ${root_slice}; preserving existing UUID."
                    new_uuid=""
                fi
            else
                log_warn "e2fsck returned ${fsck_rc} on ${root_slice}; preserving existing UUID."
                new_uuid=""
            fi
        fi
    fi

    local want_label_rewrite="false"
    if [[ -n "$old_label" && -n "$root_label" && "$old_label" != "$root_label" ]]; then
        want_label_rewrite="true"
    fi

    local need_mount="false"
    [[ -n "$new_uuid" ]] && need_mount="true"
    [[ "$emmc_boot0" == "true" && -b "${block_dev}boot0" ]] && need_mount="true"
    [[ "$want_label_rewrite" == "true" ]] && need_mount="true"

    local boot_slice=""
    if [[ "$need_mount" == "true" ]]; then
        # Detect separate /boot partition if the image uses a 2-partition layout
        local cand_p cand_lbl
        for cand_p in "${linux_parts[@]}"; do
            [[ "$cand_p" == "$root_slice" ]] && continue
            cand_lbl="$(_rvdk_run_priv blkid -s LABEL -o value "$cand_p" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
            case "$cand_lbl" in
                boot|bootfs|opi_boot|armbi_boot)
                    boot_slice="$cand_p"
                    break
                    ;;
            esac
        done

        _RVDK_FLASH_TMP_MNT="$(mktemp -d "/tmp/rvdk_postflash.XXXXXX")"
        if ! _rvdk_run_priv mount "$root_slice" "$_RVDK_FLASH_TMP_MNT"; then
            log_fatal "Failed to mount flashed rootfs ${root_slice} during post-flash convergence."
        fi

        if [[ -n "$boot_slice" ]]; then
            if [[ -L "${_RVDK_FLASH_TMP_MNT}/boot" ]]; then
                log_fatal "Refusing to mount ${boot_slice}: /boot on ${root_slice} is a symbolic link."
            fi
            if [[ ! -d "${_RVDK_FLASH_TMP_MNT}/boot" ]]; then
                log_fatal "Failed to mount separate /boot partition ${boot_slice}: /boot directory missing on ${root_slice}."
            fi
            if ! _rvdk_run_priv mount "$boot_slice" "${_RVDK_FLASH_TMP_MNT}/boot"; then
                log_fatal "Failed to mount separate /boot partition ${boot_slice} during post-flash convergence."
            fi
        fi

        local rewrite_old_lbl="" rewrite_new_lbl=""
        if [[ "$want_label_rewrite" == "true" ]]; then
            rewrite_old_lbl="$old_label"
            rewrite_new_lbl="$root_label"
        fi

        if ! _rvdk_flash_rewrite_target_configs "$_RVDK_FLASH_TMP_MNT" "$old_uuid" "$new_uuid" "$rewrite_old_lbl" "$rewrite_new_lbl" "false"; then
            _rvdk_flash_rewrite_target_configs "$_RVDK_FLASH_TMP_MNT" "$new_uuid" "$old_uuid" "$rewrite_new_lbl" "$rewrite_old_lbl" "true" || true
            log_fatal "Failed to update target boot configuration files on ${root_slice}; aborted before mutating superblock."
        fi

        # SpacemiT K1/M1/Ky X1 hardware eMMC boot0 SPL provisioning (bootinfo_emmc.bin @ LBA 0 + FSBL.bin @ LBA 1)
        if [[ "$emmc_boot0" == "true" && -b "${block_dev}boot0" ]]; then
            local uboot_dir="" cand_uboot
            for cand_uboot in \
                "${_RVDK_FLASH_TMP_MNT}"/usr/lib/linux-u-boot-* \
                /usr/lib/linux-u-boot-*; do
                if [[ -f "${cand_uboot}/bootinfo_emmc.bin" && -f "${cand_uboot}/FSBL.bin" ]]; then
                    uboot_dir="$cand_uboot"
                    break
                fi
            done

            if [[ -n "$uboot_dir" ]]; then
                local boot0_dev="${block_dev}boot0"
                local boot0_sys
                boot0_sys="/sys/block/$(basename "$boot0_dev")/force_ro"
                if [[ -f "$boot0_sys" ]]; then
                    _RVDK_FLASH_BOOT0_SYS="$boot0_sys"
                    printf '0\n' | _rvdk_run_priv tee "$boot0_sys" >/dev/null
                fi
                _rvdk_run_priv dd if="${uboot_dir}/bootinfo_emmc.bin" of="$boot0_dev" bs=512 seek=0 conv=notrunc,fsync status=none
                _rvdk_run_priv dd if="${uboot_dir}/FSBL.bin" of="$boot0_dev" bs=512 seek=1 conv=notrunc,fsync status=none
                if [[ -f "$boot0_sys" ]]; then
                    printf '1\n' | _rvdk_run_priv tee "$boot0_sys" >/dev/null
                    _RVDK_FLASH_BOOT0_SYS=""
                fi
                log_ok "Programmed SpacemiT/Ky eMMC BootROM SPL (${boot0_dev} <- bootinfo_emmc.bin + FSBL.bin)"
            else
                log_warn "Could not find bootinfo_emmc.bin + FSBL.bin for ${block_dev}boot0; verify eMMC SPL before rebooting."
            fi
        fi

        sync
        if [[ -n "$boot_slice" ]]; then
            if ! _rvdk_run_priv umount "${_RVDK_FLASH_TMP_MNT}/boot"; then
                log_fatal "Failed to unmount separate /boot partition ${boot_slice} cleanly; aborting superblock mutation."
            fi
        fi
        if ! _rvdk_run_priv umount "$_RVDK_FLASH_TMP_MNT"; then
            log_fatal "Failed to unmount rootfs ${root_slice} cleanly; aborting superblock mutation."
        fi
        rmdir "$_RVDK_FLASH_TMP_MNT"
        _RVDK_FLASH_TMP_MNT=""
    fi

    if [[ -n "$new_uuid" ]]; then
        local rollback_from_lbl="" rollback_to_lbl=""
        if [[ "$want_label_rewrite" == "true" ]]; then
            rollback_from_lbl="$root_label"
            rollback_to_lbl="$old_label"
        fi
        local post_fsck_rc=0
        _rvdk_run_priv "$e2fsck_bin" -pf "$root_slice" >/dev/null 2>&1 || post_fsck_rc=$?
        if (( post_fsck_rc > 1 )); then
            log_err "Post-unmount e2fsck returned ${post_fsck_rc} on ${root_slice}; reverting rewritten boot configs."
            _rvdk_flash_rollback_target_configs "$root_slice" "$boot_slice" "$new_uuid" "$old_uuid" "$rollback_from_lbl" "$rollback_to_lbl" || true
            log_fatal "Aborted ext4 UUID update on ${root_slice} due to post-unmount e2fsck failure (rc=${post_fsck_rc})."
        fi
        if ! _rvdk_run_priv "$tune2fs_bin" -U "$new_uuid" "$root_slice" >/dev/null; then
            log_err "tune2fs -U failed on ${root_slice}; reverting rewritten boot configs."
            _rvdk_flash_rollback_target_configs "$root_slice" "$boot_slice" "$new_uuid" "$old_uuid" "$rollback_from_lbl" "$rollback_to_lbl" || true
            log_fatal "Aborted ext4 UUID update on ${root_slice} after tune2fs -U failure."
        fi
        log_ok "Assigned unique ext4 UUID on ${root_slice}: ${new_uuid} (preventing SD/eMMC UUID collision)"
    fi

    _rvdk_harden_ext4_superblock "$tune2fs_bin" "$e2fsck_bin" "$debugfs_bin" "$root_slice"

    if [[ -n "$root_label" && -x "$e2label_bin" ]]; then
        _rvdk_run_priv "$e2label_bin" "$root_slice" "$root_label"
        local linux_lbl=""
        linux_lbl="$(_rvdk_run_priv "$e2label_bin" "$root_slice" 2>/dev/null | tr -d '[:space:]' || true)"
        [[ "$linux_lbl" != "$root_label" ]] && log_fatal "Failed to verify ext4 label '${root_label}' on ${root_slice}."
        log_ok "Labeled ext4 rootfs : ${root_slice} -> ${linux_lbl}"
    fi

    _rvdk_seed_ext4_rtc_floor "$debugfs_bin" "$tune2fs_bin" "$root_slice"
    if [[ -x "$e2fsck_bin" ]]; then
        _rvdk_run_priv "$e2fsck_bin" -pf "$root_slice" >/dev/null 2>&1 || true
    fi
    sync
}

rvdk_flash_usage() {
    cat << 'EOF'
Usage:
  rvdk flash list
  rvdk flash <board_tag_or_vendor/board> <medium> <disk_number_or_path> [options]

Options:
  -d, --device <disk>          Target disk number (macOS: 4 or /dev/disk4) or block path (Linux: /dev/sdX, /dev/mmcblk2)
  -i, --image <path>           Flash a local image file instead of cached/mirror image
      --sha256 <hex64>         Expected SHA-256 digest for custom or remote image
      --allow-remote-sha256    Trust same-origin .sha256 sidecar when media.json has no pinned digest
      --root-label <label>     Override post-flash ext4 root filesystem label (max 16 chars)
      --no-root-label          Skip post-flash ext4 root filesystem labeling
      --insecure-skip-sha256   Bypass mandatory SHA-256 verification (NOT recommended)
      --allow-non-removable    Allow targeting non-USB/MMC drives on Linux (still blocks OS/swap disks)
  -t, --tune <data|ai|iot>     Target DeepTune profile (sd_bootstrap media)
      --hostname <name>        Optional target hostname override (sd_bootstrap media)
      --stage-dir <dir>        Stage config/artifacts directory (sd_bootstrap media)
      --stage-only [<dir>]     Stage artifacts without touching block devices (sd_bootstrap media)
  -n, --dry-run                Dry-run preflight check (sd_bootstrap media)
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
    local cli_root_label=""
    local bootstrap_hostname=""
    local bootstrap_tune=""
    local bootstrap_stage_dir=""
    local bootstrap_stage_only="false"
    local dry_run="false"
    local want_help="false"
    local skip_root_label="false"
    local allow_remote_sha256="false"
    local skip_sha256="false"
    local allow_non_removable="false"
    local force_large_disk="false"
    local skip_confirm="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --board)                 [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."; board_query="${2:-}"; shift 2 ;;
            --medium)                [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."; medium="${2:-}"; shift 2 ;;
            -d|--device)             [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."; target_arg="${2:-}"; shift 2 ;;
            -i|--image)              [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."; image_path="${2:-}"; shift 2 ;;
            --sha256)                [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."; cli_sha256="${2:-}"; shift 2 ;;
            --allow-remote-sha256)   allow_remote_sha256="true"; shift ;;
            --root-label)            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."; cli_root_label="${2:-}"; shift 2 ;;
            --no-root-label)         skip_root_label="true"; shift ;;
            --hostname)              [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."; bootstrap_hostname="${2:-}"; shift 2 ;;
            -t|--tune)               [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."; bootstrap_tune="${2:-}"; shift 2 ;;
            --tune=*)                bootstrap_tune="${1#*=}"; [[ -z "$bootstrap_tune" ]] && log_fatal "Option '--tune=' requires an argument."; shift ;;
            --stage-dir)             [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."; bootstrap_stage_dir="${2:-}"; shift 2 ;;
            --stage-dir=*)           bootstrap_stage_dir="${1#*=}"; [[ -z "$bootstrap_stage_dir" ]] && log_fatal "Option '--stage-dir=' requires an argument."; shift ;;
            --stage-only=*)          bootstrap_stage_only="true"; bootstrap_stage_dir="${1#*=}"; [[ -z "$bootstrap_stage_dir" ]] && log_fatal "Option '--stage-only=' requires an argument."; shift ;;
            --stage-only)
                bootstrap_stage_only="true"
                if [[ -n "${2:-}" && "${2:-}" != -* && -z "$bootstrap_stage_dir" && ! "${2:-}" =~ ^(/dev/|[0-9]+$) ]]; then
                    bootstrap_stage_dir="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            -n|--dry-run)            dry_run="true"; shift ;;
            --insecure-skip-sha256)  skip_sha256="true"; shift ;;
            --allow-non-removable)   allow_non_removable="true"; shift ;;
            --force)                 force_large_disk="true"; shift ;;
            -y|--yes)                skip_confirm="true"; shift ;;
            -h|--help)               want_help="true"; shift ;;
            -*)                      log_fatal "Unknown flag: $1" ;;
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

    if [[ "$want_help" == "true" && ( -z "$board_query" || -z "$medium" ) ]]; then
        rvdk_flash_usage
        return 0
    fi
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
raw_min_img = m.get("min_image_mib")
min_img_val = 100 if raw_min_img is None else raw_min_img
raw_min_size = m.get("min_size_gib")
min_size_val = 8 if raw_min_size is None else raw_min_size
fields = [
    doc.get("board", ""),
    doc.get("tag", ""),
    doc.get("name", ""),
    doc.get("arch", "") or "",
    mode,
    m.get("script", ""),
    m.get("image", ""),
    m.get("sha256", ""),
    m.get("url", ""),
    m.get("fallback_url", ""),
    m.get("fallback_sha256", ""),
    m.get("uboot_payload", ""),
    m.get("fs_label", ""),
    str(m.get("root_part", "auto")),
    m.get("root_label", ""),
    "true" if m.get("regenerate_root_uuid") else "false",
    "true" if m.get("emmc_uboot_boot0") else "false",
    str(min_size_val),
    str(min_img_val),
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

    local board_id board_tag board_name board_arch flash_mode script_rel default_img manifest_sha custom_url fallback_url fallback_sha uboot_payload fs_label root_part manifest_root_label regen_root_uuid emmc_uboot_boot0 min_size_gib min_image_mib
    {
        IFS= read -r board_id
        IFS= read -r board_tag
        IFS= read -r board_name
        IFS= read -r board_arch
        IFS= read -r flash_mode
        IFS= read -r script_rel
        IFS= read -r default_img
        IFS= read -r manifest_sha
        IFS= read -r custom_url
        IFS= read -r fallback_url
        IFS= read -r fallback_sha
        IFS= read -r uboot_payload
        IFS= read -r fs_label
        IFS= read -r root_part
        IFS= read -r manifest_root_label
        IFS= read -r regen_root_uuid
        IFS= read -r emmc_uboot_boot0
        IFS= read -r min_size_gib
        IFS= read -r min_image_mib
    } <<< "$parsed_spec"
    local post_notes="${parsed_spec#*---NOTES---}"
    post_notes="${post_notes#$'\n'}"

    local effective_root_label="${cli_root_label:-$manifest_root_label}"
    [[ "$skip_root_label" == "true" ]] && effective_root_label=""

    if [[ "$flash_mode" == "sd_bootstrap" && "${RVDK_FLASH_FORCE_RAW:-0}" == "1" ]]; then
        flash_mode="raw"
    fi

    if [[ "$flash_mode" == "sd_bootstrap" ]]; then
        local manifest_dir bootstrap_script
        manifest_dir="$(cd "$(dirname "$manifest_path")" && pwd)"
        bootstrap_script="${manifest_dir}/${script_rel}"
        [[ -z "$script_rel" || ! -f "$bootstrap_script" ]] && log_fatal "sd_bootstrap mode requires an existing 'script' in ${manifest_path}."
        local fwd_args=()
        [[ "$want_help" == "true" ]] && fwd_args+=("--help")
        [[ -n "$target_arg" ]] && fwd_args+=("--device" "$target_arg")
        [[ -n "$image_path" ]] && fwd_args+=("--image" "$image_path")
        [[ -n "$cli_sha256" ]] && fwd_args+=("--sha256" "$cli_sha256")
        [[ "$allow_remote_sha256" == "true" ]] && fwd_args+=("--allow-remote-sha256")
        [[ "$skip_sha256" == "true" ]] && fwd_args+=("--insecure-skip-sha256")
        [[ "$allow_non_removable" == "true" ]] && fwd_args+=("--allow-non-removable")
        [[ -n "$effective_root_label" ]] && fwd_args+=("--root-label" "$effective_root_label")
        [[ -n "$bootstrap_hostname" ]] && fwd_args+=("--hostname" "$bootstrap_hostname")
        [[ -n "$bootstrap_tune" ]] && fwd_args+=("--tune" "$bootstrap_tune")
        [[ -n "$bootstrap_stage_dir" ]] && fwd_args+=("--stage-dir" "$bootstrap_stage_dir")
        [[ "$bootstrap_stage_only" == "true" ]] && fwd_args+=("--stage-only")
        [[ "$dry_run" == "true" ]] && fwd_args+=("--dry-run")
        [[ "$force_large_disk" == "true" ]] && fwd_args+=("--force")
        [[ "$skip_confirm" == "true" ]] && fwd_args+=("--yes")
        exec bash "$bootstrap_script" ${fwd_args[@]+"${fwd_args[@]}"}
    fi

    if [[ "$want_help" == "true" ]]; then
        rvdk_flash_usage
        return 0
    fi

    if [[ "${RVDK_FLASH_FORCE_RAW:-0}" != "1" ]] && [[ -n "$bootstrap_tune" || -n "$bootstrap_stage_dir" || "$bootstrap_stage_only" == "true" ]]; then
        log_fatal "--tune, --stage-dir, and --stage-only are only supported for 'sd_bootstrap' media manifests."
    fi

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
    [[ "$min_image_mib" =~ ^[1-9][0-9]*$ ]] || min_image_mib=100
    local min_bytes=$(( min_size_gib * 1024 * 1024 * 1024 ))
    local min_image_bytes=$(( min_image_mib * 1024 * 1024 ))
    local max_safe_bytes=$(( 256 * 1024 * 1024 * 1024 ))

    # ==========================================================================
    # 1. PLATFORM-SPECIFIC DEVICE RESOLUTION & HARDWARE SAFETY INTERLOCKS
    # ==========================================================================
    local block_dev="" raw_dev="" media_name="" disk_bytes=0 mkfs_ext4="" disk_num=""

    if [[ "$os_type" == "Darwin" ]]; then
        disk_num="$target_arg"
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

        local is_internal is_removable is_virtual disk_size_line
        is_internal="$(awk '/^[[:space:]]*Device Location:[[:space:]]*/ { sub(/^[[:space:]]*Device Location:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' <<< "$disk_info")"
        is_removable="$(awk '/^[[:space:]]*Removable Media:[[:space:]]*/ { sub(/^[[:space:]]*Removable Media:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' <<< "$disk_info")"
        is_virtual="$(awk '/^[[:space:]]*Virtual:[[:space:]]*/ { sub(/^[[:space:]]*Virtual:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' <<< "$disk_info")"
        media_name="$(awk '/^[[:space:]]*Device \/ Media Name:[[:space:]]*/ { sub(/^[[:space:]]*Device \/ Media Name:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' <<< "$disk_info")"
        disk_size_line="$(awk '/^[[:space:]]*Disk Size:[[:space:]]*/ { sub(/^[[:space:]]*Disk Size:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' <<< "$disk_info")"
        disk_bytes="$(grep -oE '\([0-9]+ Bytes\)' <<< "$disk_size_line" | tr -dc '0-9' || echo 0)"
        [[ -z "$disk_bytes" ]] && disk_bytes=0

        if [[ "$is_internal" != "External" || "$is_virtual" == "Yes" || "$is_removable" != "Removable" ]]; then
            log_fatal "Safety Interlock: ${block_dev} (${media_name:-unknown}) rejected (location=${is_internal:-unknown}, removable=${is_removable:-unknown}, virtual=${is_virtual:-unknown}); requires External, non-Virtual, Removable media! Aborting."
        fi

        if [[ "$flash_mode" == "uboot_ext4" ]]; then
            local e2fs_sbin=""
            e2fs_sbin="$(_rvdk_find_macos_e2fs_dir || true)"
            mkfs_ext4="${e2fs_sbin}/mkfs.ext4"
            [[ ! -x "$mkfs_ext4" ]] && log_fatal "macOS requires Homebrew e2fsprogs to build U-Boot ext4 media. Run: brew install e2fsprogs"
        fi

        log_info "Target macOS Media : ${block_dev} -> ${raw_dev} (${media_name} | ${disk_size_line})"
    else
        case "$target_arg" in
            ""|*[!0-9]*) ;;
            *) log_fatal "On Linux, specify the full block device path (e.g., /dev/sdX or /dev/mmcblk2)." ;;
        esac
        block_dev="$target_arg"
        raw_dev="$target_arg"

        case "$block_dev" in
            *boot[0-9]|*rpmb)
                log_fatal "Specify the parent MMC block device (e.g., /dev/mmcblk2), not hardware sub-partition '${block_dev}'."
                ;;
        esac

        if [[ "$block_dev" == /* || -b "$block_dev" ]] && rvdk_device_backs_os_or_swap "$block_dev"; then
            log_fatal "Safety Interlock: ${block_dev} backs a critical OS filesystem or active SWAP! Aborting."
        fi

        [[ ! -b "$block_dev" ]] && log_fatal "Block device not found: ${block_dev}"

        local dev_type=""
        dev_type="$(lsblk -dn -o TYPE "$block_dev" 2>/dev/null | head -n1 | xargs || true)"
        if [[ "$dev_type" == "part" ]]; then
            log_fatal "Specify a whole-disk block device, not partition '${block_dev}'."
        fi

        if [[ "$allow_non_removable" != "true" ]]; then
            local rm_flag hotplug_flag tran_type dev_base is_mmc_target="false"
            rm_flag="$(lsblk -dn -o RM "$block_dev" 2>/dev/null | head -n1 | tr -dc '0-9' || echo 0)"
            hotplug_flag="$(lsblk -dn -o HOTPLUG "$block_dev" 2>/dev/null | head -n1 | tr -dc '0-9' || echo 0)"
            tran_type="$(lsblk -dn -o TRAN "$block_dev" 2>/dev/null | head -n1 | tr '[:upper:]' '[:lower:]' | xargs || true)"
            dev_base="$(basename "$block_dev")"
            if [[ "$dev_base" == mmcblk[0-9]* ]] && [[ "$medium" == "sd" || "$medium" == "emmc" ]]; then
                is_mmc_target="true"
            fi
            if [[ "${rm_flag:-0}" != "1" && "${hotplug_flag:-0}" != "1" && "$tran_type" != "usb" && "$tran_type" != "mmc" && "$is_mmc_target" != "true" ]]; then
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
    _rvdk_flash_register_cleanup

    if [[ -n "$image_path" ]]; then
        image_path="${image_path/#\~/$REAL_HOME}"
        [[ ! -f "$image_path" ]] && log_fatal "Custom image file not found: ${image_path}"
        log_info "Using custom image : ${image_path}"
        if [[ -n "$cli_sha256" ]]; then
            _rvdk_flash_verify_sha256 "$image_path" "" "" "$cli_sha256" "$skip_sha256" "$REAL_USER" "$allow_remote_sha256" "false"
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
            if _rvdk_flash_download_to_part "$primary_url" "${image_path}.part"; then
                mv -f "${image_path}.part" "$image_path"
                _RVDK_FLASH_PART_FILE=""
                chown "$REAL_USER" "$image_path" 2>/dev/null || true
                log_ok "Cached ${image_path}"
            elif [[ -n "$fallback_url" ]]; then
                rm -f "${image_path}.part" 2>/dev/null || true
                _RVDK_FLASH_PART_FILE=""
                log_warn "Primary mirror unreachable; falling back to ${fallback_url}..."
                image_path="${cache_dir}/$(basename "$fallback_url")"
                sha_path="${image_path}.sha256"
                active_url="$fallback_url"
                active_pinned_sha="${cli_sha256:-$fallback_sha}"
                if ! _rvdk_flash_download_to_part "$fallback_url" "${image_path}.part"; then
                    rm -f "${image_path}.part" 2>/dev/null || true
                    _RVDK_FLASH_PART_FILE=""
                    log_fatal "Failed to download ${fallback_url}."
                fi
                mv -f "${image_path}.part" "$image_path"
                _RVDK_FLASH_PART_FILE=""
                chown "$REAL_USER" "$image_path" 2>/dev/null || true
                log_ok "Cached fallback image ${image_path}"
            else
                rm -f "${image_path}.part" 2>/dev/null || true
                _RVDK_FLASH_PART_FILE=""
                log_fatal "Failed to download ${primary_url}."
            fi
        fi

        _rvdk_flash_verify_sha256 "$image_path" "$sha_path" "${active_url}.sha256" "$active_pinned_sha" "$skip_sha256" "$REAL_USER" "$allow_remote_sha256" "true"
    fi

    _rvdk_require_decompressor "$image_path" "$os_type"

    local img_size_bytes
    img_size_bytes="$(wc -c < "$image_path" | tr -dc '0-9')"
    if (( img_size_bytes < min_image_bytes )); then
        log_fatal "Safety Interlock: ${image_path} is only ${img_size_bytes} bytes (< ${min_image_mib} MiB). Refusing to write!"
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

    local need_sudo="true"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        need_sudo="false"
    elif [[ "$os_type" == "Darwin" && -r "$raw_dev" && -w "$raw_dev" ]]; then
        need_sudo="false"
    fi

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
        local stage_stamp="${cache_dir}/${board_tag}-${medium}-stage.rvdk-stage.sha256"

        if [[ "$image_path" == "$staged_img" ]]; then
            log_info "Using uncompressed payload at ${staged_img}"
        else
            local src_sha256 stage_reuse="false"
            src_sha256="$(rvdk_sha256_file "$image_path")"
            if [[ -f "$staged_img" ]]; then
                if [[ -f "$stage_stamp" ]]; then
                    local rec_src_sha="" rec_staged_sha="" cur_staged_sha=""
                    read -r rec_src_sha rec_staged_sha _ < "$stage_stamp" || true
                    if [[ "$rec_src_sha" =~ ^[0-9a-f]{64}$ && "$rec_staged_sha" =~ ^[0-9a-f]{64}$ && "$rec_src_sha" == "$src_sha256" ]]; then
                        cur_staged_sha="$(rvdk_sha256_file "$staged_img")"
                        if [[ "$cur_staged_sha" == "$rec_staged_sha" ]]; then
                            stage_reuse="true"
                        else
                            log_warn "Staged payload ${staged_img} failed SHA-256 verification (expected ${rec_staged_sha}, got ${cur_staged_sha}); re-decompressing atomically."
                        fi
                    else
                        log_warn "Staged payload ${staged_img} does not match source archive SHA-256; re-decompressing atomically."
                    fi
                else
                    log_warn "Staged payload ${staged_img} is missing verification sidecar (${stage_stamp}); re-decompressing atomically."
                fi
            fi

            if [[ "$stage_reuse" == "true" ]]; then
                rm -f "${staged_img}.rvdk-stage.sha256" 2>/dev/null || true
                log_ok "Reusing verified decompressed staging payload: ${staged_img}"
            else
                log_info "Decompressing U-Boot payload to ${staged_img}..."
                _rvdk_flash_register_cleanup
                rm -f "$stage_stamp" 2>/dev/null || true
                find "$stage_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
                local tmp_img decomp_rc=0
                tmp_img="$(mktemp "${staged_img}.tmp.XXXXXX")"
                _RVDK_TMPFILES+=("$tmp_img")
                case "$image_path" in
                    *.zst) zstd -dc "$image_path" > "$tmp_img" || decomp_rc=$? ;;
                    *.xz)  xz -dc "$image_path" > "$tmp_img" || decomp_rc=$? ;;
                    *.bz2) bzip2 -dc "$image_path" > "$tmp_img" || decomp_rc=$? ;;
                    *.gz)  gzip -dc "$image_path" > "$tmp_img" || decomp_rc=$? ;;
                    *)     cp "$image_path" "$tmp_img" || decomp_rc=$? ;;
                esac
                if (( decomp_rc != 0 )); then
                    rm -f "$tmp_img" 2>/dev/null || true
                    if typeset -f _rvdk_untrack_tmpfile >/dev/null 2>&1; then
                        _rvdk_untrack_tmpfile "$tmp_img"
                    fi
                    log_fatal "Failed to decompress U-Boot payload from ${image_path} (exit ${decomp_rc})."
                fi
                mv -f "$tmp_img" "$staged_img"
                if typeset -f _rvdk_untrack_tmpfile >/dev/null 2>&1; then
                    _rvdk_untrack_tmpfile "$tmp_img"
                fi
                local staged_sha256
                staged_sha256="$(rvdk_sha256_file "$staged_img")"
                printf '%s %s\n' "$src_sha256" "$staged_sha256" | rvdk_atomic_write "$stage_stamp" 0644
                chown "$REAL_USER" "$stage_stamp" 2>/dev/null || true
                chown -R "$REAL_USER" "$stage_dir" 2>/dev/null || true
                log_ok "Staged payload: ${staged_img}"
            fi
        fi

        [[ "$need_sudo" == "true" ]] && sudo -v
        if [[ "$os_type" == "Darwin" ]]; then
            log_info "Unmounting ${block_dev} and building U-Boot ext4 filesystem (${fs_label})..."
            diskutil unmountDisk "$block_dev"
            _rvdk_dev_priv "$raw_dev" "$mkfs_ext4" -F -b 4096 -L "$fs_label" \
                -O ^metadata_csum_seed,^orphan_file \
                -d "$stage_dir" \
                "$raw_dev"
            sync
            diskutil eject "$block_dev"
        else
            log_info "Unmounting ${block_dev}, formatting U-Boot ext4 (${fs_label}), and staging payload..."
            _rvdk_flash_unmount_dev_children "$block_dev" "true"
            _rvdk_run_priv wipefs -a "$block_dev"
            _rvdk_run_priv "$mkfs_ext4" -F -b 4096 -L "$fs_label" \
                -O ^metadata_csum_seed,^orphan_file \
                "$block_dev"

            _RVDK_FLASH_TMP_MNT="$(mktemp -d "/tmp/rvdk_${board_tag}_usb.XXXXXX")"
            _rvdk_run_priv mount "$block_dev" "$_RVDK_FLASH_TMP_MNT"
            _rvdk_run_priv cp -v "$staged_img" "${_RVDK_FLASH_TMP_MNT}/${uboot_payload}"
            sync
            _rvdk_run_priv umount "$_RVDK_FLASH_TMP_MNT"
            rmdir "$_RVDK_FLASH_TMP_MNT"
            _RVDK_FLASH_TMP_MNT=""
            _rvdk_run_priv eject "$block_dev" 2>/dev/null || true
        fi
    elif [[ "$flash_mode" == "raw" ]]; then
        if [[ "$os_type" == "Darwin" ]]; then
            log_info "Unmounting ${block_dev} via diskutil..."
            diskutil unmountDisk "$block_dev"
        else
            log_info "Unmounting active partitions on ${block_dev}..."
            _rvdk_flash_unmount_dev_children "$block_dev" "true"
        fi

        [[ "$need_sudo" == "true" ]] && sudo -v

        # Clear stale backup GPT header at the tail of reused media so MBR first-boot resize expands cleanly
        if [[ "$os_type" != "Darwin" ]] && command -v wipefs >/dev/null 2>&1; then
            _rvdk_run_priv wipefs -af "$block_dev" >/dev/null 2>&1 || true
        fi
        if (( disk_bytes >= 4194304 && disk_bytes % 512 == 0 )); then
            local tail_seek=$(( (disk_bytes / 512) - 2048 ))
            _rvdk_dev_priv "$raw_dev" dd if=/dev/zero of="$raw_dev" bs=512 seek="$tail_seek" count=2048 status=none 2>/dev/null || true
        fi

        local dd_bs="4M"
        [[ "$os_type" == "Darwin" ]] && dd_bs="4m"
        local dd_pipe_args=("of=${raw_dev}" "bs=${dd_bs}" "status=progress")
        if dd if=/dev/zero of=/dev/null bs=512 count=1 iflag=fullblock status=none 2>/dev/null; then
            dd_pipe_args+=("iflag=fullblock")
        fi

        log_info "Streaming image to ${raw_dev} (bs=${dd_bs})..."
        case "$image_path" in
            *.zst) zstd -dc "$image_path" | _rvdk_dev_priv "$raw_dev" dd "${dd_pipe_args[@]}" ;;
            *.bz2) bzip2 -dc "$image_path" | _rvdk_dev_priv "$raw_dev" dd "${dd_pipe_args[@]}" ;;
            *.xz)  xz -dc "$image_path" | _rvdk_dev_priv "$raw_dev" dd "${dd_pipe_args[@]}" ;;
            *.gz)  gzip -dc "$image_path" | _rvdk_dev_priv "$raw_dev" dd "${dd_pipe_args[@]}" ;;
            *)     _rvdk_dev_priv "$raw_dev" dd if="$image_path" of="$raw_dev" bs="$dd_bs" status=progress ;;
        esac

        log_info "Flushing write buffers (sync)..."
        sync

        _rvdk_flash_postprocess_raw \
            "$os_type" \
            "$block_dev" \
            "$root_part" \
            "$effective_root_label" \
            "$regen_root_uuid" \
            "$emmc_uboot_boot0" \
            "$board_arch"

        if [[ "$os_type" == "Darwin" ]]; then
            diskutil eject "$block_dev"
        elif [[ "$(basename "$block_dev")" != mmcblk* ]]; then
            _rvdk_run_priv eject "$block_dev" 2>/dev/null || true
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
