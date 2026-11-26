#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: Declarative Native Kernel Btrfs RAID Builder
# Path: riscv-data-kit/mods/btrfs-raid/forge.sh
#
# Safety Interlocks:
#   • Supports explicit `.devices[]` paths OR size-bounded blank-disk discovery
#   • Refuses to auto-select or overwrite any disk containing partitions, swap,
#     LVM/RAID/LUKS headers, or filesystems unless `--force-wipe` is passed
#   • Validates relative subdirectory paths and atomically updates `/etc/fstab`
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
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:RAID]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_resolve_caller() { REAL_USER="${SUDO_USER:-root}"; REAL_GRP="root"; }
        rvdk_load_config_env() { :; }
        rvdk_normalize_mount_path() {
            local p="${1:-}"
            while [[ "$p" != "/" && "$p" == */ ]]; do p="${p%/}"; done
            printf '%s\n' "$p"
        }
        rvdk_validate_rel_subdir() {
            local rel="${1:-}"
            [[ -n "$rel" && "$rel" != /* && ! "$rel" =~ (^|/)\.\.(/|$) && "$rel" =~ ^[A-Za-z0-9._/-]+$ ]]
        }
        rvdk_atomic_write() {
            local _dst="$1" _mode="${2:-0644}" _own="${3:-}" _tmp
            mkdir -p "$(dirname "$_dst")"
            _tmp="$(mktemp "$(dirname "$_dst")/.$(basename "$_dst").rvdk.XXXXXX")"
            cat > "$_tmp"
            chmod "$_mode" "$_tmp"
            [[ -n "$_own" ]] && chown "$_own" "$_tmp"
            mv -f "$_tmp" "$_dst"
        }
    fi
fi
if [[ -z "${_RVDK_APT_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/apt.sh" ]]; then
        # shellcheck source=lib/apt.sh
        source "${_REPO_ROOT}/lib/apt.sh"
    fi
fi
if [[ -z "${_RVDK_STORAGE_GUARD_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/storage_guard.sh" ]]; then
        # shellcheck source=lib/storage_guard.sh
        source "${_REPO_ROOT}/lib/storage_guard.sh"
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

rvdk_log_init "RVDK:RAID"

usage() {
    cat <<'EOF'
Usage: sudo rvdk mods/btrfs-raid [--json '<arrays_json>'] [--force-wipe]

JSON Array Element Schema:
  {
    "name": "vault_warm",
    "label": "RVDK_RAID10",
    "mount": "/mnt/raid_warm",
    "profile": "raid10",
    "devices": ["/dev/sda", "/dev/sdb", "/dev/sdc", "/dev/sdd"],
    "disks": 4, "min_bytes": 1000000000000, "max_bytes": 5000000000000,
    "subdirs": ["datasets", "backups"]
  }
EOF
}

for _arg in "$@"; do
    if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
        usage
        exit 0
    fi
done

rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
rvdk_resolve_caller
rvdk_load_config_env RAID_ARRAYS_JSON FORCE_WIPE_RAID

FORCE_WIPE_RAID="${FORCE_WIPE_RAID:-false}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            [[ -z "${2:-}" ]] && log_fatal "Option '$1' requires a JSON array argument."
            RAID_ARRAYS_JSON="$2"
            shift 2 ;;
        --force-wipe|--force-wipe-raid)     FORCE_WIPE_RAID="true"; shift ;;
        --no-apt-update|--skip-apt-update)  export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)           export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)                          usage; exit 0 ;;
        *)                                  log_fatal "Unknown argument: $1 (try --help)" ;;
    esac
done

RAID_ARRAYS_JSON="${RAID_ARRAYS_JSON:-[]}"

rvdk_prog_init "Btrfs RAID: verifying btrfs-progs & jq..."
rvdk_prog 15 "Btrfs RAID: verifying btrfs-progs & jq..."
rvdk_apt_ensure btrfs-progs jq util-linux

ARRAY_COUNT="$(jq 'if type=="array" then length else -1 end' <<< "$RAID_ARRAYS_JSON" 2>/dev/null || echo -1)"
if (( ARRAY_COUNT < 0 )); then
    log_fatal "Invalid JSON array passed via --json / RAID_ARRAYS_JSON."
elif (( ARRAY_COUNT == 0 )); then
    rvdk_prog 100 "Btrfs RAID: no arrays declared (skipped)"
    log_skip "RAID_ARRAYS_JSON is empty; no Btrfs RAID arrays requested."
    exit 0
fi

btrfs device scan >/dev/null 2>&1 || true

_btrfs_profile_min_disks() {
    case "$1" in
        raid10|raid1c4) printf '4\n' ;;
        raid1c3)        printf '3\n' ;;
        raid1|raid0)    printf '2\n' ;;
        single)         printf '1\n' ;;
        *)              log_fatal "Unsupported Btrfs profile '${1}'." ;;
    esac
}

_btrfs_ensure_unmounted() {
    local arr_name="$1"
    local mnt="$2"
    shift 2 || true
    local -a mnt_targets=()
    local d _desc_mnt _sorted_mnt

    [[ -n "$mnt" ]] && mnt_targets+=("$mnt")
    for d in "$@"; do
        [[ -n "$d" && -b "$d" ]] || continue
        while IFS= read -r _desc_mnt; do
            [[ -n "$_desc_mnt" && "$_desc_mnt" == /* ]] && mnt_targets+=("$_desc_mnt")
        done < <(_rvdk_lsblk_mountpoints "$d")
    done

    if (( ${#mnt_targets[@]} > 0 )); then
        while IFS= read -r _sorted_mnt; do
            [[ -n "$_sorted_mnt" ]] || continue
            if mountpoint -q "$_sorted_mnt" 2>/dev/null; then
                umount "$_sorted_mnt" 2>/dev/null || true
            fi
        done < <(printf '%s\n' "${mnt_targets[@]}" | awk '!seen[$0]++ { printf "%d\t%s\n", length($0), $0 }' | sort -rn -k1,1 | cut -f2-)
    fi

    if [[ -n "$mnt" ]] && mountpoint -q "$mnt" 2>/dev/null; then
        log_fatal "Cannot proceed on '${arr_name}': mountpoint '${mnt}' is still mounted/busy."
    fi
    for d in "$@"; do
        [[ -n "$d" && -b "$d" ]] || continue
        while IFS= read -r _desc_mnt; do
            [[ -z "$_desc_mnt" ]] && continue
            log_fatal "Cannot proceed on '${arr_name}': disk ${d} still has active/busy mount '${_desc_mnt}'."
        done < <(_rvdk_lsblk_mountpoints "$d")
    done
}

_btrfs_converge_fstab_entry() {
    rvdk_converge_fstab_entry "$1" "$2" "btrfs" "$3" "${4:-/etc/fstab}"
}

for (( i=0; i<ARRAY_COUNT; i++ )); do
    # Single-pass jq extraction for all per-array scalar & list fields
    _ARR_FIELDS=()
    while IFS= read -r _fline; do
        _ARR_FIELDS+=("$_fline")
    done < <(jq -r --argjson idx "$i" '
        .[$idx] |
        (.name // "array_\($idx)"),
        (.type // "data"),
        ((.profile // "raid10") | ascii_downcase),
        (.label // ""),
        (.mount // ""),
        ((.disks // 4) | tostring),
        ((.min_bytes // 0) | tostring),
        ((.max_bytes // 0) | tostring),
        ((.devices // []) | map(tostring) | join("\u001f")),
        ((.subdirs // []) | map(tostring) | join("\u001f")),
        ((.devices // []) | length | tostring)
    ' <<< "$RAID_ARRAYS_JSON")

    ARR_NAME="${_ARR_FIELDS[0]:-array_${i}}"
    ARR_TYPE="${_ARR_FIELDS[1]:-data}"
    ARR_PROFILE="${_ARR_FIELDS[2]:-raid10}"
    ARR_LABEL="${_ARR_FIELDS[3]:-}"
    ARR_MOUNT="$(rvdk_normalize_mount_path "${_ARR_FIELDS[4]:-}")"
    ARR_DISKS="${_ARR_FIELDS[5]:-4}"
    ARR_MIN_B="${_ARR_FIELDS[6]:-0}"
    ARR_MAX_B="${_ARR_FIELDS[7]:-0}"
    ARR_DEVS_RAW="${_ARR_FIELDS[8]:-}"
    ARR_SUBDIRS_RAW="${_ARR_FIELDS[9]:-}"
    ARR_EXPLICIT_DEVS_CNT="${_ARR_FIELDS[10]:-0}"

    [[ -z "$ARR_LABEL" || ! "$ARR_LABEL" =~ ^[A-Za-z0-9._-]+$ ]] && log_fatal "Invalid or missing Btrfs label '${ARR_LABEL}' on array '${ARR_NAME}'."
    [[ -z "$ARR_MOUNT" || "$ARR_MOUNT" != /* || "$ARR_MOUNT" == "/" ]] && log_fatal "Invalid mountpoint '${ARR_MOUNT}' on array '${ARR_NAME}'."
    if ! [[ "$ARR_DISKS" =~ ^[0-9]+$ ]] || (( ARR_DISKS <= 0 )); then
        log_fatal "Invalid 'disks' count '${ARR_DISKS}' on array '${ARR_NAME}'."
    fi
    [[ "$ARR_MIN_B" =~ ^[0-9]+$ && "$ARR_MAX_B" =~ ^[0-9]+$ ]] || log_fatal "Invalid min_bytes/max_bytes on array '${ARR_NAME}'."
    case "$ARR_PROFILE" in
        raid10|raid1|raid1c3|raid1c4|raid0|single) ;;
        *) log_fatal "Unsupported Btrfs profile '${ARR_PROFILE}' on array '${ARR_NAME}'." ;;
    esac

    STEP_PCT=$(( 25 + ((i * 70) / ARRAY_COUNT) ))
    TYPE_UPPER="$(tr '[:lower:]' '[:upper:]' <<< "$ARR_TYPE")"
    rvdk_prog "$STEP_PCT" "Btrfs RAID (${ARR_PROFILE}): converging ${ARR_NAME} (${ARR_LABEL})..."
    log_info "Checking ${ARR_NAME} [${TYPE_UPPER}] (${ARR_LABEL} -> ${ARR_MOUNT})..."
    EXISTING_DEV="$(blkid -L "$ARR_LABEL" 2>/dev/null || true)"
    if [[ -z "$EXISTING_DEV" && "$FORCE_WIPE_RAID" == "false" ]] && mountpoint -q "$ARR_MOUNT" 2>/dev/null; then
        _arr_src="$(findmnt -rn -o SOURCE -M "$ARR_MOUNT" 2>/dev/null || true)"
        _arr_src="${_arr_src%%\[*}"
        [[ -b "$_arr_src" ]] && EXISTING_DEV="$_arr_src"
    fi

    EFFECTIVE_ARR_LABEL="$ARR_LABEL"
    EFFECTIVE_ARR_SPEC="LABEL=${ARR_LABEL}"
    if [[ -n "$EXISTING_DEV" && "$FORCE_WIPE_RAID" == "false" ]]; then
        _arr_lbl="$(blkid -s LABEL -o value "$EXISTING_DEV" 2>/dev/null || true)"
        _arr_uuid="$(blkid -s UUID -o value "$EXISTING_DEV" 2>/dev/null || true)"
        if [[ -n "$_arr_lbl" ]]; then
            EFFECTIVE_ARR_LABEL="$_arr_lbl"
            EFFECTIVE_ARR_SPEC="LABEL=${_arr_lbl}"
        elif [[ -n "$_arr_uuid" ]]; then
            EFFECTIVE_ARR_SPEC="UUID=${_arr_uuid}"
        fi
        log_skip "${ARR_NAME} volume '${EFFECTIVE_ARR_LABEL}' already exists on ${EXISTING_DEV}"
    else
        CANDIDATE_DISKS=()

        if [[ -n "$ARR_DEVS_RAW" ]] || (( ARR_EXPLICIT_DEVS_CNT > 0 )); then
            IFS=$'\x1f' read -r -a _explicit_devs <<< "$ARR_DEVS_RAW"
            (( ${#_explicit_devs[@]} > 0 )) || log_fatal "${ARR_NAME}: explicit .devices[] contains an empty device entry."
            for explicit_dev in "${_explicit_devs[@]}"; do
                [[ -n "$explicit_dev" ]] || log_fatal "${ARR_NAME}: explicit .devices[] contains an empty device entry."
                [[ -b "$explicit_dev" ]] || log_fatal "${ARR_NAME}: explicit device '${explicit_dev}' is not a valid block device."
                _canon_dev="$(readlink -f "$explicit_dev")"
                [[ -b "$_canon_dev" ]] || log_fatal "${ARR_NAME}: explicit device '${explicit_dev}' resolved to invalid block device '${_canon_dev}'."
                _dup_dev="false"
                for _seen_dev in ${CANDIDATE_DISKS[@]+"${CANDIDATE_DISKS[@]}"}; do
                    if [[ "$_seen_dev" == "$_canon_dev" ]]; then
                        _dup_dev="true"
                        break
                    fi
                done
                [[ "$_dup_dev" == "false" ]] && CANDIDATE_DISKS+=("$_canon_dev")
            done
        else
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                d_path="$(awk '{print $1}' <<< "$line")"
                d_size="$(awk '{print $2}' <<< "$line")"
                d_type="$(awk '{print $3}' <<< "$line")"
                [[ "$d_type" != "disk" ]] && continue
                [[ "$d_path" == /dev/nvme* || "$d_path" == /dev/mmcblk* || "$d_path" == /dev/zram* ]] && continue
                d_path="$(readlink -f "$d_path" 2>/dev/null || echo "$d_path")"
                rvdk_device_backs_os_or_swap "$d_path" && continue
                if [[ "$FORCE_WIPE_RAID" == "false" ]] && ! rvdk_disk_is_blank "$d_path"; then
                    continue
                fi
                if (( d_size >= ARR_MIN_B && d_size <= ARR_MAX_B )); then
                    _dup_dev="false"
                    for _seen_dev in ${CANDIDATE_DISKS[@]+"${CANDIDATE_DISKS[@]}"}; do
                        if [[ "$_seen_dev" == "$d_path" ]]; then
                            _dup_dev="true"
                            break
                        fi
                    done
                    [[ "$_dup_dev" == "false" ]] && CANDIDATE_DISKS+=("$d_path")
                fi
            done < <(lsblk -b -dn -o PATH,SIZE,TYPE)

            if (( ${#CANDIDATE_DISKS[@]} != ARR_DISKS )); then
                log_fatal "${ARR_NAME} requires ${ARR_DISKS} eligible blank disks between ${ARR_MIN_B} and ${ARR_MAX_B} bytes; found ${#CANDIDATE_DISKS[@]} (${CANDIDATE_DISKS[*]:-none}). Specify explicit \"devices\" or pass --force-wipe if re-initializing existing drives."
            fi
        fi

        _min_disks="$(_btrfs_profile_min_disks "$ARR_PROFILE")"
        if (( ${#CANDIDATE_DISKS[@]} < _min_disks )); then
            log_fatal "${ARR_NAME}: Btrfs profile '${ARR_PROFILE}' requires at least ${_min_disks} unique disk(s); got ${#CANDIDATE_DISKS[@]} (${CANDIDATE_DISKS[*]:-none})."
        fi

        for d in "${CANDIDATE_DISKS[@]}"; do
            rvdk_assert_device_safe_to_wipe "$d" "$FORCE_WIPE_RAID" "$ARR_LABEL"
        done

        if [[ "$FORCE_WIPE_RAID" == "true" ]]; then
            _btrfs_ensure_unmounted "$ARR_NAME" "$ARR_MOUNT" "${CANDIDATE_DISKS[@]}"
        fi

        log_info "Formatting native Btrfs (${ARR_PROFILE}) '${ARR_LABEL}' across: ${CANDIDATE_DISKS[*]}"
        for d in "${CANDIDATE_DISKS[@]}"; do
            while IFS= read -r _part; do
                [[ -n "$_part" && -b "$_part" ]] || continue
                wipefs -af "$_part" >/dev/null
            done < <(rvdk_list_child_partitions "$d")
            wipefs -af "$d" >/dev/null
        done
        mkfs.btrfs -f -L "$ARR_LABEL" -d "$ARR_PROFILE" -m "$ARR_PROFILE" "${CANDIDATE_DISKS[@]}"
        btrfs device scan >/dev/null 2>&1 || true
        udevadm settle
        EFFECTIVE_ARR_LABEL="$ARR_LABEL"
        EFFECTIVE_ARR_SPEC="LABEL=${ARR_LABEL}"
        log_ok "Created ${#CANDIDATE_DISKS[@]}-drive Btrfs (${ARR_PROFILE}) volume '${ARR_LABEL}'"
    fi

    mkdir -p "$ARR_MOUNT"
    ARR_FSTYPE=""
    if [[ -n "$EXISTING_DEV" ]]; then
        ARR_FSTYPE="$(blkid -s TYPE -o value "$EXISTING_DEV" 2>/dev/null || true)"
    fi
    [[ -z "$ARR_FSTYPE" ]] && ARR_FSTYPE="btrfs"
    if [[ "$ARR_FSTYPE" == "btrfs" ]]; then
        FSTAB_RAID="${EFFECTIVE_ARR_SPEC}  ${ARR_MOUNT}  btrfs  rw,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=30s  0  2"
    else
        FSTAB_RAID="${EFFECTIVE_ARR_SPEC}  ${ARR_MOUNT}  ${ARR_FSTYPE}  rw,noatime,nofail,x-systemd.device-timeout=30s  0  2"
    fi
    rvdk_converge_fstab_entry "$EFFECTIVE_ARR_SPEC" "$ARR_MOUNT" "$ARR_FSTYPE" "$FSTAB_RAID"

    if ! mountpoint -q "$ARR_MOUNT"; then
        mount "$ARR_MOUNT"
        log_ok "Mounted ${ARR_MOUNT}"
    else
        log_skip "${ARR_MOUNT} is already mounted"
    fi

    if [[ -n "$ARR_SUBDIRS_RAW" ]]; then
        IFS=$'\x1f' read -r -a _subdirs <<< "$ARR_SUBDIRS_RAW"
        for subdir in "${_subdirs[@]}"; do
            [[ -z "$subdir" ]] && continue
            if ! rvdk_validate_rel_subdir "$subdir"; then
                log_fatal "Rejected unsafe relative subdirectory '${subdir}' on ${ARR_MOUNT}."
            fi
            install -d -m 0775 -o "$REAL_USER" -g "$REAL_GRP" "${ARR_MOUNT}/${subdir}"
        done
    fi
done

rvdk_prog 100 "Btrfs RAID volumes converged"
