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
    local kname="${1:-}"
    local depth="${2:-0}"
    local visited="${3:-|}"
    [[ -n "$kname" ]] || return 0
    (( depth < 32 )) || return 0
    [[ "$visited" == *"|${kname}|"* ]] && return 0
    visited="${visited}${kname}|"

    local slave_dir="/sys/class/block/${kname}/slaves"
    if [[ -d "$slave_dir" ]] && compgen -G "${slave_dir}/*" >/dev/null 2>&1; then
        local s s_base
        for s in "${slave_dir}"/*; do
            [[ -e "$s" ]] || continue
            s_base="$(basename "$s")"
            [[ -n "$s_base" ]] && _rvdk_collect_leaf_disks "$s_base" "$(( depth + 1 ))" "$visited"
        done
        return 0
    fi

    local pk_out="" pk="" found_pk="false"
    if command -v lsblk >/dev/null 2>&1 && [[ -b "/dev/${kname}" ]]; then
        pk_out="$(lsblk -ndo PKNAME "/dev/${kname}" 2>/dev/null || true)"
        while IFS= read -r pk; do
            pk="${pk#"${pk%%[![:space:]]*}"}"
            pk="${pk%"${pk##*[![:space:]]}"}"
            [[ -n "$pk" && "$pk" != "$kname" ]] || continue
            found_pk="true"
            _rvdk_collect_leaf_disks "$pk" "$(( depth + 1 ))" "$visited"
        done <<< "$pk_out"
    fi
    if [[ "$found_pk" == "true" ]]; then
        return 0
    fi

    if [[ -L "/sys/class/block/${kname}" ]]; then
        local sys_real parent_base
        sys_real="$(readlink -f "/sys/class/block/${kname}" 2>/dev/null || true)"
        parent_base="$(basename "$(dirname "$sys_real")")"
        if [[ -n "$parent_base" && "$parent_base" != "block" && -e "/sys/block/${parent_base}" && "$parent_base" != "$kname" ]]; then
            _rvdk_collect_leaf_disks "$parent_base" "$(( depth + 1 ))" "$visited"
            return 0
        fi
    fi

    printf '%s\n' "$kname"
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

# Query mountpoints for <dev> and all descendants, supporting both `MOUNTPOINTS`
# (util-linux >= 2.38, multi-mount per node) and legacy `MOUNTPOINT`.
# Splits multi-line and literal `\n` / `\x0a` separators into one path per line.
_rvdk_lsblk_mountpoints() {
    local dev="${1:-}"
    [[ -n "$dev" ]] || return 0

    local out=""
    if ! out="$(lsblk -nr -o MOUNTPOINTS "$dev" 2>/dev/null)"; then
        out="$(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null || true)"
    fi
    [[ -n "$out" ]] || return 0

    awk '{
        gsub(/\\x0[aA]/, "\n")
        gsub(/\\n/, "\n")
        n = split($0, parts, "\n")
        for (i = 1; i <= n; i++) {
            if (parts[i] != "") print parts[i]
        }
    }' <<< "$out"
}

# Parse one `lsblk -P -o PATH,TYPE,FSTYPE,LABEL` line safely without `eval`.
# Sets: _RVDK_SG_PATH, _RVDK_SG_TYPE, _RVDK_SG_FSTYPE, _RVDK_SG_LABEL
_rvdk_storage_parse_lsblk_line() {
    local rest="${1:-}"
    _RVDK_SG_PATH=""
    _RVDK_SG_TYPE=""
    _RVDK_SG_FSTYPE=""
    _RVDK_SG_LABEL=""

    local pair_re='^([A-Za-z_][A-Za-z0-9_]*)="(([^"\\]|\\.)*)"[[:space:]]*(.*)$'
    while [[ -n "$rest" ]]; do
        rest="${rest#"${rest%%[![:space:]]*}"}"
        [[ -z "$rest" ]] && break
        if [[ "$rest" =~ $pair_re ]]; then
            local k="${BASH_REMATCH[1]}"
            local v="${BASH_REMATCH[2]}"
            rest="${BASH_REMATCH[4]}"
            case "$k" in
                PATH)   _RVDK_SG_PATH="$v" ;;
                TYPE)   _RVDK_SG_TYPE="$v" ;;
                FSTYPE) _RVDK_SG_FSTYPE="$v" ;;
                LABEL)  _RVDK_SG_LABEL="$v" ;;
            esac
        else
            break
        fi
    done
}

# Returns 0 if <mnt> matches a critical OS/swap mountpoint.
_rvdk_is_critical_mountpoint() {
    local mnt="${1:-}"
    [[ -n "$mnt" ]] || return 1
    while [[ "$mnt" != "/" && "$mnt" == */ ]]; do
        mnt="${mnt%/}"
    done
    case "$mnt" in
        /|/boot|/boot/*|/usr|/var|/var/log|/var/lib|/home|/etc|/opt|/root|/srv|"[SWAP]")
            return 0
            ;;
    esac
    return 1
}

# Recursively resolve a mount/swap source device <src> via `lsblk -no PKNAME`
# (and sysfs slaves for multi-disk mdraid/LVM on Linux) to check whether it
# resides on <target_dev>, bounded by cycle and depth guards.
_rvdk_source_backs_disk() {
    local src="${1:-}"
    local target_dev="${2:-}"
    local depth="${3:-0}"
    local visited="${4:- }"

    [[ -n "$src" && -n "$target_dev" ]] || return 1
    (( depth < 16 )) || return 1

    local src_real target_real src_kname src_orig_kname target_kname target_orig_kname
    src_real="$(readlink -f "$src" 2>/dev/null || echo "$src")"
    target_real="$(readlink -f "$target_dev" 2>/dev/null || echo "$target_dev")"
    src_kname="${src_real##*/}"
    src_orig_kname="${src##*/}"
    target_kname="${target_real##*/}"
    target_orig_kname="${target_dev##*/}"

    if [[ "$src" == "$target_dev" || "$src_real" == "$target_real" \
          || ( -n "$src_kname" && "$src_kname" == "$target_kname" ) \
          || ( -n "$src_orig_kname" && "$src_orig_kname" == "$target_orig_kname" ) ]]; then
        return 0
    fi

    local visit_key="${src_kname:-$src}"
    [[ "$visited" == *" ${visit_key} "* ]] && return 1
    visited="${visited}${visit_key} "
    if [[ -n "$src_orig_kname" && "$src_orig_kname" != "$visit_key" ]]; then
        visited="${visited}${src_orig_kname} "
    fi

    local -a parent_candidates=()
    if command -v lsblk >/dev/null 2>&1; then
        local pk_out="" pk_line
        pk_out="$(lsblk -ndo PKNAME "$src" 2>/dev/null || true)"
        if [[ -z "$pk_out" && "$src_real" != "$src" ]]; then
            pk_out="$(lsblk -ndo PKNAME "$src_real" 2>/dev/null || true)"
        fi
        # Support mocks that match `lsblk -no PKNAME` (without `-d`), while
        # ignoring descendant lines emitted when line 1 (self PKNAME) is blank.
        if [[ -z "$pk_out" ]]; then
            local raw_no_out="" first_no_line=""
            raw_no_out="$(lsblk -no PKNAME "$src" 2>/dev/null || true)"
            if [[ -z "$raw_no_out" && "$src_real" != "$src" ]]; then
                raw_no_out="$(lsblk -no PKNAME "$src_real" 2>/dev/null || true)"
            fi
            if [[ -n "$raw_no_out" ]]; then
                IFS= read -r first_no_line <<< "$raw_no_out"
                first_no_line="${first_no_line#"${first_no_line%%[![:space:]]*}"}"
                first_no_line="${first_no_line%"${first_no_line##*[![:space:]]}"}"
                if [[ -n "$first_no_line" ]]; then
                    pk_out="$raw_no_out"
                fi
            fi
        fi

        while IFS= read -r pk_line; do
            pk_line="${pk_line#"${pk_line%%[![:space:]]*}"}"
            pk_line="${pk_line%"${pk_line##*[![:space:]]}"}"
            [[ -n "$pk_line" ]] || continue
            if [[ "$pk_line" == /* ]]; then
                parent_candidates+=("$pk_line")
            else
                parent_candidates+=("/dev/${pk_line}")
            fi
        done <<< "$pk_out"
    fi

    # Multi-slave virtual block devices (mdraid, multi-PV LVM) expose all backing
    # members in `/sys/class/block/<kname>/slaves` even when PKNAME omits extras.
    local slave_dir="/sys/class/block/${src_kname}/slaves"
    if [[ -n "$src_kname" && -d "$slave_dir" ]] && compgen -G "${slave_dir}/*" >/dev/null 2>&1; then
        local _s
        for _s in "${slave_dir}"/*; do
            [[ -e "$_s" ]] || continue
            parent_candidates+=("/dev/$(basename "$_s")")
        done
    fi

    local cand cand_kname
    for cand in ${parent_candidates[@]+"${parent_candidates[@]}"}; do
        [[ -n "$cand" ]] || continue
        cand_kname="${cand##*/}"
        if [[ "$cand_kname" == "$visit_key" || "$cand_kname" == "$src_orig_kname" ]]; then
            continue
        fi
        if _rvdk_source_backs_disk "$cand" "$target_dev" $(( depth + 1 )) "$visited"; then
            return 0
        fi
    done

    return 1
}

# List exact child partition device paths for <dev> without shell prefix globbing.
# Usage: rvdk_list_child_partitions <dev>
rvdk_list_child_partitions() {
    local dev="${1:-}"
    [[ -n "$dev" ]] || return 0
    command -v lsblk >/dev/null 2>&1 || return 0
    lsblk -rn -o PATH,TYPE "$dev" 2>/dev/null | awk '$2 == "part" {print $1}' || true
}

# Returns 0 if any partition/LV on <dev> backs a critical OS mountpoint or active swap
rvdk_device_backs_os_or_swap() {
    local dev="${1:-}"
    [[ -n "$dev" ]] || return 1

    local mnt
    while IFS= read -r mnt; do
        [[ -z "$mnt" ]] && continue
        if _rvdk_is_critical_mountpoint "$mnt"; then
            return 0
        fi
    done < <(_rvdk_lsblk_mountpoints "$dev")

    # Cross-check critical OS mounts via findmnt and resolve parent disks
    # recursively so stacked LVM/LUKS/mdraid OS devices fail closed.
    if command -v findmnt >/dev/null 2>&1; then
        local tgt src
        while IFS=' ' read -r tgt src; do
            [[ -n "$tgt" && -n "$src" ]] || continue
            src="${src%%\[*}"
            [[ "$src" == /* ]] || continue
            if _rvdk_is_critical_mountpoint "$tgt" && _rvdk_source_backs_disk "$src" "$dev"; then
                return 0
            fi
        done < <(findmnt -rn -o TARGET,SOURCE 2>/dev/null || true)

        local -a crit_targets=(
            /
            /boot
            /boot/efi
            /boot/firmware
            /usr
            /var
            /var/log
            /var/lib
            /home
            /etc
            /opt
            /root
            /srv
        )
        local _b_sub
        if [[ -d /boot ]]; then
            for _b_sub in /boot/*; do
                [[ -d "$_b_sub" ]] || continue
                case "$_b_sub" in
                    /boot/efi|/boot/firmware) ;;
                    *) crit_targets+=("$_b_sub") ;;
                esac
            done
        fi

        local mp
        for mp in "${crit_targets[@]}"; do
            while IFS= read -r src; do
                src="${src#"${src%%[![:space:]]*}"}"
                src="${src%"${src##*[![:space:]]}"}"
                src="${src%%\[*}"
                [[ "$src" == /* ]] || continue
                if _rvdk_source_backs_disk "$src" "$dev"; then
                    return 0
                fi
            done < <(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)
        done
    fi

    # Cross-check /proc/swaps against child block nodes and parent chains
    if [[ -r /proc/swaps ]]; then
        local kname
        while IFS= read -r kname; do
            [[ -z "$kname" ]] && continue
            if awk -v d="/dev/${kname}" 'NR>1 && $1 == d {found=1} END {exit !found}' /proc/swaps 2>/dev/null; then
                return 0
            fi
        done < <(lsblk -nr -o KNAME "$dev" 2>/dev/null || true)

        local swap_src
        while IFS= read -r swap_src; do
            [[ "$swap_src" == /* ]] || continue
            if _rvdk_source_backs_disk "$swap_src" "$dev"; then
                return 0
            fi
        done < <(awk 'NR>1 {print $1}' /proc/swaps 2>/dev/null || true)
    fi

    return 1
}

# Assert that <dev> is safe to wipe/format.
# Usage: rvdk_assert_device_safe_to_wipe <dev> <force_wipe_bool> [_unused_allowed_labels]
rvdk_assert_device_safe_to_wipe() {
    local dev="$1"
    local force_wipe="${2:-false}"
    # Optional 3rd parameter retained for caller compatibility; never bypasses wipe guard when force_wipe != true.
    local _unused_allowed="${3:-}"
    : "$_unused_allowed"

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
    done < <(_rvdk_lsblk_mountpoints "$dev")
    if [[ ${#active_mnts[@]} -gt 0 ]]; then
        log_fatal "Safety Interlock: ${dev} has mounted filesystem(s) (${active_mnts[*]}). Unmount and pass --force-wipe if you intend to destroy existing data."
    fi

    # Hard Interlock 3 (when force_wipe == false): Refuse if ANY existing filesystem, LVM PV, RAID, ZFS, or LUKS exists
    local line node_desc
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _rvdk_storage_parse_lsblk_line "$line"
        [[ -z "$_RVDK_SG_FSTYPE" || "$_RVDK_SG_FSTYPE" == "-" ]] && continue
        node_desc="$dev"
        if [[ -n "$_RVDK_SG_PATH" && "$_RVDK_SG_PATH" != "$dev" ]]; then
            node_desc="${dev} (${_RVDK_SG_PATH})"
        fi
        log_fatal "Safety Interlock: ${node_desc} already contains '${_RVDK_SG_FSTYPE}' signature${_RVDK_SG_LABEL:+ (label=${_RVDK_SG_LABEL})}. Pass --force-wipe to overwrite."
    done < <(lsblk -P -o PATH,TYPE,FSTYPE,LABEL "$dev" 2>/dev/null || true)

    local -a blkid_nodes=("$dev")
    local _p _seen _existing
    while IFS= read -r _p; do
        [[ -n "$_p" ]] || continue
        _seen="false"
        for _existing in "${blkid_nodes[@]}"; do
            if [[ "$_existing" == "$_p" ]]; then
                _seen="true"
                break
            fi
        done
        [[ "$_seen" == "false" ]] && blkid_nodes+=("$_p")
    done < <(lsblk -nr -o PATH "$dev" 2>/dev/null || true)

    local blk_node blkid_type blkid_lbl
    for blk_node in "${blkid_nodes[@]}"; do
        blkid_type="$(blkid -s TYPE -o value "$blk_node" 2>/dev/null || true)"
        blkid_lbl="$(blkid -s LABEL -o value "$blk_node" 2>/dev/null || true)"
        if [[ -n "$blkid_type" ]]; then
            node_desc="$dev"
            if [[ "$blk_node" != "$dev" ]]; then
                node_desc="${dev} (${blk_node})"
            fi
            log_fatal "Safety Interlock: ${node_desc} contains existing '${blkid_type}' superblock${blkid_lbl:+ (label=${blkid_lbl})}. Pass --force-wipe to overwrite."
        fi
    done
}

# Returns 0 only if a whole disk is genuinely blank/unused (no mounts, swap, partitions, holders, or FS magic)
rvdk_disk_is_blank() {
    local dev="$1"
    [[ -b "$dev" ]] || return 1
    rvdk_device_backs_os_or_swap "$dev" && return 1

    local m
    m="$(_rvdk_lsblk_mountpoints "$dev" | tr -d '[:space:]' || true)"
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

# Idempotently converge an fstab entry matching <spec> or <mount> in [fstab_file] (default: /etc/fstab).
# Usage: rvdk_converge_fstab_entry <spec> <mount> <fstype> <entry> [fstab_file]
rvdk_converge_fstab_entry() {
    local spec="$1"
    local mnt="$2"
    local fstype="$3"
    local entry="$4"
    local fstab_file="${5:-/etc/fstab}"
    local want_fstab=""

    if [[ -s "$fstab_file" ]]; then
        want_fstab="$(RVDK_FSTAB_SPEC="$spec" RVDK_FSTAB_MNT="$mnt" RVDK_FSTAB_LINE="$entry" awk '
            BEGIN {
                sp = ENVIRON["RVDK_FSTAB_SPEC"]
                mp = ENVIRON["RVDK_FSTAB_MNT"]
                line = ENVIRON["RVDK_FSTAB_LINE"]
                replaced = 0
                while (length(mp) > 1 && substr(mp, length(mp), 1) == "/") {
                    mp = substr(mp, 1, length(mp) - 1)
                }
            }
            /^[[:space:]]*#/ || NF < 2 { print; next }
            {
                m = $2
                while (length(m) > 1 && substr(m, length(m), 1) == "/") {
                    m = substr(m, 1, length(m) - 1)
                }
                if ($1 == sp || m == mp) {
                    if (!replaced) {
                        print line
                        replaced = 1
                    }
                    next
                }
                print
            }
            END { if (!replaced) print line }
        ' "$fstab_file")"
    else
        want_fstab="$entry"
    fi

    if [[ -f "$fstab_file" ]] && printf '%s\n' "$want_fstab" | cmp -s - "$fstab_file" 2>/dev/null; then
        log_skip "${mnt} (${fstype}) already in ${fstab_file}"
    else
        printf '%s\n' "$want_fstab" | rvdk_atomic_write "$fstab_file" 0644
        if [[ "$fstab_file" == "/etc/fstab" ]] && command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload
        fi
        log_ok "Persisted ${spec} -> ${mnt} (${fstype}) in ${fstab_file}"
    fi
}
