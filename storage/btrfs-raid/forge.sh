#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: Declarative Native Kernel Btrfs RAID 10 Builder
# Path: riscv-data-kit/storage/btrfs-raid/forge.sh
#
# Usage:
#   sudo rvdk storage/btrfs-raid [--force-wipe-raid]
#   curl -fsSL https://rvdk.drewv-labs.dev/storage/btrfs-raid/forge.sh | sudo bash
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
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
NODE_ENV="${BRAKERRAK_NODE_ENV:-${REAL_HOME}/.brakerrak/node.env}"
# shellcheck disable=SC1090
[[ -f "$NODE_ENV" ]] && source "$NODE_ENV"

FORCE_WIPE_RAID="${FORCE_WIPE_RAID:-false}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) RAID_ARRAYS_JSON="${2:-[]}"; shift 2 ;;
        --force-wipe|--force-wipe-raid) FORCE_WIPE_RAID="true"; shift ;;
        *) shift ;;
    esac
done

RAID_ARRAYS_JSON="${RAID_ARRAYS_JSON:-[]}"

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

log_info()  { printf "\033[1;36m[RVDK:RAID10]\033[0m %s\n" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

apt-get update -q
apt-get install "${APT_FLAGS[@]}" btrfs-progs jq util-linux

ARRAY_COUNT="$(jq 'length' <<< "$RAID_ARRAYS_JSON" 2>/dev/null || echo 0)"
if (( ARRAY_COUNT == 0 )); then
    log_skip "RAID_ARRAYS_JSON is empty; no Btrfs RAID 10 arrays requested."
    exit 0
fi

btrfs device scan >/dev/null 2>&1 || true

for (( i=0; i<ARRAY_COUNT; i++ )); do
    ARR_NAME="$(jq -r ".[$i].name" <<< "$RAID_ARRAYS_JSON")"
    ARR_TYPE="$(jq -r ".[$i].type // \"warm\"" <<< "$RAID_ARRAYS_JSON")"
    ARR_LABEL="$(jq -r ".[$i].label" <<< "$RAID_ARRAYS_JSON")"
    ARR_MOUNT="$(jq -r ".[$i].mount" <<< "$RAID_ARRAYS_JSON")"
    ARR_DISKS="$(jq -r ".[$i].disks // 4" <<< "$RAID_ARRAYS_JSON")"
    ARR_MIN_B="$(jq -r ".[$i].min_bytes" <<< "$RAID_ARRAYS_JSON")"
    ARR_MAX_B="$(jq -r ".[$i].max_bytes" <<< "$RAID_ARRAYS_JSON")"
    ARR_TBSPC="$(jq -r ".[$i].tablespace // empty" <<< "$RAID_ARRAYS_JSON")"

    log_info "Checking ${ARR_NAME} [${ARR_TYPE^^}] (${ARR_LABEL} -> ${ARR_MOUNT})..."
    EXISTING_DEV="$(blkid -L "$ARR_LABEL" || true)"

    if [[ -n "$EXISTING_DEV" && "$FORCE_WIPE_RAID" == "false" ]]; then
        log_skip "${ARR_NAME} volume '${ARR_LABEL}' already exists on ${EXISTING_DEV}"
    else
        umount -f "$ARR_MOUNT" 2>/dev/null || true
        CANDIDATE_DISKS=()
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            d_path="$(awk '{print $1}' <<< "$line")"
            d_size="$(awk '{print $2}' <<< "$line")"
            d_type="$(awk '{print $3}' <<< "$line")"
            [[ "$d_type" != "disk" ]] && continue
            [[ "$d_path" == /dev/nvme* || "$d_path" == /dev/mmcblk* ]] && continue
            if lsblk -no MOUNTPOINT "$d_path" 2>/dev/null | grep -qE "^/"; then
                continue
            fi
            if (( d_size >= ARR_MIN_B && d_size <= ARR_MAX_B )); then
                CANDIDATE_DISKS+=("$d_path")
            fi
        done < <(lsblk -b -dn -o PATH,SIZE,TYPE)

        if (( ${#CANDIDATE_DISKS[@]} != ARR_DISKS )); then
            log_fatal "${ARR_NAME} requires ${ARR_DISKS} unmounted disks between ${ARR_MIN_B} and ${ARR_MAX_B} bytes; found ${#CANDIDATE_DISKS[@]} (${CANDIDATE_DISKS[*]:-none})."
        fi

        log_info "Formatting native Btrfs RAID 10 '${ARR_LABEL}' across: ${CANDIDATE_DISKS[*]}"
        for d in "${CANDIDATE_DISKS[@]}"; do
            wipefs -af "$d" >/dev/null 2>&1 || true
        done
        mkfs.btrfs -f -L "$ARR_LABEL" -d raid10 -m raid10 "${CANDIDATE_DISKS[@]}"
        btrfs device scan >/dev/null 2>&1 || true
        udevadm settle
        log_ok "Created 4-drive Btrfs RAID 10 volume '${ARR_LABEL}'"
    fi

    mkdir -p "$ARR_MOUNT"
    FSTAB_RAID="LABEL=${ARR_LABEL}  ${ARR_MOUNT}  btrfs  rw,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=30s  0  2"
    if ! grep -qE "^LABEL=${ARR_LABEL}[[:space:]]+${ARR_MOUNT}[[:space:]]+btrfs" /etc/fstab; then
        sed -i "\|LABEL=${ARR_LABEL}|d" /etc/fstab 2>/dev/null || true
        sed -i "\|[[:space:]]${ARR_MOUNT}[[:space:]]|d" /etc/fstab 2>/dev/null || true
        echo "$FSTAB_RAID" >> /etc/fstab
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

    # Pre-create declared NFS/vault subdirectories
    while IFS= read -r subdir; do
        [[ -z "$subdir" ]] && continue
        install -d -m 0775 -o "$REAL_USER" -g "$REAL_USER" "${ARR_MOUNT}/${subdir}"
    done < <(jq -r ".[$i].nfs_dirs[]? // empty" <<< "$RAID_ARRAYS_JSON")

    # Pre-stage and bind PostgreSQL tablespace if Postgres is active
    if [[ -n "$ARR_TBSPC" ]]; then
        TBSPC_DIR="${ARR_MOUNT}/postgresql/tablespaces"
        if id -u postgres >/dev/null 2>&1; then
            install -d -m 0700 -o postgres -g postgres "$TBSPC_DIR"
            if systemctl is-active --quiet postgresql 2>/dev/null; then
                EXISTS_TS="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_tablespace WHERE spcname='${ARR_TBSPC}';" | xargs || true)"
                if [[ "$EXISTS_TS" != "1" ]]; then
                    sudo -u postgres psql -c "CREATE TABLESPACE ${ARR_TBSPC} LOCATION '${TBSPC_DIR}';" >/dev/null
                    log_ok "Registered PostgreSQL Tablespace '${ARR_TBSPC}' -> ${TBSPC_DIR}"
                else
                    log_skip "PostgreSQL Tablespace '${ARR_TBSPC}' already registered"
                fi
            fi
        fi
    fi
done
