#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Utility: Live LVM Elastic Storage Manager & Autotuner
# Path: riscv-data-kit/utils/storage.sh
#
# Description:
#   Zero-downtime online capacity management for RVDK 4Kn Single/Dual-LVM NVMe
#   volume groups (`lv_pgdata` XFS/ext4 + `lv_nfsvault` Btrfs/XFS + Elastic Pool):
#     • status      : Inspect VG elastic pool, LV allocations, and FS usage
#     • grow-psql   : Grow PostgreSQL LV (`lv_pgdata`) + XFS/ext4 online
#     • grow-nfs    : Grow NFS Vault LV (`lv_nfsvault`) + Btrfs/XFS/ext4 online
#     • shrink-nfs  : Shrink Btrfs NFS Vault LV online & return extents to VG pool
#     • autotune    : Usage-driven elastic pool autobalancing (PostgreSQL VIP)
#
# Usage:
#   rvdk storage [status]
#   sudo rvdk storage grow-psql --gb 100 [--dry-run]
#   sudo rvdk storage grow-nfs --mb 500 [--dry-run]
#   sudo rvdk storage shrink-nfs --gb 50 [--dry-run]
#   sudo rvdk storage autotune [--dry-run] [--high-water 75] [--target-util 60]
# ==============================================================================

# Ensure compatibility when invoked via `zsh` or `bash`
if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L ksh
    setopt PIPE_FAIL ERR_RETURN NO_UNSET
else
    set -Eeuo pipefail
fi

