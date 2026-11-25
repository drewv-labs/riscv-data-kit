#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Utility: Live LVM Elastic Storage Manager & Autotuner
# Path: riscv-data-kit/utils/storage.sh
#
# Description:
#   Zero-downtime online capacity management for RVDK 4Kn LVM volume groups:
#     • status      : Dynamically inspect VG elastic pool, all LVs, and FS usage
#     • grow        : Grow any LV (--lv <name>) + XFS/Btrfs/ext4 online
#     • shrink      : Shrink any mounted Btrfs LV (--lv <name>) online safely
#     • autotune    : Usage-driven elastic pool autobalancing across mounted LVs
#
# Usage:
#   sudo rvdk storage [status]
#   sudo rvdk storage grow --lv lv_data --gb 100 [--dry-run]
#   sudo rvdk storage shrink --lv lv_secondary --gb 50 [--dry-run]
#   sudo rvdk storage autotune [--weights lv_data:1.5,lv_secondary:1.0] [--dry-run]
# ==============================================================================

# Re-exec under bash when invoked via zsh
if [[ -n "${ZSH_VERSION:-}" ]]; then
    case "${0:-}" in
        zsh|-zsh|*/zsh|*/-zsh) ;;
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
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/.." && pwd)"

# @RVDK_INLINE_LIBS: common
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:STORAGE]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_sanitize_locale() { export LANG=C LC_ALL=C; }
        rvdk_resolve_caller() { :; }
        rvdk_load_config_env() { :; }
        rvdk_normalize_mount_path() { local p="${1:-}"; [[ -n "$p" && "$p" != "/" ]] && p="${p%/}"; printf '%s\n' "$p"; }
    fi
fi

print_storage_help() {
    cat <<'EOF'
Usage:
  sudo rvdk storage [status] [--vg <vg_name>]
  sudo rvdk storage grow     --lv <lv_name> (--gb <N> | --mb <N> | --tb <N> | --pct-free <1..100>) [--dry-run]
  sudo rvdk storage shrink   --lv <lv_name> (--gb <N> | --mb <N> | --tb <N>) [--dry-run]
  sudo rvdk storage autotune [--weights <lv:w,...>] [--high-water <pct>] [--target-util <pct>]
                             [--min-reserve-pct <pct>] [--no-shrink] [--distribute-pool] [--dry-run]

Subcommands:
  status                  Display VG elastic reserve pool and live FS telemetry for all LVs
  grow                    Extend logical volume (--lv <name>) & grow XFS/Btrfs/ext4 online
  shrink                  Shrink mounted Btrfs LV (--lv <name>) online & return extents to VG pool
  autotune                Autobalance elastic VG extents across all mounted LVs in the VG:
                            • Grows any LV >= --high-water (default 75%) back to --target-util (60%)
                            • Applies priority weights (--weights lv1:1.5,lv2:1.0) when pool is scarce
                            • Reclaims idle Btrfs slack (<30% used) if another LV needs extents
                            • Preserves --min-reserve-pct (default 5%) unless critical (>=88% full)

Size & Tuning Options:
  --lv <lv_name>          Target Logical Volume name (required for 'grow' and 'shrink')
  --gb <N>                Size delta in GiB (supports decimals, e.g. --gb 100 or --gb 2.5)
  --mb <N>                Size delta in MiB (e.g. --mb 500)
  --tb <N>                Size delta in TiB (e.g. --tb 1)
  --pct-free <1..100>     Percentage of unallocated VG elastic pool extents ('grow' only)
  --vg <vg_name>          Explicit LVM Volume Group override (auto-detected by default)
  --weights <lv:w,...>    Comma-separated autotune weights (e.g. --weights lv_data:1.5,lv_secondary:1.0)
  --dry-run, -n           Compute and print exact LVM/FS resize plan without mutating disks
  --distribute-pool       (autotune) Proportionally distribute elastic pool even below high-water
EOF
}

log_plan() { printf "\033[1;35m[PLAN]\033[0m %s\n" "$1"; }

