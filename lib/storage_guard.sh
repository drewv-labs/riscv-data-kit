#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Block Storage Non-Destructive Safety Interlocks
# Path: riscv-data-kit/lib/storage_guard.sh
#
# Protects root/boot/swap/system filesystems unconditionally, enforces strict
# cross-disk LVM/filesystem confinement, and refuses to format or wipe
# pre-existing user filesystems, LVM PVs, RAID members, or LUKS containers
# unless an explicit --force-wipe flag is passed by the operator.
# ==============================================================================

[[ -n "${_RVDK_STORAGE_GUARD_SH_LOADED:-}" ]] && return 0
_RVDK_STORAGE_GUARD_SH_LOADED=1

# Recursively resolve a kernel block name (`dm-0`, `nvme0n1p1`, `nvme0n1`) to its
# leaf whole-disk kernel names via `/sys/class/block/<kname>/slaves` and `lsblk`.
_rvdk_collect_leaf_disks() {
    local kname="$1"
    [[ -n "$kname" ]] || return 0

    local slave_dir="/sys/class/block/${kname}/slaves"
    if [[ -d "$slave_dir" ]] && compgen -G "${slave_dir}/*" >/dev/null 2>&1; then
        local s
        for s in "${slave_dir}"/*; do
            [[ -e "$s" ]] || continue
            _rvdk_collect_leaf_disks "$(basename "$s")"
        done
        return 0
    fi

    local pk=""
    if command -v lsblk >/dev/null 2>&1 && [[ -b "/dev/${kname}" ]]; then
        pk="$(lsblk -ndo PKNAME "/dev/${kname}" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
    fi
    if [[ -z "$pk" && -L "/sys/class/block/${kname}" ]]; then
        local sys_real parent_base
        sys_real="$(readlink -f "/sys/class/block/${kname}" 2>/dev/null || true)"
        parent_base="$(basename "$(dirname "$sys_real")")"
        if [[ -n "$parent_base" && "$parent_base" != "block" && -e "/sys/block/${parent_base}" ]]; then
            pk="$parent_base"
        fi
    fi

    if [[ -n "$pk" && "$pk" != "$kname" ]]; then
        _rvdk_collect_leaf_disks "$pk"
    else
        printf '%s\n' "$kname"
    fi
}

# Returns 0 only if <dev_path> (whole disk, partition, or dm/LVM LV) resides
# exclusively on <target_disk>. Fails closed (returns 1) on cross-disk or unknown topology.
rvdk_block_resides_on_disk() {
    local dev_path="${1:-}"
    local target_disk="${2:-}"
    [[ -n "$dev_path" && -n "$target_disk" ]] || return 1

    local dev_real target_real dev_kname target_kname
    dev_real="$(readlink -f "$dev_path" 2>/dev/null || echo "$dev_path")"
    target_real="$(readlink -f "$target_disk" 2>/dev/null || echo "$target_disk")"
    dev_kname="$(basename "$dev_real")"
    target_kname="$(basename "$target_real")"

    [[ -n "$dev_kname" && -n "$target_kname" ]] || return 1
    if [[ "$dev_real" == "$target_real" || "$dev_kname" == "$target_kname" ]]; then
        return 0
    fi

    local found_any="false" leaf
    while IFS= read -r leaf; do
        [[ -n "$leaf" ]] || continue
        found_any="true"
        if [[ "$leaf" != "$target_kname" ]]; then
            return 1
        fi
    done < <(_rvdk_collect_leaf_disks "$dev_kname")

    [[ "$found_any" == "true" ]]
}

# Returns 0 only if every Physical Volume backing <vg_name> resides exclusively
# on <target_disk>. Fails closed if any PV is missing/unknown or on another disk.
rvdk_vg_exclusively_on_disk() {
    local vg_name="${1:-}"
    local target_disk="${2:-}"
    [[ -n "$vg_name" && -n "$target_disk" ]] || return 1
    command -v pvs >/dev/null 2>&1 || return 1

    local found_pv="false" raw_pv pv
    while IFS= read -r raw_pv; do
        pv="${raw_pv#"${raw_pv%%[![:space:]]*}"}"
        pv="${pv%"${pv##*[![:space:]]}"}"
        [[ -n "$pv" ]] || continue
        found_pv="true"
        if [[ "$pv" == *"[unknown]"* || ! -b "$pv" ]]; then
            return 1
        fi
        if ! rvdk_block_resides_on_disk "$pv" "$target_disk"; then
            return 1
        fi
    done < <(pvs --noheadings -o pv_name -S "vg_name=${vg_name}" 2>/dev/null || true)

    [[ "$found_pv" == "true" ]]
}

# Returns 0 if any partition/LV on <dev> backs a critical OS mountpoint or active swap
rvdk_device_backs_os_or_swap() {
    local dev="$1"
    local mnt
    while IFS= read -r mnt; do
        [[ -z "$mnt" ]] && continue
        case "$mnt" in
            /|/boot|/boot/*|/usr|/var|/var/log|/home|"[SWAP]")
                return 0
                ;;
        esac
    done < <(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null || true)

    # Cross-check /proc/swaps against child block nodes
    if [[ -r /proc/swaps ]]; then
        local kname
        while IFS= read -r kname; do
            [[ -z "$kname" ]] && continue
            if awk -v d="/dev/${kname}" 'NR>1 && $1 == d {found=1} END {exit !found}' /proc/swaps 2>/dev/null; then
                return 0
            fi
        done < <(lsblk -nr -o KNAME "$dev" 2>/dev/null || true)
    fi

    return 1
}

# Assert that <dev> is safe to wipe/format.
# Usage: rvdk_assert_device_safe_to_wipe <dev> <force_wipe_bool> [allowed_label_csv]
rvdk_assert_device_safe_to_wipe() {
    local dev="$1"
    local force_wipe="${2:-false}"
    local allowed_labels=",${3:-},"

    [[ -b "$dev" ]] || log_fatal "Block device not found: ${dev}"

    # Hard Interlock 1: NEVER wipe OS root/boot/usr/var/home/swap even with --force-wipe
    if rvdk_device_backs_os_or_swap "$dev"; then
        log_fatal "Safety Interlock: ${dev} backs a critical OS filesystem or active SWAP! Refusing to touch ${dev}."
    fi

    if [[ "$force_wipe" == "true" ]]; then
        return 0
    fi

    # Hard Interlock 2 (when force_wipe == false): Refuse if any non-target mountpoint is active
    local active_mnts=()
    local m
    while IFS= read -r m; do
        [[ -n "$m" ]] && active_mnts+=("$m")
    done < <(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null || true)
    if [[ ${#active_mnts[@]} -gt 0 ]]; then
        log_fatal "Safety Interlock: ${dev} has mounted filesystem(s) (${active_mnts[*]}). Unmount and pass --force-wipe if you intend to destroy existing data."
    fi

    # Hard Interlock 3 (when force_wipe == false): Refuse if existing non-RVDK filesystem, LVM PV, RAID, ZFS, or LUKS exists
    local line fstype label
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        fstype="$(awk '{print $1}' <<< "$line")"
        label="$(awk '{print $2}' <<< "$line")"
        [[ -z "$fstype" || "$fstype" == "-" ]] && continue
        if [[ -n "$label" && "$allowed_labels" == *",${label},"* ]]; then
            continue
        fi
        log_fatal "Safety Interlock: ${dev} already contains '${fstype}' signature${label:+ (label=${label})}. Pass --force-wipe to overwrite."
    done < <(lsblk -nr -o FSTYPE,LABEL "$dev" 2>/dev/null | awk '{print ($1==""?"-":$1), $2}' || true)

    local blkid_type blkid_lbl
    blkid_type="$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)"
    blkid_lbl="$(blkid -s LABEL -o value "$dev" 2>/dev/null || true)"
    if [[ -n "$blkid_type" ]] && ! [[ -n "$blkid_lbl" && "$allowed_labels" == *",${blkid_lbl},"* ]]; then
        log_fatal "Safety Interlock: ${dev} contains existing '${blkid_type}' superblock${blkid_lbl:+ (label=${blkid_lbl})}. Pass --force-wipe to overwrite."
    fi
}

# Returns 0 only if a whole disk is genuinely blank/unused (no mounts, swap, partitions, holders, or FS magic)
rvdk_disk_is_blank() {
    local dev="$1"
    [[ -b "$dev" ]] || return 1
    rvdk_device_backs_os_or_swap "$dev" && return 1

    local m
    m="$(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$m" ]] && return 1

    # Reject if child partitions or dm/md holders exist
    local line_cnt
    line_cnt="$(lsblk -nr -o NAME "$dev" 2>/dev/null | wc -l | tr -dc '0-9')"
    (( ${line_cnt:-0} > 1 )) && return 1

    local kname
    kname="$(basename "$(readlink -f "$dev" 2>/dev/null || echo "$dev")")"
    if [[ -d "/sys/block/${kname}/holders" ]] && compgen -G "/sys/block/${kname}/holders/*" >/dev/null 2>&1; then
        return 1
    fi

    # Reject if any filesystem / LVM / RAID / LUKS / partition table magic is present
    if [[ -n "$(blkid -p "$dev" 2>/dev/null || true)" ]]; then
        return 1
    fi
    return 0
}