print_storage_help() {
    cat <<'EOF'
Usage:
  sudo rvdk storage [status]
  sudo rvdk storage grow-psql  (--gb <N> | --mb <N> | --tb <N> | --pct-free <1..100>) [--dry-run]
  sudo rvdk storage grow-nfs   (--gb <N> | --mb <N> | --tb <N> | --pct-free <1..100>) [--dry-run]
  sudo rvdk storage shrink-nfs (--gb <N> | --mb <N> | --tb <N>) [--dry-run]
  sudo rvdk storage autotune   [--dry-run] [--high-water <pct>] [--target-util <pct>]
                               [--min-reserve-pct <pct>] [--no-shrink] [--distribute-pool]

Subcommands:
  status                  Display VG elastic reserve pool, LV geometry, and live FS usage
  grow-psql (grow-pg)     Extend PostgreSQL LV (lv_pgdata) & grow XFS/ext4 online
  grow-nfs                Extend NFS Vault LV (lv_nfsvault) & grow Btrfs/XFS/ext4 online
  shrink-nfs              Shrink Btrfs NFS Vault LV online and return extents to VG reserve
  autotune                Autobalance elastic VG extents based on live FS usage patterns:
                            • Grows any LV >= --high-water (default 75%) back to --target-util (60%)
                            • Prioritizes PostgreSQL 1.5x over NFS when pool extents are scarce
                            • Reclaims idle Btrfs slack (<30% used) if PSQL needs space & pool is dry
                            • Preserves --min-reserve-pct (default 5%) unless critical (>=88% full)

Size & Tuning Options:
  --gb <N>                Size delta in GiB (supports decimals, e.g. --gb 100 or --gb 2.5)
  --mb <N>                Size delta in MiB (e.g. --mb 500)
  --tb <N>                Size delta in TiB (e.g. --tb 1)
  --pct-free <1..100>     Percentage of unallocated VG elastic pool extents (grow-* only)
  --vg <vg_name>          Explicit LVM Volume Group override (auto-detected by default)
  --dry-run               Compute and print exact LVM/FS resize plan without mutating disks
  --distribute-pool       (autotune) Proportionally distribute elastic pool even below high-water
EOF
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help|help)
                print_storage_help
                exit 0
                ;;
        esac
    done

    local script_self="${BASH_SOURCE[0]:-}"
    if [[ $EUID -ne 0 ]]; then
        if [[ -n "$script_self" && -f "$script_self" ]] && command -v sudo >/dev/null 2>&1; then
            exec sudo -E bash "$script_self" "$@"
        else
            echo "[RVDK:FATAL] Run as root: sudo rvdk storage $*" >&2
            exit 1
        fi
    fi

    log_info()  { printf "\033[1;36m[RVDK:STORAGE]\033[0m %s\n" "$1"; }
    log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
    log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
    log_plan()  { printf "\033[1;35m[PLAN]\033[0m %s\n" "$1"; }
    log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
    log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_fatal "'rvdk storage' live LVM operations require a Linux target node (detected $(uname -s))."
    fi

    if ! command -v vgs >/dev/null 2>&1 || ! command -v lvs >/dev/null 2>&1; then
        log_fatal "LVM2 utilities (vgs/lvs/lvextend) are not installed on this node."
    fi

    local caller_user="${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo root)}"
    local caller_home
    caller_home="$(getent passwd "$caller_user" 2>/dev/null | cut -d: -f6 || true)"
    [[ -z "$caller_home" ]] && caller_home="/root"

    # Load optional environment defaults without clobbering explicit caller env vars
    local preset_vg="${VG_NAME:-}"
    local preset_pg_mnt="${MOUNT_POINT:-}"
    local preset_nfs_mnt="${NFS_MOUNT_POINT:-}"
    local env_file="${RVDK_ENV_FILE:-${caller_home}/.rvdk/config.env}"
    if [[ -f "$env_file" ]]; then
        # shellcheck disable=SC1090
        source "$env_file"
    fi
    local vg_name="${preset_vg:-${VG_NAME:-}}"
    local pg_mount="${preset_pg_mnt:-${MOUNT_POINT:-/mnt/nvme_pgdata}}"
    local nfs_mount="${preset_nfs_mnt:-${NFS_MOUNT_POINT:-/mnt/nfs_vault}}"
    local pg_lv="${LV_NAME:-lv_pgdata}"
    local nfs_lv="${NFS_LV_NAME:-lv_nfsvault}"

    local subcmd="status"
    if [[ $# -gt 0 && "$1" != -* ]]; then
        subcmd="$(tr '[:upper:]' '[:lower:]' <<< "$1")"
        shift
    fi

    local size_gb=""
    local size_mb=""
    local size_tb=""
    local pct_free=""
    local dry_run="false"
    local high_water=75
    local target_util=60
    local low_water=30
    local min_reserve_pct=5
    local allow_shrink="true"
    local distribute_pool="false"
    local cli_vg=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            status|--status)
                subcmd="status"; shift ;;
            --gb)
                size_gb="${2:-}"; shift 2 ;;
            --gb=*)
                size_gb="${1#*=}"; shift ;;
            --mb)
                size_mb="${2:-}"; shift 2 ;;
            --mb=*)
                size_mb="${1#*=}"; shift ;;
            --tb)
                size_tb="${2:-}"; shift 2 ;;
            --tb=*)
                size_tb="${1#*=}"; shift ;;
            --pct-free)
                pct_free="${2:-}"; shift 2 ;;
            --pct-free=*)
                pct_free="${1#*=}"; shift ;;
            --vg)
                cli_vg="${2:-}"; shift 2 ;;
            --pg-mount|--mount-point)
                pg_mount="${2:-}"; shift 2 ;;
            --nfs-mount)
                nfs_mount="${2:-}"; shift 2 ;;
            --dry-run|-n)
                dry_run="true"; shift ;;
            --high-water)
                high_water="${2:-75}"; shift 2 ;;
            --target-util)
                target_util="${2:-60}"; shift 2 ;;
            --min-reserve-pct)
                min_reserve_pct="${2:-5}"; shift 2 ;;
            --no-shrink)
                allow_shrink="false"; shift ;;
            --distribute-pool)
                distribute_pool="true"; shift ;;
            *)
                log_fatal "Unknown option for 'rvdk storage ${subcmd}': $1 (run 'rvdk storage --help')" ;;
        esac
    done

    [[ -n "$cli_vg" ]] && vg_name="$cli_vg"

    # Auto-discover active Volume Group if unspecified or absent
    if [[ -z "$vg_name" ]] || ! vgs "$vg_name" >/dev/null 2>&1; then
        local detected_vg=""
        local m_src
        for m_cand in "$pg_mount" "$nfs_mount"; do
            m_src="$(findmnt -n -o SOURCE "$m_cand" 2>/dev/null || true)"
            if [[ -n "$m_src" ]]; then
                detected_vg="$(lvs --noheadings -o vg_name "$m_src" 2>/dev/null | awk '{print $1; exit}' || true)"
                [[ -n "$detected_vg" ]] && break
            fi
        done
        if [[ -z "$detected_vg" ]]; then
            detected_vg="$(lvs --noheadings -o vg_name,lv_name 2>/dev/null | awk -v p="$pg_lv" -v n="$nfs_lv" '$2==p || $2==n {print $1; exit}' || true)"
        fi
        if [[ -z "$detected_vg" ]] && vgs vg_rvdk >/dev/null 2>&1; then
            detected_vg="vg_rvdk"
        fi
        [[ -n "$detected_vg" ]] && vg_name="$detected_vg"
    fi

    if [[ -z "$vg_name" ]] || ! vgs "$vg_name" >/dev/null 2>&1; then
        log_fatal "Could not locate an active LVM Volume Group (checked '${vg_name:-auto}'). Provision NVMe first via 'sudo rvdk mods/nvme-4kn'."
    fi

    # Helpers for byte formatting & extent math
    human_bytes() {
        awk -v b="${1:-0}" 'BEGIN {
            if (b >= 1099511627776)      printf "%.2f TiB", b / 1099511627776;
            else if (b >= 1073741824)    printf "%.2f GiB", b / 1073741824;
            else if (b >= 1048576)       printf "%.1f MiB", b / 1048576;
            else                         printf "%d B", b;
        }'
    }

    parse_requested_extents() {
        local pe_bytes="$1"
        local free_ext="$2"
        local mode_cnt=0
        [[ -n "$size_gb" ]]  && mode_cnt=$(( mode_cnt + 1 ))
        [[ -n "$size_mb" ]]  && mode_cnt=$(( mode_cnt + 1 ))
        [[ -n "$size_tb" ]]  && mode_cnt=$(( mode_cnt + 1 ))
        [[ -n "$pct_free" ]] && mode_cnt=$(( mode_cnt + 1 ))

        if (( mode_cnt == 0 )); then
            log_fatal "Specify a size flag: --gb <N>, --mb <N>, --tb <N>, or --pct-free <1..100>."
        elif (( mode_cnt > 1 )); then
            log_fatal "Specify only one size flag (--gb, --mb, --tb, or --pct-free)."
        fi

        if [[ -n "$pct_free" ]]; then
            if [[ ! "$pct_free" =~ ^[0-9]+$ ]] || (( pct_free < 1 || pct_free > 100 )); then
                log_fatal "--pct-free must be an integer between 1 and 100 (got '${pct_free}')."
            fi
            local ext=$(( (free_ext * pct_free) / 100 ))
            (( ext < 1 && free_ext >= 1 )) && ext=1
            echo "$ext"
            return 0
        fi

        local val="" mult=1
        if [[ -n "$size_tb" ]]; then
            val="$size_tb"; mult=1099511627776
        elif [[ -n "$size_gb" ]]; then
            val="$size_gb"; mult=1073741824
        else
            val="$size_mb"; mult=1048576
        fi

        if [[ ! "$val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            log_fatal "Invalid numeric size value: '${val}'."
        fi

        local req_bytes
        req_bytes="$(awk -v v="$val" -v m="$mult" 'BEGIN { b = int(v * m + 0.5); if (b <= 0) exit 1; printf "%.0f", b }' || true)"
        [[ -z "$req_bytes" ]] && log_fatal "Requested size must be greater than 0."

        local ext
        ext="$(awk -v b="$req_bytes" -v pe="$pe_bytes" 'BEGIN { e = int((b + pe - 1) / pe); if (e < 1) e = 1; printf "%.0f", e }')"
        echo "$ext"
    }

    # Read live VG geometry
    local vg_raw vg_size_b vg_free_b vg_pe_b vg_ext_total vg_ext_free
    read_vg_metrics() {
        vg_raw="$(vgs --units b --nosuffix --noheadings -o vg_size,vg_free,vg_extent_size,vg_extent_count,vg_free_count "$vg_name" 2>/dev/null | awk '{print $1,$2,$3,$4,$5; exit}')"
        read -r vg_size_b vg_free_b vg_pe_b vg_ext_total vg_ext_free <<< "$vg_raw"
    }

    # Read live LV + mounted filesystem metrics:
    # Sets globals: LV_EXISTS LV_PATH LV_SIZE_B LV_EXT LV_MNT LV_FSTYPE FS_SIZE_B FS_USED_B FS_AVAIL_B FS_UTIL_PCT
    probe_lv() {
        local lv_n="$1"
        local fallback_mnt="$2"
        LV_EXISTS="false"
        LV_PATH="/dev/${vg_name}/${lv_n}"
        LV_SIZE_B=0
        LV_EXT=0
        LV_MNT=""
        LV_FSTYPE="unmounted"
        FS_SIZE_B=0
        FS_USED_B=0
        FS_AVAIL_B=0
        FS_UTIL_PCT=0

        if lvs "${vg_name}/${lv_n}" >/dev/null 2>&1; then
            LV_EXISTS="true"
            local lv_info
            lv_info="$(lvs --units b --nosuffix --noheadings -o lv_size,lv_kernel_major,lv_kernel_minor "${vg_name}/${lv_n}" 2>/dev/null | awk '{print $1; exit}')"
            LV_SIZE_B="${lv_info:-0}"
            LV_EXT=$(( LV_SIZE_B / vg_pe_b ))

            if mountpoint -q "$fallback_mnt" 2>/dev/null; then
                LV_MNT="$fallback_mnt"
            else
                LV_MNT="$(findmnt -rn -S "$LV_PATH" -o TARGET 2>/dev/null | head -n1 || true)"
                if [[ -z "$LV_MNT" && -e "/dev/mapper/${vg_name}-${lv_n}" ]]; then
                    LV_MNT="$(findmnt -rn -S "/dev/mapper/${vg_name}-${lv_n}" -o TARGET 2>/dev/null | head -n1 || true)"
                fi
            fi

            if [[ -n "$LV_MNT" ]]; then
                LV_FSTYPE="$(findmnt -rn -M "$LV_MNT" -o FSTYPE 2>/dev/null | head -n1 || echo "unknown")"
                local df_line
                df_line="$(df -B1 --output=size,used,avail "$LV_MNT" 2>/dev/null | tail -n1 || true)"
                if [[ -n "$df_line" ]]; then
                    read -r FS_SIZE_B FS_USED_B FS_AVAIL_B <<< "$df_line"
                    if (( FS_SIZE_B > 0 )); then
                        FS_UTIL_PCT=$(( (FS_USED_B * 100 + FS_SIZE_B / 2) / FS_SIZE_B ))
                    fi
                fi
            fi
        fi
    }

    print_status_report() {
        read_vg_metrics
        local reserve_pct=0
        (( vg_ext_total > 0 )) && reserve_pct=$(( (vg_ext_free * 100) / vg_ext_total ))

        printf "\033[1;36m[RVDK:STORAGE]\033[0m Volume Group '%s' Elastic Layout\n" "$vg_name"
        printf "  • Total VG Capacity  : %s (%d extents @ %s)\n" \
            "$(human_bytes "$vg_size_b")" "$vg_ext_total" "$(human_bytes "$vg_pe_b")"
        printf "  • Elastic VG Reserve : %s free (%d%% unallocated | %d extents)\n" \
            "$(human_bytes "$vg_free_b")" "$reserve_pct" "$vg_ext_free"

        probe_lv "$pg_lv" "$pg_mount"
        if [[ "$LV_EXISTS" == "true" ]]; then
            if [[ -n "$LV_MNT" ]]; then
                printf "  • PSQL LV (%-9s): %s [%s @ %s] — Used: %s / %s (%d%% | Avail: %s)\n" \
                    "$pg_lv" "$(human_bytes "$LV_SIZE_B")" "$LV_FSTYPE" "$LV_MNT" \
                    "$(human_bytes "$FS_USED_B")" "$(human_bytes "$FS_SIZE_B")" "$FS_UTIL_PCT" "$(human_bytes "$FS_AVAIL_B")"
            else
                printf "  • PSQL LV (%-9s): %s [unmounted]\n" "$pg_lv" "$(human_bytes "$LV_SIZE_B")"
            fi
        else
            printf "  • PSQL LV (%-9s): not provisioned\n" "$pg_lv"
        fi

        probe_lv "$nfs_lv" "$nfs_mount"
        if [[ "$LV_EXISTS" == "true" ]]; then
            if [[ -n "$LV_MNT" ]]; then
                printf "  • NFS  LV (%-9s): %s [%s @ %s] — Used: %s / %s (%d%% | Avail: %s)\n" \
                    "$nfs_lv" "$(human_bytes "$LV_SIZE_B")" "$LV_FSTYPE" "$LV_MNT" \
                    "$(human_bytes "$FS_USED_B")" "$(human_bytes "$FS_SIZE_B")" "$FS_UTIL_PCT" "$(human_bytes "$FS_AVAIL_B")"
            else
                printf "  • NFS  LV (%-9s): %s [unmounted]\n" "$nfs_lv" "$(human_bytes "$LV_SIZE_B")"
            fi
        else
            printf "  • NFS  LV (%-9s): not provisioned (single-LV layout)\n" "$nfs_lv"
        fi
    }

    extend_lv_online() {
        local label="$1"
        local lv_n="$2"
        local fallback_mnt="$3"
        local add_ext="$4"

        read_vg_metrics
        probe_lv "$lv_n" "$fallback_mnt"
        [[ "$LV_EXISTS" != "true" ]] && log_fatal "${label} logical volume '${vg_name}/${lv_n}' does not exist."
        [[ -z "$LV_MNT" ]] && log_fatal "${label} logical volume '${LV_PATH}' is not mounted; mount it before online resize."

        if (( vg_ext_free <= 0 )); then
            log_fatal "Elastic VG reserve in '${vg_name}' has 0 free extents ($(human_bytes "$vg_free_b")). If '${nfs_lv}' is Btrfs with idle space, reclaim extents via 'sudo rvdk storage shrink-nfs --gb <N>'."
        fi

        # Allow 1-extent rounding tolerance when user asks for exact GiB matching remaining pool
        if (( add_ext == vg_ext_free + 1 )); then
            add_ext="$vg_ext_free"
        elif (( add_ext > vg_ext_free )); then
            log_fatal "Requested +$(human_bytes $(( add_ext * vg_pe_b ))) (${add_ext} extents) exceeds '${vg_name}' free elastic reserve of $(human_bytes "$vg_free_b") (${vg_ext_free} extents)."
        fi

        local add_bytes=$(( add_ext * vg_pe_b ))
        local new_bytes=$(( LV_SIZE_B + add_bytes ))

        if [[ "$dry_run" == "true" ]]; then
            log_plan "[DRY-RUN] Grow ${label} (${vg_name}/${lv_n} @ ${LV_MNT}, ${LV_FSTYPE}): $(human_bytes "$LV_SIZE_B") -> $(human_bytes "$new_bytes") (+$(human_bytes "$add_bytes") / +${add_ext} extents)"
            return 0
        fi

        log_info "Extending ${label} (${LV_PATH}) by +$(human_bytes "$add_bytes") (+${add_ext} extents)..."
        lvextend -l "+${add_ext}" "$LV_PATH" >/dev/null

        case "$LV_FSTYPE" in
            xfs)
                xfs_growfs "$LV_MNT" >/dev/null
                ;;
            btrfs)
                btrfs filesystem resize max "$LV_MNT" >/dev/null
                ;;
            ext4|ext3|ext2)
                resize2fs "$LV_PATH" >/dev/null
                ;;
            *)
                log_warn "Extended LV '${LV_PATH}', but filesystem '${LV_FSTYPE}' has no built-in online grow handler."
                ;;
        esac

        log_ok "${label} (${LV_MNT}) grown online -> $(human_bytes "$new_bytes")"
    }

    shrink_btrfs_lv_online() {
        local lv_n="$1"
        local fallback_mnt="$2"
        local sub_ext="$3"

        read_vg_metrics
        probe_lv "$lv_n" "$fallback_mnt"
        [[ "$LV_EXISTS" != "true" ]] && log_fatal "NFS Vault logical volume '${vg_name}/${lv_n}' does not exist."
        [[ -z "$LV_MNT" ]] && log_fatal "NFS Vault '${LV_PATH}' must be mounted for online Btrfs shrink."
        if [[ "$LV_FSTYPE" != "btrfs" ]]; then
            log_fatal "Online live shrink requires Btrfs ('${LV_MNT}' is formatted as '${LV_FSTYPE}'). XFS does not support shrinking."
        fi

        # Safety floor: max(used * 1.25 + 2 GiB, 4 GiB) + 64 MiB resize cushion
        local two_gib=$(( 2 * 1073741824 ))
        local four_gib=$(( 4 * 1073741824 ))
        local cushion_b=$(( 64 * 1048576 ))
        local min_safe_b=$(( (FS_USED_B * 125) / 100 + two_gib ))
        (( min_safe_b < four_gib )) && min_safe_b="$four_gib"

        local sub_bytes=$(( sub_ext * vg_pe_b ))
        local new_lv_ext=$(( LV_EXT - sub_ext ))
        local new_lv_b=$(( new_lv_ext * vg_pe_b ))

        if (( new_lv_b < min_safe_b )); then
            local max_reclaim_b=$(( LV_SIZE_B - min_safe_b ))
            (( max_reclaim_b < 0 )) && max_reclaim_b=0
            log_fatal "Refusing to shrink '${LV_MNT}' to $(human_bytes "$new_lv_b") (minimum safe floor for $(human_bytes "$FS_USED_B") used data is $(human_bytes "$min_safe_b"); max reclaimable right now: $(human_bytes "$max_reclaim_b"))."
        fi

        if [[ "$dry_run" == "true" ]]; then
            log_plan "[DRY-RUN] Shrink NFS Vault (${vg_name}/${lv_n} @ ${LV_MNT}, btrfs): $(human_bytes "$LV_SIZE_B") -> $(human_bytes "$new_lv_b") (-$(human_bytes "$sub_bytes") / -${sub_ext} extents returned to ${vg_name})"
            return 0
        fi

        local fs_pre_target=$(( new_lv_b - cushion_b ))
        log_info "Shrinking Btrfs filesystem on ${LV_MNT} & returning $(human_bytes "$sub_bytes") (${sub_ext} extents) to '${vg_name}'..."
        btrfs filesystem resize "$fs_pre_target" "$LV_MNT" >/dev/null
        lvreduce -f -y -l "$new_lv_ext" "$LV_PATH" >/dev/null
        btrfs filesystem resize max "$LV_MNT" >/dev/null
        log_ok "Shrank ${LV_MNT} online -> $(human_bytes "$new_lv_b") (+$(human_bytes "$sub_bytes") returned to '${vg_name}' elastic pool)"
    }

    run_autotune() {
        if [[ ! "$high_water" =~ ^[0-9]+$ || ! "$target_util" =~ ^[0-9]+$ || ! "$min_reserve_pct" =~ ^[0-9]+$ ]]; then
            log_fatal "--high-water, --target-util, and --min-reserve-pct must be integers."
        fi
        if (( target_util < 20 || target_util >= high_water || high_water > 95 )); then
            log_fatal "Require 20 <= --target-util (${target_util}) < --high-water (${high_water}) <= 95."
        fi

        read_vg_metrics
        probe_lv "$pg_lv" "$pg_mount"
        local pg_present="$LV_EXISTS" pg_mnt_cur="$LV_MNT" pg_fs="$LV_FSTYPE"
        local pg_size_b="$LV_SIZE_B" pg_used_b="$FS_USED_B" pg_util="$FS_UTIL_PCT"

        probe_lv "$nfs_lv" "$nfs_mount"
        local nfs_present="$LV_EXISTS" nfs_mnt_cur="$LV_MNT" nfs_fs="$LV_FSTYPE"
        local nfs_size_b="$LV_SIZE_B" nfs_used_b="$FS_USED_B" nfs_util="$FS_UTIL_PCT"

        log_info "Evaluating live storage telemetry on '${vg_name}' (high-water=${high_water}%, target=${target_util}%, min-reserve=${min_reserve_pct}%)..."

        local min_add_b=1073741824 # 1 GiB minimum meaningful step
        local want_pg_ext=0
        local want_nfs_ext=0
        local critical="false"

        if [[ "$pg_present" == "true" && -n "$pg_mnt_cur" ]] && (( pg_util >= high_water )); then
            (( pg_util >= 88 )) && critical="true"
            local target_pg_b=$(( (pg_used_b * 100) / target_util ))
            local delta_pg_b=$(( target_pg_b - pg_size_b ))
            (( delta_pg_b < min_add_b )) && delta_pg_b="$min_add_b"
            want_pg_ext=$(( (delta_pg_b + vg_pe_b - 1) / vg_pe_b ))
        fi

        if [[ "$nfs_present" == "true" && -n "$nfs_mnt_cur" ]] && (( nfs_util >= high_water )); then
            (( nfs_util >= 88 )) && critical="true"
            local target_nfs_b=$(( (nfs_used_b * 100) / target_util ))
            local delta_nfs_b=$(( target_nfs_b - nfs_size_b ))
            (( delta_nfs_b < min_add_b )) && delta_nfs_b="$min_add_b"
            want_nfs_ext=$(( (delta_nfs_b + vg_pe_b - 1) / vg_pe_b ))
        fi

        local min_res_ext=$(( (vg_ext_total * min_reserve_pct) / 100 ))
        [[ "$critical" == "true" ]] && min_res_ext=0

        local alloc_ext=$(( vg_ext_free - min_res_ext ))
        (( alloc_ext < 0 )) && alloc_ext=0

        # Optional --distribute-pool: proportionally allocate elastic reserve by current usage weight
        if (( want_pg_ext == 0 && want_nfs_ext == 0 )) && [[ "$distribute_pool" == "true" ]]; then
            if (( alloc_ext <= 0 )); then
                log_skip "No allocatable extents above ${min_reserve_pct}% minimum VG reserve (${vg_ext_free} extents free)."
                print_status_report
                return 0
            fi
            if [[ "$pg_present" == "true" && -n "$pg_mnt_cur" && "$nfs_present" == "true" && -n "$nfs_mnt_cur" ]]; then
                # Weight PostgreSQL 1.5x (3:2) with a 1 GiB floor per volume so near-empty nodes split ~60/40
                local eff_pg=$(( pg_used_b > 1073741824 ? pg_used_b : 1073741824 ))
                local eff_nfs=$(( nfs_used_b > 1073741824 ? nfs_used_b : 1073741824 ))
                want_pg_ext="$(awk -v a="$alloc_ext" -v p="$eff_pg" -v n="$eff_nfs" 'BEGIN { w_p = p * 1.5; w_n = n * 1.0; printf "%.0f", int(a * (w_p / (w_p + w_n))) }')"
                want_nfs_ext=$(( alloc_ext - want_pg_ext ))
            elif [[ "$pg_present" == "true" && -n "$pg_mnt_cur" ]]; then
                want_pg_ext="$alloc_ext"
            elif [[ "$nfs_present" == "true" && -n "$nfs_mnt_cur" ]]; then
                want_nfs_ext="$alloc_ext"
            fi
        fi

        # If PSQL needs more extents than the VG reserve holds, check if Btrfs NFS has idle slack (<30% used)
        local reclaim_nfs_ext=0
        if (( want_pg_ext > alloc_ext )) && [[ "$allow_shrink" == "true" && "$nfs_present" == "true" && -n "$nfs_mnt_cur" && "$nfs_fs" == "btrfs" ]] && (( nfs_util < low_water )); then
            local shortfall_ext=$(( want_pg_ext - alloc_ext ))
            # Keep NFS generous: at least max(2.0x used + 2 GiB, 8 GiB)
            local keep_nfs_b=$(( nfs_used_b * 2 + 2 * 1073741824 ))
            local eight_gib=$(( 8 * 1073741824 ))
            (( keep_nfs_b < eight_gib )) && keep_nfs_b="$eight_gib"
            if (( nfs_size_b > keep_nfs_b + min_add_b )); then
                local max_donor_ext=$(( (nfs_size_b - keep_nfs_b) / vg_pe_b ))
                if (( max_donor_ext > 0 )); then
                    reclaim_nfs_ext=$(( shortfall_ext < max_donor_ext ? shortfall_ext : max_donor_ext ))
                fi
            fi
        fi

        if (( want_pg_ext == 0 && want_nfs_ext == 0 )); then
            log_ok "All volumes healthy below ${high_water}% high-water mark (PSQL: ${pg_util}% used, NFS: ${nfs_util}% used)."
            log_skip "Preserving $(human_bytes "$vg_free_b") elastic VG reserve so grow-only XFS never locks in unneeded extents (pass --distribute-pool or --high-water <pct> to allocate early)."
            print_status_report
            return 0
        fi

        if (( reclaim_nfs_ext > 0 )); then
            log_info "Autotune Donor Reclaim: NFS Vault is ${nfs_util}% used (<${low_water}%); reclaiming ${reclaim_nfs_ext} extents ($(human_bytes $(( reclaim_nfs_ext * vg_pe_b )))) for PostgreSQL."
            shrink_btrfs_lv_online "$nfs_lv" "$nfs_mount" "$reclaim_nfs_ext"
            if [[ "$dry_run" == "true" ]]; then
                alloc_ext=$(( alloc_ext + reclaim_nfs_ext ))
            else
                read_vg_metrics
                alloc_ext=$(( vg_ext_free - min_res_ext ))
                (( alloc_ext < 0 )) && alloc_ext=0
            fi
        fi

        if (( alloc_ext <= 0 )); then
            log_warn "Volumes exceeded ${high_water}% high-water mark, but '${vg_name}' has 0 allocatable extents remaining ($(human_bytes "$vg_free_b") free)."
            print_status_report
            return 0
        fi

        local grant_pg_ext=0
        local grant_nfs_ext=0
        if (( want_pg_ext + want_nfs_ext <= alloc_ext )); then
            grant_pg_ext="$want_pg_ext"
            grant_nfs_ext="$want_nfs_ext"
        elif (( want_pg_ext > 0 && want_nfs_ext == 0 )); then
            grant_pg_ext="$alloc_ext"
        elif (( want_nfs_ext > 0 && want_pg_ext == 0 )); then
            grant_nfs_ext="$alloc_ext"
        else
            # Both hungry & pool scarce -> weight PostgreSQL 1.5x over NFS
            grant_pg_ext="$(awk -v a="$alloc_ext" -v p="$want_pg_ext" -v n="$want_nfs_ext" 'BEGIN {
                wp = p * 1.5; wn = n * 1.0;
                g = int(a * (wp / (wp + wn)) + 0.5);
                if (g > a) g = a;
                printf "%.0f", g;
            }')"
            grant_nfs_ext=$(( alloc_ext - grant_pg_ext ))
        fi

        (( grant_pg_ext > 0 ))  && extend_lv_online "PostgreSQL Data" "$pg_lv"  "$pg_mount"  "$grant_pg_ext"
        (( grant_nfs_ext > 0 )) && extend_lv_online "NFSv4 Vault"     "$nfs_lv" "$nfs_mount" "$grant_nfs_ext"

        print_status_report
    }

    case "$subcmd" in
        status|list|info|show)
            print_status_report
            ;;
        grow-psql|grow-pg|grow-postgres|extend-psql|add-psql|add-pg|add-postgres)
            read_vg_metrics
            local req_ext
            req_ext="$(parse_requested_extents "$vg_pe_b" "$vg_ext_free")"
            extend_lv_online "PostgreSQL Data" "$pg_lv" "$pg_mount" "$req_ext"
            print_status_report
            ;;
        grow-nfs|extend-nfs|add-nfs)
            read_vg_metrics
            local req_ext
            req_ext="$(parse_requested_extents "$vg_pe_b" "$vg_ext_free")"
            extend_lv_online "NFSv4 Vault" "$nfs_lv" "$nfs_mount" "$req_ext"
            print_status_report
            ;;
        shrink-nfs|reduce-nfs|reclaim-nfs)
            [[ -n "$pct_free" ]] && log_fatal "--pct-free is only valid when growing from free VG extents (use --gb or --mb for shrink-nfs)."
            read_vg_metrics
            local req_ext
            req_ext="$(parse_requested_extents "$vg_pe_b" "$vg_ext_free")"
            shrink_btrfs_lv_online "$nfs_lv" "$nfs_mount" "$req_ext"
            print_status_report
            ;;
        autotune|auto-tune|balance|autobalance)
            run_autotune
            ;;
        *)
            log_fatal "Unknown storage subcommand '${subcmd}' (expected: status | grow-psql | grow-nfs | shrink-nfs | autotune)."
            ;;
    esac
}

main "$@"