main() {
    rvdk_log_init "RVDK:STORAGE"

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
    rvdk_require_root "$script_self" "$@"
    rvdk_sanitize_locale
    rvdk_resolve_caller

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_fatal "'rvdk storage' live LVM operations require a Linux target node (detected $(uname -s))."
    fi

    if ! command -v vgs >/dev/null 2>&1 || ! command -v lvs >/dev/null 2>&1; then
        log_fatal "LVM2 utilities (vgs/lvs/lvextend) are not installed on this node."
    fi

    # Safely load optional config keys without sourcing untrusted shell code
    rvdk_load_config_env \
        VG_NAME LV_NAME MOUNT_POINT \
        SECONDARY_LV_NAME SECONDARY_MOUNT_POINT \
        NFS_LV_NAME NFS_MOUNT_POINT

    local vg_name="${VG_NAME:-}"
    local primary_lv="${LV_NAME:-lv_data}"
    local primary_mount="${MOUNT_POINT:-/mnt/nvme_data}"
    local secondary_lv="${SECONDARY_LV_NAME:-${NFS_LV_NAME:-lv_secondary}}"
    local secondary_mount="${SECONDARY_MOUNT_POINT:-${NFS_MOUNT_POINT:-/mnt/nvme_secondary}}"

    local subcmd="status"
    if [[ $# -gt 0 && "$1" != -* ]]; then
        subcmd="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
        shift
    fi

    local target_lv=""
    # Allow positional LV right after `grow <lv>` or `shrink <lv>`
    case "$subcmd" in
        grow|extend|add|shrink|reduce|reclaim)
            if [[ $# -gt 0 && "$1" != -* ]]; then
                target_lv="$1"
                shift
            fi
            ;;
    esac

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
    local weights_csv=""
    local cli_vg=""

    _require_arg() {
        [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != -* ]] || log_fatal "Option '${1:-}' requires an argument."
    }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            status|--status)
                subcmd="status"; shift ;;
            --lv|-l)
                _require_arg "$@"; target_lv="$2"; shift 2 ;;
            --lv=*)
                target_lv="${1#*=}"; shift ;;
            --gb)
                _require_arg "$@"; size_gb="$2"; shift 2 ;;
            --gb=*)
                size_gb="${1#*=}"; shift ;;
            --mb)
                _require_arg "$@"; size_mb="$2"; shift 2 ;;
            --mb=*)
                size_mb="${1#*=}"; shift ;;
            --tb)
                _require_arg "$@"; size_tb="$2"; shift 2 ;;
            --tb=*)
                size_tb="${1#*=}"; shift ;;
            --pct-free)
                _require_arg "$@"; pct_free="$2"; shift 2 ;;
            --pct-free=*)
                pct_free="${1#*=}"; shift ;;
            --vg)
                _require_arg "$@"; cli_vg="$2"; shift 2 ;;
            --vg=*)
                cli_vg="${1#*=}"; shift ;;
            --weights)
                _require_arg "$@"; weights_csv="$2"; shift 2 ;;
            --weights=*)
                weights_csv="${1#*=}"; shift ;;
            --mount|--mount-point)
                _require_arg "$@"; primary_mount="$2"; shift 2 ;;
            --nfs-mount|--secondary-mount)
                _require_arg "$@"; secondary_mount="$2"; shift 2 ;;
            --dry-run|-n)
                dry_run="true"; shift ;;
            --high-water)
                _require_arg "$@"; high_water="$2"; shift 2 ;;
            --target-util)
                _require_arg "$@"; target_util="$2"; shift 2 ;;
            --min-reserve-pct)
                _require_arg "$@"; min_reserve_pct="$2"; shift 2 ;;
            --no-shrink)
                allow_shrink="false"; shift ;;
            --distribute-pool)
                distribute_pool="true"; shift ;;
            *)
                log_fatal "Unknown option for 'rvdk storage ${subcmd}': $1 (run 'rvdk storage --help')" ;;
        esac
    done

    primary_mount="$(rvdk_normalize_mount_path "$primary_mount")"
    secondary_mount="$(rvdk_normalize_mount_path "$secondary_mount")"
    [[ -n "$cli_vg" ]] && vg_name="$cli_vg"

    # Auto-discover active Volume Group if unspecified or absent
    if [[ -z "$vg_name" ]] || ! vgs "$vg_name" >/dev/null 2>&1; then
        local detected_vg=""
        if vgs vg_rvdk >/dev/null 2>&1; then
            detected_vg="vg_rvdk"
        fi
        if [[ -z "$detected_vg" ]]; then
            local m_cand m_src
            for m_cand in "$primary_mount" "$secondary_mount" "/mnt/nfs_vault"; do
                [[ -n "$m_cand" ]] || continue
                m_src="$(findmnt -n -o SOURCE "$m_cand" 2>/dev/null || true)"
                if [[ -n "$m_src" ]]; then
                    detected_vg="$(lvs --noheadings -o vg_name "$m_src" 2>/dev/null | awk '{print $1; exit}' || true)"
                    [[ -n "$detected_vg" ]] && break
                fi
            done
        fi
        if [[ -z "$detected_vg" ]]; then
            detected_vg="$(lvs --noheadings -o vg_name,lv_name 2>/dev/null | awk -v p="$primary_lv" -v s="$secondary_lv" '$2==p || $2=="lv_data" || $2==s || $2=="lv_secondary" || $2=="lv_nfsvault" {print $1; exit}' || true)"
        fi
        if [[ -z "$detected_vg" ]]; then
            local vg_cnt
            vg_cnt="$(vgs --noheadings -o vg_name 2>/dev/null | wc -l | awk '{print $1}')"
            if [[ "$vg_cnt" == "1" ]]; then
                detected_vg="$(vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1; exit}')"
            fi
        fi
        [[ -n "$detected_vg" ]] && vg_name="$detected_vg"
    fi

    if [[ -z "$vg_name" ]] || ! vgs "$vg_name" >/dev/null 2>&1; then
        log_fatal "Could not locate an active LVM Volume Group (checked '${vg_name:-auto}'). Pass --vg <vg_name> or provision NVMe via 'sudo rvdk mods/nvme-4kn'."
    fi

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

    local vg_raw vg_size_b vg_free_b vg_pe_b vg_ext_total vg_ext_free
    read_vg_metrics() {
        vg_raw="$(vgs --units b --nosuffix --noheadings -o vg_size,vg_free,vg_extent_size,vg_extent_count,vg_free_count "$vg_name" 2>/dev/null | awk '{print $1,$2,$3,$4,$5; exit}')"
        read -r vg_size_b vg_free_b vg_pe_b vg_ext_total vg_ext_free <<< "$vg_raw"
    }

    # Enumerate all logical volumes inside $vg_name
    list_vg_lvs() {
        lvs --noheadings -o lv_name "$vg_name" 2>/dev/null | awk '{$1=$1; if ($1 != "") print $1}'
    }

    # Resolve priority weight for an LV during autotune
    lv_weight_for() {
        local lv_n="$1"
        if [[ -n "$weights_csv" ]]; then
            local pair k v
            local -a _pairs=()
            IFS=',' read -r -a _pairs <<< "$weights_csv"
            for pair in "${_pairs[@]+"${_pairs[@]}"}"; do
                k="${pair%%:*}"
                v="${pair#*:}"
                if [[ "$k" == "$lv_n" ]]; then
                    if [[ ! "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                        log_fatal "Invalid numeric weight '${v}' for LV '${k}' in --weights."
                    fi
                    echo "$v"
                    return 0
                fi
            done
        fi
        case "$lv_n" in
            lv_data|"$primary_lv") echo "1.5" ;;
            *)                     echo "1.0" ;;
        esac
    }

    # Read live LV + mounted filesystem metrics (with DM hyphen escaping):
    # Sets globals: LV_EXISTS LV_PATH LV_SIZE_B LV_EXT LV_MNT LV_FSTYPE FS_SIZE_B FS_USED_B FS_AVAIL_B FS_UTIL_PCT
    probe_lv() {
        local lv_n="$1"
        local fallback_mnt="${2:-}"
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
            lv_info="$(lvs --units b --nosuffix --noheadings -o lv_size "${vg_name}/${lv_n}" 2>/dev/null | awk '{print $1; exit}')"
            LV_SIZE_B="${lv_info:-0}"
            LV_EXT=$(( LV_SIZE_B / vg_pe_b ))

            local vg_dm="${vg_name//-/--}"
            local lv_dm="${lv_n//-/--}"
            local dm_path="/dev/mapper/${vg_dm}-${lv_dm}"

            LV_MNT="$(findmnt -rn -S "$LV_PATH" -o TARGET 2>/dev/null | head -n1 || true)"
            if [[ -z "$LV_MNT" && -e "$dm_path" ]]; then
                LV_MNT="$(findmnt -rn -S "$dm_path" -o TARGET 2>/dev/null | head -n1 || true)"
            fi
            if [[ -z "$LV_MNT" && -n "$fallback_mnt" ]] && mountpoint -q "$fallback_mnt" 2>/dev/null; then
                local fb_src
                fb_src="$(findmnt -rn -M "$fallback_mnt" -o SOURCE 2>/dev/null | head -n1 || true)"
                if [[ "$fb_src" == "$LV_PATH" || "$fb_src" == "$dm_path" ]]; then
                    LV_MNT="$fallback_mnt"
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

        log_info "Volume Group '${vg_name}' Elastic Layout"
        printf "  • Total VG Capacity  : %s (%d extents @ %s)\n" \
            "$(human_bytes "$vg_size_b")" "$vg_ext_total" "$(human_bytes "$vg_pe_b")"
        printf "  • Elastic VG Reserve : %s free (%d%% unallocated | %d extents)\n" \
            "$(human_bytes "$vg_free_b")" "$reserve_pct" "$vg_ext_free"

        local lv_item any_lv="false"
        while IFS= read -r lv_item; do
            [[ -n "$lv_item" ]] || continue
            any_lv="true"
            probe_lv "$lv_item" ""
            if [[ -n "$LV_MNT" ]]; then
                printf "  • LV %-15s : %s [%s @ %s] — Used: %s / %s (%d%% | Avail: %s)\n" \
                    "$lv_item" "$(human_bytes "$LV_SIZE_B")" "$LV_FSTYPE" "$LV_MNT" \
                    "$(human_bytes "$FS_USED_B")" "$(human_bytes "$FS_SIZE_B")" "$FS_UTIL_PCT" "$(human_bytes "$FS_AVAIL_B")"
            else
                printf "  • LV %-15s : %s [unmounted]\n" "$lv_item" "$(human_bytes "$LV_SIZE_B")"
            fi
        done < <(list_vg_lvs)

        if [[ "$any_lv" == "false" ]]; then
            printf "  • Logical Volumes    : (none provisioned in %s)\n" "$vg_name"
        fi
    }

    extend_lv_online() {
        local lv_n="$1"
        local fallback_mnt="$2"
        local add_ext="$3"

        [[ -z "$lv_n" ]] && log_fatal "Missing --lv <lv_name> for online LV growth."

        read_vg_metrics
        probe_lv "$lv_n" "$fallback_mnt"
        [[ "$LV_EXISTS" != "true" ]] && log_fatal "Logical volume '${vg_name}/${lv_n}' does not exist."
        [[ -z "$LV_MNT" ]] && log_fatal "Logical volume '${LV_PATH}' is not mounted; mount it before online resize."

        if (( vg_ext_free <= 0 )); then
            log_fatal "Elastic VG reserve in '${vg_name}' has 0 free extents ($(human_bytes "$vg_free_b")). If a Btrfs LV has idle space, reclaim extents via 'sudo rvdk storage shrink --lv <btrfs_lv> --gb <N>'."
        fi

        if (( add_ext == vg_ext_free + 1 )); then
            add_ext="$vg_ext_free"
        elif (( add_ext > vg_ext_free )); then
            log_fatal "Requested +$(human_bytes $(( add_ext * vg_pe_b ))) (${add_ext} extents) exceeds '${vg_name}' free elastic reserve of $(human_bytes "$vg_free_b") (${vg_ext_free} extents)."
        fi

        local add_bytes=$(( add_ext * vg_pe_b ))
        local new_bytes=$(( LV_SIZE_B + add_bytes ))

        if [[ "$dry_run" == "true" ]]; then
            log_plan "[DRY-RUN] Grow ${vg_name}/${lv_n} (@ ${LV_MNT}, ${LV_FSTYPE}): $(human_bytes "$LV_SIZE_B") -> $(human_bytes "$new_bytes") (+$(human_bytes "$add_bytes") / +${add_ext} extents)"
            return 0
        fi

        log_info "Extending ${LV_PATH} (@ ${LV_MNT}) by +$(human_bytes "$add_bytes") (+${add_ext} extents)..."
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

        log_ok "${vg_name}/${lv_n} (${LV_MNT}) grown online -> $(human_bytes "$new_bytes")"
    }

    shrink_btrfs_lv_online() {
        local lv_n="$1"
        local fallback_mnt="$2"
        local sub_ext="$3"

        [[ -z "$lv_n" ]] && log_fatal "Missing --lv <lv_name> for online Btrfs shrink."

        read_vg_metrics
        probe_lv "$lv_n" "$fallback_mnt"
        [[ "$LV_EXISTS" != "true" ]] && log_fatal "Logical volume '${vg_name}/${lv_n}' does not exist."
        [[ -z "$LV_MNT" ]] && log_fatal "Logical volume '${LV_PATH}' must be mounted for online Btrfs shrink."
        if [[ "$LV_FSTYPE" != "btrfs" ]]; then
            log_fatal "Online live shrink requires Btrfs ('${LV_MNT}' is formatted as '${LV_FSTYPE}'). XFS/ext4 cannot shrink online."
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
            log_plan "[DRY-RUN] Shrink ${vg_name}/${lv_n} (@ ${LV_MNT}, btrfs): $(human_bytes "$LV_SIZE_B") -> $(human_bytes "$new_lv_b") (-$(human_bytes "$sub_bytes") / -${sub_ext} extents returned to ${vg_name})"
            return 0
        fi

        local fs_pre_target=$(( new_lv_b - cushion_b ))
        log_info "Shrinking Btrfs filesystem on ${LV_MNT} & returning $(human_bytes "$sub_bytes") (${sub_ext} extents) to '${vg_name}'..."
        btrfs filesystem resize "$fs_pre_target" "$LV_MNT" >/dev/null
        if ! lvreduce -f -y -l "$new_lv_ext" "$LV_PATH" >/dev/null; then
            log_warn "lvreduce failed on ${LV_PATH}; rolling Btrfs filesystem on ${LV_MNT} back to max LV size..."
            btrfs filesystem resize max "$LV_MNT" >/dev/null 2>&1 || true
            log_fatal "Online LV shrink aborted safely; filesystem restored to full LV extent."
        fi
        btrfs filesystem resize max "$LV_MNT" >/dev/null
        log_ok "Shrank ${LV_MNT} online -> $(human_bytes "$new_lv_b") (+$(human_bytes "$sub_bytes") returned to '${vg_name}' elastic pool)"
    }

    resolve_primary_lv() {
        if lvs "${vg_name}/${primary_lv}" >/dev/null 2>&1; then
            echo "$primary_lv"
        elif lvs "${vg_name}/lv_data" >/dev/null 2>&1; then
            echo "lv_data"
        else
            echo "$primary_lv"
        fi
    }

    resolve_secondary_lv() {
        if lvs "${vg_name}/${secondary_lv}" >/dev/null 2>&1; then
            echo "$secondary_lv"
        elif lvs "${vg_name}/lv_nfsvault" >/dev/null 2>&1; then
            echo "lv_nfsvault"
        elif lvs "${vg_name}/lv_secondary" >/dev/null 2>&1; then
            echo "lv_secondary"
        else
            echo "$secondary_lv"
        fi
    }

    run_autotune() {
        if [[ ! "$high_water" =~ ^[0-9]+$ || ! "$target_util" =~ ^[0-9]+$ || ! "$min_reserve_pct" =~ ^[0-9]+$ ]]; then
            log_fatal "--high-water, --target-util, and --min-reserve-pct must be integers."
        fi
        if (( target_util < 20 || target_util >= high_water || high_water > 95 )); then
            log_fatal "Require 20 <= --target-util (${target_util}) < --high-water (${high_water}) <= 95."
        fi

        read_vg_metrics
        log_info "Evaluating live storage telemetry on '${vg_name}' (high-water=${high_water}%, target=${target_util}%, min-reserve=${min_reserve_pct}%)..."

        local lvs_names=() lvs_mnt=() lvs_fs=() lvs_size_b=() lvs_used_b=() lvs_util=() lvs_weight=() lvs_want_ext=()
        local lv_item idx=0
        while IFS= read -r lv_item; do
            [[ -n "$lv_item" ]] || continue
            probe_lv "$lv_item" ""
            [[ -n "$LV_MNT" ]] || continue
            lvs_names+=("$lv_item")
            lvs_mnt+=("$LV_MNT")
            lvs_fs+=("$LV_FSTYPE")
            lvs_size_b+=("$LV_SIZE_B")
            lvs_used_b+=("$FS_USED_B")
            lvs_util+=("$FS_UTIL_PCT")
            lvs_weight+=("$(lv_weight_for "$lv_item")")
            lvs_want_ext+=(0)
            idx=$(( idx + 1 ))
        done < <(list_vg_lvs)

        local m_cnt="${#lvs_names[@]}"
        if (( m_cnt == 0 )); then
            log_skip "No mounted logical volumes found in '${vg_name}'."
            print_status_report
            return 0
        fi

        local min_add_b=1073741824 # 1 GiB minimum meaningful step
        local total_want_ext=0
        local critical="false"
        local i

        for (( i = 0; i < m_cnt; i++ )); do
            if (( lvs_util[i] >= high_water )); then
                (( lvs_util[i] >= 88 )) && critical="true"
                local t_b=$(( (lvs_used_b[i] * 100) / target_util ))
                local d_b=$(( t_b - lvs_size_b[i] ))
                (( d_b < min_add_b )) && d_b="$min_add_b"
                local w_ext=$(( (d_b + vg_pe_b - 1) / vg_pe_b ))
                lvs_want_ext[i]="$w_ext"
                total_want_ext=$(( total_want_ext + w_ext ))
            fi
        done

        local min_res_ext=$(( (vg_ext_total * min_reserve_pct) / 100 ))
        [[ "$critical" == "true" ]] && min_res_ext=0

        local alloc_ext=$(( vg_ext_free - min_res_ext ))
        (( alloc_ext < 0 )) && alloc_ext=0

        # Optional --distribute-pool: proportionally allocate elastic reserve by effective_used * weight
        if (( total_want_ext == 0 )) && [[ "$distribute_pool" == "true" ]]; then
            if (( alloc_ext <= 0 )); then
                log_skip "No allocatable extents above ${min_reserve_pct}% minimum VG reserve (${vg_ext_free} extents free)."
                print_status_report
                return 0
            fi
            local score_args=""
            for (( i = 0; i < m_cnt; i++ )); do
                local eff_u="${lvs_used_b[i]}"
                (( eff_u < 1073741824 )) && eff_u=1073741824
                score_args="${score_args} ${eff_u}:${lvs_weight[i]}"
            done
            local dist_out
            dist_out="$(awk -v alloc="$alloc_ext" -v specs="$score_args" 'BEGIN {
                n = split(specs, arr, " ");
                sum = 0;
                for (i = 1; i <= n; i++) {
                    split(arr[i], kv, ":");
                    s[i] = (kv[1] + 0) * (kv[2] + 0);
                    sum += s[i];
                }
                rem = alloc;
                for (i = 1; i <= n; i++) {
                    if (i == n) { g = rem; }
                    else { g = int(alloc * (s[i] / sum) + 0.5); if (g > rem) g = rem; }
                    rem -= g;
                    printf "%d%s", g, (i == n ? "\n" : " ");
                }
            }')"
            local dist_arr=()
            read -r -a dist_arr <<< "$dist_out"
            total_want_ext=0
            for (( i = 0; i < m_cnt; i++ )); do
                lvs_want_ext[i]="${dist_arr[i]:-0}"
                total_want_ext=$(( total_want_ext + lvs_want_ext[i] ))
            done
        fi

        # Donor reclaim from idle Btrfs LVs (<low_water%) if wanted extents exceed VG reserve
        if (( total_want_ext > alloc_ext )) && [[ "$allow_shrink" == "true" ]]; then
            local eight_gib=$(( 8 * 1073741824 ))
            for (( i = 0; i < m_cnt; i++ )); do
                (( total_want_ext <= alloc_ext )) && break
                if (( lvs_want_ext[i] == 0 )) && [[ "${lvs_fs[i]}" == "btrfs" ]] && (( lvs_util[i] < low_water )); then
                    local shortfall_ext=$(( total_want_ext - alloc_ext ))
                    local keep_b=$(( lvs_used_b[i] * 2 + 2 * 1073741824 ))
                    (( keep_b < eight_gib )) && keep_b="$eight_gib"
                    if (( lvs_size_b[i] > keep_b + min_add_b )); then
                        local max_donor_ext=$(( (lvs_size_b[i] - keep_b) / vg_pe_b ))
                        if (( max_donor_ext > 0 )); then
                            local reclaim_ext=$(( shortfall_ext < max_donor_ext ? shortfall_ext : max_donor_ext ))
                            log_info "Autotune Donor Reclaim: '${lvs_names[i]}' is ${lvs_util[i]}% used (<${low_water}%); reclaiming ${reclaim_ext} extents ($(human_bytes $(( reclaim_ext * vg_pe_b ))))."
                            shrink_btrfs_lv_online "${lvs_names[i]}" "${lvs_mnt[i]}" "$reclaim_ext"
                            if [[ "$dry_run" == "true" ]]; then
                                alloc_ext=$(( alloc_ext + reclaim_ext ))
                            else
                                read_vg_metrics
                                alloc_ext=$(( vg_ext_free - min_res_ext ))
                                (( alloc_ext < 0 )) && alloc_ext=0
                            fi
                        fi
                    fi
                fi
            done
        fi

        if (( total_want_ext == 0 )); then
            local summary_parts=()
            for (( i = 0; i < m_cnt; i++ )); do
                summary_parts+=("${lvs_names[i]}: ${lvs_util[i]}%")
            done
            local summary_str
            summary_str="$(IFS=', '; echo "${summary_parts[*]}")"
            log_ok "All mounted volumes healthy below ${high_water}% high-water mark (${summary_str})."
            log_skip "Preserving $(human_bytes "$vg_free_b") elastic VG reserve so grow-only filesystems never lock in unneeded extents (pass --distribute-pool or --high-water <pct> to allocate early)."
            print_status_report
            return 0
        fi

        if (( alloc_ext <= 0 )); then
            log_warn "Volumes exceeded ${high_water}% high-water mark, but '${vg_name}' has 0 allocatable extents remaining ($(human_bytes "$vg_free_b") free)."
            print_status_report
            return 0
        fi

        local grants=()
        if (( total_want_ext <= alloc_ext )); then
            for (( i = 0; i < m_cnt; i++ )); do
                grants+=("${lvs_want_ext[i]}")
            done
        else
            local w_specs=""
            for (( i = 0; i < m_cnt; i++ )); do
                w_specs="${w_specs} ${lvs_want_ext[i]}:${lvs_weight[i]}"
            done
            local grant_out
            grant_out="$(awk -v alloc="$alloc_ext" -v specs="$w_specs" 'BEGIN {
                n = split(specs, arr, " ");
                sum = 0;
                last_hungry = 0;
                for (i = 1; i <= n; i++) {
                    split(arr[i], kv, ":");
                    want[i] = kv[1] + 0;
                    s[i] = want[i] * (kv[2] + 0);
                    sum += s[i];
                    if (want[i] > 0) last_hungry = i;
                }
                rem = alloc;
                for (i = 1; i <= n; i++) {
                    if (want[i] <= 0) { g = 0; }
                    else if (i == last_hungry) {
                        g = rem;
                        if (g > want[i]) g = want[i];
                    }
                    else {
                        g = int(alloc * (s[i] / sum) + 0.5);
                        if (g > want[i]) g = want[i];
                        if (g > rem) g = rem;
                    }
                    rem -= g;
                    printf "%d%s", g, (i == n ? "\n" : " ");
                }
            }')"
            read -r -a grants <<< "$grant_out"
        fi

        for (( i = 0; i < m_cnt; i++ )); do
            if (( ${grants[i]:-0} > 0 )); then
                extend_lv_online "${lvs_names[i]}" "${lvs_mnt[i]}" "${grants[i]}"
            fi
        done

        print_status_report
    }

    case "$subcmd" in
        status|list|info|show)
            print_status_report
            ;;
        grow|extend|add)
            [[ -z "$target_lv" ]] && log_fatal "Missing --lv <lv_name>. Usage: sudo rvdk storage grow --lv <lv_name> --gb <N>"
            read_vg_metrics
            local req_ext
            req_ext="$(parse_requested_extents "$vg_pe_b" "$vg_ext_free")"
            extend_lv_online "$target_lv" "" "$req_ext"
            print_status_report
            ;;
        shrink|reduce|reclaim)
            [[ -z "$target_lv" ]] && log_fatal "Missing --lv <lv_name>. Usage: sudo rvdk storage shrink --lv <lv_name> --gb <N>"
            [[ -n "$pct_free" ]] && log_fatal "--pct-free is only valid when growing from free VG extents (use --gb, --mb, or --tb for shrink)."
            read_vg_metrics
            local req_ext
            req_ext="$(parse_requested_extents "$vg_pe_b" "$vg_ext_free")"
            shrink_btrfs_lv_online "$target_lv" "" "$req_ext"
            print_status_report
            ;;
        grow-primary|extend-primary|add-primary)
            local resolved_pri_lv
            resolved_pri_lv="$(resolve_primary_lv)"
            log_warn "'${subcmd}' is deprecated; prefer 'sudo rvdk storage grow --lv ${resolved_pri_lv}'."
            read_vg_metrics
            local req_ext
            req_ext="$(parse_requested_extents "$vg_pe_b" "$vg_ext_free")"
            extend_lv_online "$resolved_pri_lv" "$primary_mount" "$req_ext"
            print_status_report
            ;;
        grow-nfs|extend-nfs|add-nfs|grow-secondary)
            local resolved_sec_lv
            resolved_sec_lv="$(resolve_secondary_lv)"
            log_warn "'${subcmd}' is deprecated; prefer 'sudo rvdk storage grow --lv ${resolved_sec_lv}'."
            read_vg_metrics
            local req_ext
            req_ext="$(parse_requested_extents "$vg_pe_b" "$vg_ext_free")"
            extend_lv_online "$resolved_sec_lv" "$secondary_mount" "$req_ext"
            print_status_report
            ;;
        shrink-nfs|reduce-nfs|reclaim-nfs|shrink-secondary)
            local resolved_sec_lv
            resolved_sec_lv="$(resolve_secondary_lv)"
            log_warn "'${subcmd}' is deprecated; prefer 'sudo rvdk storage shrink --lv ${resolved_sec_lv}'."
            [[ -n "$pct_free" ]] && log_fatal "--pct-free is only valid when growing from free VG extents (use --gb or --mb for shrink)."
            read_vg_metrics
            local req_ext
            req_ext="$(parse_requested_extents "$vg_pe_b" "$vg_ext_free")"
            shrink_btrfs_lv_online "$resolved_sec_lv" "$secondary_mount" "$req_ext"
            print_status_report
            ;;
        autotune|auto-tune|balance|autobalance)
            run_autotune
            ;;
        *)
            log_fatal "Unknown storage subcommand '${subcmd}' (expected: status | grow | shrink | autotune)."
            ;;
    esac
}

main "$@"
