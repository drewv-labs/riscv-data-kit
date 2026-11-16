#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: Declarative Native Kernel Btrfs RAID Builder
# Path: riscv-data-kit/mods/btrfs-raid/forge.sh
#
# Safety Interlocks:
#   • Supports explicit `.devices[]` paths OR size-bounded blank-disk discovery
#   • Refuses to auto-select or overwrite any disk containing partitions, swap,
#     LVM/RAID/LUKS headers, or filesystems unless `--force-wipe` is passed
#   • Validates relative subdirectory paths and PostgreSQL tablespace identifiers
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
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${_REPO_ROOT}/lib/common.sh"
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/apt.sh" ]]; then
    # shellcheck source=lib/apt.sh
    source "${_REPO_ROOT}/lib/apt.sh"
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/storage_guard.sh" ]]; then
    # shellcheck source=lib/storage_guard.sh
    source "${_REPO_ROOT}/lib/storage_guard.sh"
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]]; then
    # shellcheck source=lib/progbar.sh
    source "${_REPO_ROOT}/lib/progbar.sh"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_log_init "RVDK:RAID"
rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
rvdk_resolve_caller
rvdk_load_config_env RAID_ARRAYS_JSON FORCE_WIPE_RAID

FORCE_WIPE_RAID="${FORCE_WIPE_RAID:-false}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)                             RAID_ARRAYS_JSON="${2:-[]}"; shift 2 ;;
        --force-wipe|--force-wipe-raid)     FORCE_WIPE_RAID="true"; shift ;;
        --no-apt-update|--skip-apt-update)  export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)           export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)
            cat <<EOF
Usage: sudo rvdk mods/btrfs-raid [--json '<arrays_json>'] [--force-wipe]

JSON Array Element Schema:
  {
    "name": "vault_warm",
    "label": "RVDK_RAID10",
    "mount": "/mnt/raid_warm",
    "profile": "raid10",
    "devices": ["/dev/sda", "/dev/sdb", "/dev/sdc", "/dev/sdd"],
    "disks": 4, "min_bytes": 1000000000000, "max_bytes": 5000000000000,
    "subdirs": ["datasets", "backups"],
    "tablespace": "ts_warm"
  }
EOF
            exit 0
            ;;
        *) shift ;;
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

