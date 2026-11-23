#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Metadata-Driven Removable Media Flasher (macOS & Linux)
# Path: riscv-data-kit/lib/flash.sh
#
# Reads board flash specifications from `boards/<vendor>/<board>/media.json` and
# executes hardware-interlocked, cryptographically verified media preparation:
#   • mode = "raw"          : Stream-decompresses (.zst/.xz/.bz2/.gz/raw) to block dev,
#                             wipes stale backup GPT headers on reused cards, seeds
#                             cold-RTC clock floor (/etc/fake-hwclock.data + timesync),
#                             applies deterministic ext4 rootfs labels (rvdk_sd_root /
#                             rvdk_emmc_root), de-collides dual-media UUID + PARTUUID,
#                             and provisions SpacemiT/Ky eMMC hardware boot0 SPL.
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

if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    # shellcheck source=lib/common.sh
    source "${_FLASH_LIB_DIR}/common.sh"
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

_RVDK_FLASH_TMP_MNT=""
_rvdk_flash_cleanup() {
    if [[ -n "${_RVDK_FLASH_TMP_MNT:-}" && -d "${_RVDK_FLASH_TMP_MNT}" ]]; then
        if [[ -d "${_RVDK_FLASH_TMP_MNT}/boot" ]]; then
            _rvdk_run_priv umount "${_RVDK_FLASH_TMP_MNT}/boot" 2>/dev/null || true
        fi
        if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null; then
            _rvdk_run_priv umount "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null || _rvdk_run_priv umount -l "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null || true
        else
            _rvdk_run_priv umount "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null || true
        fi
        rmdir "${_RVDK_FLASH_TMP_MNT}" 2>/dev/null || true
    fi
    declare -F _rvdk_cleanup_tmpfiles >/dev/null 2>&1 && _rvdk_cleanup_tmpfiles || true
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
    "orangepi-rv2": "orangepi/rv2",
    "opirv2": "orangepi/rv2",
    "orangepi-r2s": "orangepi/r2s",
    "opir2s": "orangepi/r2s",
    "orangepi-rv": "orangepi/rv",
    "bananapi-f3": "bananapi/f3",
    "bpi-f3": "bananapi/f3",
    "milkv-jupiter": "milkv/jupiter",
    "milkv-jupiter2": "milkv/jupiter2",
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

    local expected=""
    if [[ -n "$pinned_sha" ]]; then
        expected="$(printf '%s' "$pinned_sha" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')"
    elif [[ "$allow_remote_sha" == "true" ]]; then
        if [[ ! -s "$sha_file" && -n "$remote_sha_url" ]]; then
            log_info "Fetching same-origin SHA-256 sidecar (${remote_sha_url}) (--allow-remote-sha256)..."
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
        if [[ -n "$remote_sha_url" ]]; then
            log_fatal "Fail-closed security check: no pinned SHA-256 digest for ${img_file}. Pass --sha256 <hex>, --allow-remote-sha256 (to trust ${remote_sha_url}), or --insecure-skip-sha256."
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
        if grep -Eq '^[[:space:]]*[^#].*[[:space:]]/[[:space:]]+ext4[[:space:]].*commit=[0-9]{2,}' <<< "$cur_fstab"; then
            local tmp_fstab tmp_fcmds
            tmp_fstab="$(mktemp "/tmp/rvdk_fstab.XXXXXX")"
            tmp_fcmds="$(mktemp "/tmp/rvdk_fcmds.XXXXXX")"
            sed -E '/^[[:space:]]*#/! s/,commit=[0-9]{2,}//g; /^[[:space:]]*#/! s/commit=[0-9]{2,},//g' <<< "$cur_fstab" > "$tmp_fstab"
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

# Seed host UTC timestamp into unmounted ext4 `/etc/fake-hwclock.data`,
# `/var/lib/systemd/timesync/clock`, and superblock check-time so batteryless
# RISC-V SBCs boot inside the valid TLS certificate window on first power-on.
_rvdk_seed_ext4_rtc_floor() {
    local debugfs_bin="$1"
    local tune2fs_bin="$2"
    local root_slice="$3"

    local now_epoch=""
    now_epoch="$(date -u +%s 2>/dev/null || echo 0)"
    [[ "$now_epoch" =~ ^[0-9]+$ ]] && (( now_epoch >= 1767225600 )) || return 0

    local utc_now
    utc_now="$(date -u '+%Y-%m-%d %H:%M:%S')"
    local seeded="false"

    if [[ -n "$debugfs_bin" && -x "$debugfs_bin" ]]; then
        local has_etc="" has_timesync=""
        has_etc="$(_rvdk_dev_priv "$root_slice" "$debugfs_bin" -R "stat /etc" "$root_slice" 2>/dev/null || true)"
        has_timesync="$(_rvdk_dev_priv "$root_slice" "$debugfs_bin" -R "stat /var/lib/systemd/timesync" "$root_slice" 2>/dev/null || true)"

        if grep -q "Inode:" <<< "$has_etc" || grep -q "Inode:" <<< "$has_timesync"; then
            local tmp_rtc tmp_empty tmp_cmds
            tmp_rtc="$(mktemp "/tmp/rvdk_rtc.XXXXXX")"
            tmp_empty="$(mktemp "/tmp/rvdk_ts.XXXXXX")"
            tmp_cmds="$(mktemp "/tmp/rvdk_dbg.XXXXXX")"
            printf '%s\n' "$utc_now" > "$tmp_rtc"
            : > "$tmp_empty"
            : > "$tmp_cmds"
            if grep -q "Inode:" <<< "$has_etc"; then
                cat <<EOF >> "$tmp_cmds"
rm /etc/fake-hwclock.data
write ${tmp_rtc} /etc/fake-hwclock.data
sif /etc/fake-hwclock.data uid 0
sif /etc/fake-hwclock.data gid 0
sif /etc/fake-hwclock.data mode 0100644
EOF
            fi
            if grep -q "Inode:" <<< "$has_timesync"; then
                cat <<EOF >> "$tmp_cmds"
rm /var/lib/systemd/timesync/clock
write ${tmp_empty} /var/lib/systemd/timesync/clock
sif /var/lib/systemd/timesync/clock uid 0
sif /var/lib/systemd/timesync/clock gid 0
sif /var/lib/systemd/timesync/clock mode 0100644
EOF
            fi
            chmod 0644 "$tmp_rtc" "$tmp_empty" "$tmp_cmds"
            if _rvdk_dev_priv "$root_slice" "$debugfs_bin" -w -f "$tmp_cmds" "$root_slice" >/dev/null 2>&1; then
                seeded="true"
            fi
            rm -f "$tmp_rtc" "$tmp_empty" "$tmp_cmds"
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

_rvdk_flash_postprocess_raw() {
    local os_type="$1"
    local block_dev="$2"
    local root_part_hint="$3"
    local root_label="$4"
    local regen_uuid="$5"
    local emmc_boot0="$6"

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
            [[ -n "$root_label" ]] && log_warn "No partition slices detected on ${block_dev} after image stream; skipping host ext4 hygiene."
            return 0
        fi

        local root_slice=""
        if ! root_slice="$(_rvdk_select_ext4_root_slice "$tune2fs_bin" "$root_part_hint" "${slices[@]}")"; then
            [[ -n "$root_label" ]] && log_warn "Could not locate an ext4 rootfs slice on ${block_dev}; skipping host ext4 hygiene."
            return 0
        fi

        diskutil unmountDisk "$block_dev" >/dev/null 2>&1 || true
        _rvdk_harden_ext4_superblock "$tune2fs_bin" "$e2fsck_bin" "$debugfs_bin" "$root_slice"

        if [[ -n "$root_label" && -x "$e2label_bin" ]]; then
            _rvdk_dev_priv "$root_slice" "$e2label_bin" "$root_slice" "$root_label"
            local verified_lbl=""
            verified_lbl="$(_rvdk_dev_priv "$root_slice" "$e2label_bin" "$root_slice" 2>/dev/null | tr -d '[:space:]' || true)"
            if [[ "$verified_lbl" != "$root_label" ]]; then
                log_fatal "Failed to verify ext4 label '${root_label}' on ${root_slice} (got '${verified_lbl}')."
            fi
            log_ok "Labeled ext4 rootfs : ${root_slice} -> ${verified_lbl}"
        fi

        _rvdk_seed_ext4_rtc_floor "$debugfs_bin" "$tune2fs_bin" "$root_slice"
        if [[ -n "$e2fsck_bin" && -x "$e2fsck_bin" ]]; then
            _rvdk_dev_priv "$root_slice" "$e2fsck_bin" -pf "$root_slice" >/dev/null 2>&1 || true
        fi
        sync
        return 0
    fi

    # Linux post-flash processing (partition re-read, UUID/PARTUUID de-collision, eMMC boot0 SPL, RTC floor, e2label)
    _rvdk_run_priv partprobe "$block_dev" 2>/dev/null || _rvdk_run_priv blockdev --rereadpt "$block_dev" 2>/dev/null || true
    command -v udevadm >/dev/null 2>&1 && _rvdk_run_priv udevadm settle 2>/dev/null || sleep 1

    local p_node
    for p_node in "${block_dev}"*; do
        [[ "$p_node" == "$block_dev" ]] && continue
        _rvdk_run_priv umount "$p_node" 2>/dev/null || true
    done

    # De-collide MBR 32-bit disk identifier when regenerating UUID so PARTUUID (`ubootpart=`) is unique across SD & eMMC
    if [[ "$regen_uuid" == "true" ]] && command -v sfdisk >/dev/null 2>&1; then
        local pt_type=""
        pt_type="$(_rvdk_run_priv blkid -s PTTYPE -o value "$block_dev" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
        if [[ "$pt_type" == "dos" ]]; then
            local new_mbr_id=""
            new_mbr_id="0x$(od -An -N4 -tx4 /dev/urandom 2>/dev/null | tr -d '[:space:]' || printf '7276646b')"
            if _rvdk_run_priv sfdisk --disk-id "$block_dev" "$new_mbr_id" >/dev/null 2>&1; then
                _rvdk_run_priv partprobe "$block_dev" 2>/dev/null || _rvdk_run_priv blockdev --rereadpt "$block_dev" 2>/dev/null || true
                command -v udevadm >/dev/null 2>&1 && _rvdk_run_priv udevadm settle 2>/dev/null || sleep 1
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
    local lp_path lp_type
    while IFS=' ' read -r lp_path lp_type; do
        [[ "$lp_type" == "part" && -b "$lp_path" ]] && linux_parts+=("$lp_path")
    done < <(lsblk -ln -o PATH,TYPE "$block_dev" 2>/dev/null || true)

    if (( ${#linux_parts[@]} == 0 )); then
        [[ -n "$root_label" ]] && log_warn "No child partitions detected on ${block_dev}; skipping post-flash filesystem hygiene."
        return 0
    fi

    local root_slice=""
    if [[ -x "$tune2fs_bin" ]]; then
        root_slice="$(_rvdk_select_ext4_root_slice "$tune2fs_bin" "$root_part_hint" "${linux_parts[@]}" || true)"
    fi
    if [[ -z "$root_slice" ]]; then
        [[ -n "$root_label" ]] && log_warn "Could not locate ext4 rootfs partition on ${block_dev}; skipping post-flash filesystem hygiene."
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
            [[ -z "$other_dev" || "$other_dev" == "$root_slice" || "$other_dev" == "${block_dev}"* ]] && continue
            uuid_collision="true"
            break
        done < <(_rvdk_run_priv blkid -t "UUID=${old_uuid}" -o device 2>/dev/null || true)
    fi

    local need_mount="false"
    [[ "$regen_uuid" == "true" || "$uuid_collision" == "true" ]] && need_mount="true"
    [[ "$emmc_boot0" == "true" && -b "${block_dev}boot0" ]] && need_mount="true"

    local new_uuid=""
    if [[ "$regen_uuid" == "true" || "$uuid_collision" == "true" ]]; then
        if [[ -x "$tune2fs_bin" && -x "$e2fsck_bin" ]]; then
            local fsck_rc=0
            _rvdk_run_priv "$e2fsck_bin" -pf "$root_slice" >/dev/null 2>&1 || fsck_rc=$?
            if (( fsck_rc <= 1 )); then
                new_uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
                _rvdk_run_priv "$tune2fs_bin" -U "$new_uuid" "$root_slice" >/dev/null
                log_ok "Assigned unique ext4 UUID on ${root_slice}: ${new_uuid} (preventing SD/eMMC UUID collision)"
            else
                log_warn "e2fsck returned ${fsck_rc} on ${root_slice}; preserving existing UUID."
                new_uuid=""
            fi
        fi
    fi

    if [[ "$need_mount" == "true" ]]; then
        _RVDK_FLASH_TMP_MNT="$(mktemp -d "/tmp/rvdk_postflash.XXXXXX")"
        _rvdk_run_priv mount "$root_slice" "$_RVDK_FLASH_TMP_MNT"

        # Mount separate /boot partition if the image uses a 2-partition layout
        local boot_slice="" cand_p cand_lbl
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
        if [[ -n "$boot_slice" && -d "${_RVDK_FLASH_TMP_MNT}/boot" ]]; then
            _rvdk_run_priv mount "$boot_slice" "${_RVDK_FLASH_TMP_MNT}/boot" 2>/dev/null || true
        fi

        local cfg_rel cfg_full
        for cfg_rel in \
            etc/fstab \
            boot/orangepiEnv.txt \
            boot/armbianEnv.txt \
            boot/env_k1-x.txt \
            boot/spacemit/env_k1-x.txt \
            boot/extlinux/extlinux.conf \
            boot/efi/extlinux.conf; do
            cfg_full="${_RVDK_FLASH_TMP_MNT}/${cfg_rel}"
            [[ -f "$cfg_full" ]] || continue
            if [[ -n "$old_uuid" && -n "$new_uuid" ]] && _rvdk_run_priv grep -qF "$old_uuid" "$cfg_full" 2>/dev/null; then
                _rvdk_run_priv sed -i "s|${old_uuid}|${new_uuid}|g" "$cfg_full"
                log_ok "Updated root UUID in target /${cfg_rel}"
            fi
            if [[ -n "$old_label" && -n "$root_label" && "$old_label" != "$root_label" ]] && _rvdk_run_priv grep -qF "LABEL=${old_label}" "$cfg_full" 2>/dev/null; then
                _rvdk_run_priv sed -i "s|LABEL=${old_label}|LABEL=${root_label}|g" "$cfg_full"
                log_ok "Updated root LABEL in target /${cfg_rel} (${old_label} -> ${root_label})"
            fi
        done

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
                [[ -f "$boot0_sys" ]] && printf '0\n' | _rvdk_run_priv tee "$boot0_sys" >/dev/null
                _rvdk_run_priv dd if="${uboot_dir}/bootinfo_emmc.bin" of="$boot0_dev" bs=512 seek=0 conv=notrunc,fsync status=none
                _rvdk_run_priv dd if="${uboot_dir}/FSBL.bin" of="$boot0_dev" bs=512 seek=1 conv=notrunc,fsync status=none
                [[ -f "$boot0_sys" ]] && printf '1\n' | _rvdk_run_priv tee "$boot0_sys" >/dev/null
                log_ok "Programmed SpacemiT/Ky eMMC BootROM SPL (${boot0_dev} <- bootinfo_emmc.bin + FSBL.bin)"
            else
                log_warn "Could not find bootinfo_emmc.bin + FSBL.bin for ${block_dev}boot0; verify eMMC SPL before rebooting."
            fi
        fi

        sync
        [[ -n "$boot_slice" ]] && _rvdk_run_priv umount "${_RVDK_FLASH_TMP_MNT}/boot" 2>/dev/null || true
        _rvdk_run_priv umount "$_RVDK_FLASH_TMP_MNT"
        rmdir "$_RVDK_FLASH_TMP_MNT"
        _RVDK_FLASH_TMP_MNT=""
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
      --hostname <name>        Optional target hostname override (sd_bootstrap media)
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
            --board)                 board_query="${2:-}"; shift 2 ;;
            --medium)                medium="${2:-}"; shift 2 ;;
            -d|--device)             target_arg="${2:-}"; shift 2 ;;
            -i|--image)              image_path="${2:-}"; shift 2 ;;
            --sha256)                cli_sha256="${2:-}"; shift 2 ;;
            --allow-remote-sha256)   allow_remote_sha256="true"; shift ;;
            --root-label)            cli_root_label="${2:-}"; shift 2 ;;
            --no-root-label)         skip_root_label="true"; shift ;;
            --hostname)              bootstrap_hostname="${2:-}"; shift 2 ;;
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
fields = [
    doc.get("board", ""),
    doc.get("tag", ""),
    doc.get("name", ""),
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

    local board_id board_tag board_name flash_mode script_rel default_img manifest_sha custom_url fallback_url fallback_sha uboot_payload fs_label root_part manifest_root_label regen_root_uuid emmc_uboot_boot0 min_size_gib
    {
        IFS= read -r board_id
        IFS= read -r board_tag
        IFS= read -r board_name
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
    } <<< "$parsed_spec"
    local post_notes="${parsed_spec#*---NOTES---}"
    post_notes="${post_notes#$'\n'}"

    local effective_root_label="${cli_root_label:-$manifest_root_label}"
    [[ "$skip_root_label" == "true" ]] && effective_root_label=""

    if [[ "$flash_mode" == "sd_bootstrap" ]]; then
        local manifest_dir bootstrap_script
        manifest_dir="$(cd "$(dirname "$manifest_path")" && pwd)"
        bootstrap_script="${manifest_dir}/${script_rel}"
        [[ -z "$script_rel" || ! -f "$bootstrap_script" ]] && log_fatal "sd_bootstrap mode requires an existing 'script' in ${manifest_path}."
        local fwd_args=()
        [[ "$want_help" == "true" ]] && fwd_args+=("--help")
        [[ -n "$target_arg" ]] && fwd_args+=("--device" "$target_arg")
        [[ -n "$effective_root_label" ]] && fwd_args+=("--root-label" "$effective_root_label")
        [[ -n "$bootstrap_hostname" ]] && fwd_args+=("--hostname" "$bootstrap_hostname")
        [[ "$dry_run" == "true" ]] && fwd_args+=("--dry-run")
        [[ "$force_large_disk" == "true" ]] && fwd_args+=("--force")
        [[ "$skip_confirm" == "true" ]] && fwd_args+=("--yes")
        exec bash "$bootstrap_script" ${fwd_args[@]+"${fwd_args[@]}"}
    fi

    if [[ "$want_help" == "true" ]]; then
        rvdk_flash_usage
        return 0
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
    local min_bytes=$(( min_size_gib * 1024 * 1024 * 1024 ))
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
        is_internal="$(awk -F': *' '/Device Location:/ {print $2}' <<< "$disk_info" | xargs)"
        is_removable="$(awk -F': *' '/Removable Media:/ {print $2}' <<< "$disk_info" | xargs)"
        is_virtual="$(awk -F': *' '/Virtual:/ {print $2}' <<< "$disk_info" | xargs)"
        media_name="$(awk -F': *' '/Device \/ Media Name:/ {print $2}' <<< "$disk_info" | xargs)"
        disk_size_line="$(awk -F': *' '/Disk Size:/ {print $2}' <<< "$disk_info" | xargs)"
        disk_bytes="$(grep -oE '\([0-9]+ Bytes\)' <<< "$disk_size_line" | tr -dc '0-9' || echo 0)"
        [[ -z "$disk_bytes" ]] && disk_bytes=0

        if [[ "$is_internal" == "Internal" && "$is_removable" != "Removable" && "$is_virtual" != "Yes" ]]; then
            log_fatal "Safety Interlock: ${block_dev} (${media_name}) is an INTERNAL non-removable drive! Aborting."
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
        [[ ! -b "$block_dev" ]] && log_fatal "Block device not found: ${block_dev}"

        case "$block_dev" in
            *boot[0-9]|*rpmb)
                log_fatal "Specify the parent MMC block device (e.g., /dev/mmcblk2), not hardware sub-partition '${block_dev}'."
                ;;
        esac

        local dev_type=""
        dev_type="$(lsblk -dn -o TYPE "$block_dev" 2>/dev/null | head -n1 | xargs || true)"
        if [[ "$dev_type" == "part" ]]; then
            log_fatal "Specify a whole-disk block device, not partition '${block_dev}'."
        fi

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
    if [[ -n "$image_path" ]]; then
        image_path="${image_path/#\~/$REAL_HOME}"
        [[ ! -f "$image_path" ]] && log_fatal "Custom image file not found: ${image_path}"
        log_info "Using custom image : ${image_path}"
        if [[ -n "$cli_sha256" ]]; then
            _rvdk_flash_verify_sha256 "$image_path" "" "" "$cli_sha256" "$skip_sha256" "$REAL_USER" "$allow_remote_sha256"
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

        _rvdk_flash_verify_sha256 "$image_path" "$sha_path" "${active_url}.sha256" "$active_pinned_sha" "$skip_sha256" "$REAL_USER" "$allow_remote_sha256"
    fi

    _rvdk_require_decompressor "$image_path" "$os_type"

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
            local part
            for part in "${block_dev}"*; do
                _rvdk_run_priv umount "$part" 2>/dev/null || true
            done
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
            local part
            for part in "${block_dev}"*; do
                _rvdk_run_priv umount "$part" 2>/dev/null || true
            done
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
            "$emmc_uboot_boot0"

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