for (( i=0; i<ARRAY_COUNT; i++ )); do
    ARR_NAME="$(jq -r ".[$i].name // \"array_${i}\"" <<< "$RAID_ARRAYS_JSON")"
    ARR_TYPE="$(jq -r ".[$i].type // \"data\"" <<< "$RAID_ARRAYS_JSON")"
    ARR_PROFILE="$(jq -r ".[$i].profile // \"raid10\"" <<< "$RAID_ARRAYS_JSON" | tr '[:upper:]' '[:lower:]')"
    ARR_LABEL="$(jq -r ".[$i].label // empty" <<< "$RAID_ARRAYS_JSON")"
    ARR_MOUNT="$(jq -r ".[$i].mount // empty" <<< "$RAID_ARRAYS_JSON")"
    ARR_DISKS="$(jq -r ".[$i].disks // 4" <<< "$RAID_ARRAYS_JSON")"
    ARR_MIN_B="$(jq -r ".[$i].min_bytes // 0" <<< "$RAID_ARRAYS_JSON")"
    ARR_MAX_B="$(jq -r ".[$i].max_bytes // 0" <<< "$RAID_ARRAYS_JSON")"
    ARR_TBSPC="$(jq -r ".[$i].tablespace // empty" <<< "$RAID_ARRAYS_JSON")"

    [[ -z "$ARR_LABEL" || ! "$ARR_LABEL" =~ ^[A-Za-z0-9._-]+$ ]] && log_fatal "Invalid or missing Btrfs label '${ARR_LABEL}' on array '${ARR_NAME}'."
    [[ -z "$ARR_MOUNT" || "$ARR_MOUNT" != /* || "$ARR_MOUNT" == "/" ]] && log_fatal "Invalid mountpoint '${ARR_MOUNT}' on array '${ARR_NAME}'."
    case "$ARR_PROFILE" in
        raid10|raid1|raid1c3|raid1c4|raid0|single) ;;
        *) log_fatal "Unsupported Btrfs profile '${ARR_PROFILE}' on array '${ARR_NAME}'." ;;
    esac
    if [[ -n "$ARR_TBSPC" ]] && ! rvdk_validate_pg_ident "$ARR_TBSPC"; then
        log_fatal "Invalid PostgreSQL tablespace identifier '${ARR_TBSPC}' (expected lowercase [a-z_][a-z0-9_]{0,62})."
    fi

    STEP_PCT=$(( 25 + ((i * 70) / ARRAY_COUNT) ))
    TYPE_UPPER="$(tr '[:lower:]' '[:upper:]' <<< "$ARR_TYPE")"
    rvdk_prog "$STEP_PCT" "Btrfs RAID (${ARR_PROFILE}): converging ${ARR_NAME} (${ARR_LABEL})..."
    log_info "Checking ${ARR_NAME} [${TYPE_UPPER}] (${ARR_LABEL} -> ${ARR_MOUNT})..."
    EXISTING_DEV="$(blkid -L "$ARR_LABEL" 2>/dev/null || true)"

    if [[ -n "$EXISTING_DEV" && "$FORCE_WIPE_RAID" == "false" ]]; then
        log_skip "${ARR_NAME} volume '${ARR_LABEL}' already exists on ${EXISTING_DEV}"
    else
        umount -f "$ARR_MOUNT" 2>/dev/null || true
        CANDIDATE_DISKS=()

        # Prefer explicit device list if provided in JSON
        while IFS= read -r explicit_dev; do
            [[ -n "$explicit_dev" ]] && CANDIDATE_DISKS+=("$explicit_dev")
        done < <(jq -r ".[$i].devices[]? // empty" <<< "$RAID_ARRAYS_JSON")

        if (( ${#CANDIDATE_DISKS[@]} == 0 )); then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                d_path="$(awk '{print $1}' <<< "$line")"
                d_size="$(awk '{print $2}' <<< "$line")"
                d_type="$(awk '{print $3}' <<< "$line")"
                [[ "$d_type" != "disk" ]] && continue
                [[ "$d_path" == /dev/nvme* || "$d_path" == /dev/mmcblk* || "$d_path" == /dev/zram* ]] && continue
                rvdk_device_backs_os_or_swap "$d_path" && continue
                if [[ "$FORCE_WIPE_RAID" == "false" ]] && ! rvdk_disk_is_blank "$d_path"; then
                    continue
                fi
                if (( d_size >= ARR_MIN_B && d_size <= ARR_MAX_B )); then
                    CANDIDATE_DISKS+=("$d_path")
                fi
            done < <(lsblk -b -dn -o PATH,SIZE,TYPE)

            if (( ${#CANDIDATE_DISKS[@]} != ARR_DISKS )); then
                log_fatal "${ARR_NAME} requires ${ARR_DISKS} eligible blank disks between ${ARR_MIN_B} and ${ARR_MAX_B} bytes; found ${#CANDIDATE_DISKS[@]} (${CANDIDATE_DISKS[*]:-none}). Specify explicit \"devices\" or pass --force-wipe if re-initializing existing drives."
            fi
        fi

        for d in "${CANDIDATE_DISKS[@]}"; do
            rvdk_assert_device_safe_to_wipe "$d" "$FORCE_WIPE_RAID" "$ARR_LABEL"
        done

        log_info "Formatting native Btrfs (${ARR_PROFILE}) '${ARR_LABEL}' across: ${CANDIDATE_DISKS[*]}"
        for d in "${CANDIDATE_DISKS[@]}"; do
            wipefs -af "$d" >/dev/null 2>&1 || true
        done
        mkfs.btrfs -f -L "$ARR_LABEL" -d "$ARR_PROFILE" -m "$ARR_PROFILE" "${CANDIDATE_DISKS[@]}"
        btrfs device scan >/dev/null 2>&1 || true
        udevadm settle
        log_ok "Created ${#CANDIDATE_DISKS[@]}-drive Btrfs (${ARR_PROFILE}) volume '${ARR_LABEL}'"
    fi

    mkdir -p "$ARR_MOUNT"
    FSTAB_RAID="LABEL=${ARR_LABEL}  ${ARR_MOUNT}  btrfs  rw,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=30s  0  2"
    if ! grep -qE "^LABEL=${ARR_LABEL}[[:space:]]+${ARR_MOUNT}[[:space:]]+btrfs" /etc/fstab; then
        sed -i "\|LABEL=${ARR_LABEL}|d" /etc/fstab 2>/dev/null || true
        sed -i "\|[[:space:]]${ARR_MOUNT}[[:space:]]|d" /etc/fstab 2>/dev/null || true
        printf '%s\n' "$FSTAB_RAID" >> /etc/fstab
        systemctl daemon-reload
        log_ok "Added ${ARR_LABEL} to /etc/fstab"
    else
        log_skip "${ARR_LABEL} already in /etc/fstab"
    fi

    if ! mountpoint -q "$ARR_MOUNT"; then
        mount "$ARR_MOUNT"
        log_ok "Mounted ${ARR_MOUNT}"
    else
        log_skip "${ARR_MOUNT} is already mounted"
    fi

    # Pre-create declared subdirectories (.subdirs[] with .nfs_dirs[] backwards compatibility)
    while IFS= read -r subdir; do
        [[ -z "$subdir" ]] && continue
        if ! rvdk_validate_rel_subdir "$subdir"; then
            log_fatal "Rejected unsafe relative subdirectory '${subdir}' on ${ARR_MOUNT}."
        fi
        install -d -m 0775 -o "$REAL_USER" -g "$REAL_GRP" "${ARR_MOUNT}/${subdir}"
    done < <(jq -r "(.[$i].subdirs // .[$i].nfs_dirs // [])[]?" <<< "$RAID_ARRAYS_JSON")

    # Pre-stage and bind PostgreSQL tablespace if Postgres is active
    if [[ -n "$ARR_TBSPC" ]]; then
        TBSPC_DIR="${ARR_MOUNT}/postgresql/tablespaces"
        if id -u postgres >/dev/null 2>&1; then
            install -d -m 0700 -o postgres -g postgres "$TBSPC_DIR"
            if systemctl is-active --quiet postgresql 2>/dev/null; then
                EXISTS_TS="$(sudo -u postgres psql -v ts="$ARR_TBSPC" -tAc "SELECT 1 FROM pg_tablespace WHERE spcname = :'ts';" | xargs || true)"
                if [[ "$EXISTS_TS" != "1" ]]; then
                    ESCAPED_LOC="${TBSPC_DIR//\'/\'\'}"
                    sudo -u postgres psql -c "CREATE TABLESPACE \"${ARR_TBSPC}\" LOCATION '${ESCAPED_LOC}';" >/dev/null
                    log_ok "Registered PostgreSQL Tablespace '${ARR_TBSPC}' -> ${TBSPC_DIR}"
                else
                    log_skip "PostgreSQL Tablespace '${ARR_TBSPC}' already registered"
                fi
            fi
        fi
    fi
done

rvdk_prog 100 "Btrfs RAID volumes converged"
