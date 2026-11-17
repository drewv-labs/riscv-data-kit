#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Layer 2 Silicon BSP Primitives Library
# Path: riscv-data-kit/lib/bsp.sh
#
# Shared idempotent primitives across ESWIN, SiFive, StarFive, SpacemiT,
# Tenstorrent, and UltraRISC silicon BSP scripts:
#   • Vendor U-Boot/DTB/UEFI dpkg confold protection & boot config backups
#   • SSH-safe wired NIC DHCP fallback persistence (never clobbers live routes)
#   • Deterministic SD/eMMC ext4 rootfs labeling (rvdk_sd_root / rvdk_emmc_root)
#   • Sleep/suspend/hibernate systemd target masking
#   • Persistent cpufreq performance governor (systemd + OpenWrt procd)
#   • KASLR-safe hardware PMU counter exposure (kptr_restrict=1 default)
# ==============================================================================

if [[ "${_RVDK_BSP_SOURCED:-0}" == "1" ]]; then
    return 0 2>/dev/null || true
fi
_RVDK_BSP_SOURCED="1"

rvdk_bsp_read_dt_model() {
    local dt="Unknown"
    if [[ -r /proc/device-tree/model ]]; then
        dt="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
    fi
    echo "$dt"
}

rvdk_bsp_protect_dpkg() {
    local conf_path="$1"
    local label="${2:-vendor U-Boot/DTB}"
    if [[ ! -d /etc/apt/apt.conf.d ]]; then
        log_skip "Non-APT rootfs; skipping dpkg confold hook"
        return 0
    fi
    local want='Dpkg::Options {
   "--force-confdef";
   "--force-confold";
};'
    if ! printf '%s\n' "$want" | cmp -s - "$conf_path" 2>/dev/null; then
        printf '%s\n' "$want" > "$conf_path"
        chmod 0644 "$conf_path"
        log_ok "Configured dpkg confold protection for ${label} hooks (${conf_path})"
    else
        log_skip "${label} dpkg protection already active (${conf_path})"
    fi
}

rvdk_bsp_backup_boot_configs() {
    local cfg
    for cfg in "$@"; do
        if [[ -f "$cfg" && ! -f "${cfg}.factory.bak" ]]; then
            cp -a "$cfg" "${cfg}.factory.bak"
            log_ok "Backed up factory boot artifact to ${cfg}.factory.bak"
        fi
    done
}

# Persist a fallback DHCP config ONLY when the node has no active network manager /
# default route ownership, preventing mid-SSH static IP drops during `netplan apply`.
rvdk_bsp_persist_wired_nic() {
    local prefix="$1"
    shift || true

    if [[ -f /etc/openwrt_release ]]; then
        log_skip "OpenWrt netifd manages network interfaces (/etc/config/network); leaving untouched"
        return 0
    fi

    local target_nic="${RVDK_PRIMARY_NIC:-}"
    if [[ -z "$target_nic" || "$target_nic" == wl* ]]; then
        target_nic=""
        local cand
        for cand in "$@"; do
            if ip link show "$cand" >/dev/null 2>&1; then
                target_nic="$cand"
                break
            fi
        done
    fi

    if [[ -z "$target_nic" ]] || ! ip link show "$target_nic" >/dev/null 2>&1; then
        log_skip "No candidate wired NIC ($*) detected; skipping NIC persistence"
        return 0
    fi

    if command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]]; then
        # Never overwrite or re-apply Netplan if any existing YAML or NetworkManager already governs networking
        if grep -rqE "(${target_nic}|NetworkManager|ethernets:|macaddress:)" /etc/netplan/ 2>/dev/null; then
            log_skip "Netplan configuration already present in /etc/netplan/; preserving active network state"
            return 0
        fi
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
            log_skip "NetworkManager is actively managing networking; skipping Netplan override"
            return 0
        fi
        if ip -4 route show default 2>/dev/null | grep -q "dev ${target_nic}"; then
            log_skip "Active default route already established on '${target_nic}'; skipping disruptive netplan apply"
            return 0
        fi

        local np_file="/etc/netplan/01-${prefix}-${target_nic}.yaml"
        cat <<EOF > "$np_file"
network:
  version: 2
  ethernets:
    ${target_nic}:
      dhcp4: true
      optional: true
EOF
        chmod 0600 "$np_file"
        netplan apply
        log_ok "Persisted fallback DHCP configuration for ${target_nic} in ${np_file}"
    elif [[ -d /etc/network/interfaces.d ]]; then
        if grep -rqE "iface[[:space:]]+${target_nic}([[:space:]]|$)" /etc/network/ 2>/dev/null; then
            log_skip "Interface '${target_nic}' already persisted in /etc/network/"
        elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
            log_skip "NetworkManager is active; skipping /etc/network/interfaces.d/${target_nic}"
        else
            cat <<EOF > "/etc/network/interfaces.d/${target_nic}"
allow-hotplug ${target_nic}
iface ${target_nic} inet dhcp
EOF
            chmod 0644 "/etc/network/interfaces.d/${target_nic}"
            log_ok "Persisted ${target_nic} DHCP configuration in /etc/network/interfaces.d/${target_nic}"
        fi
    fi
}

# Converge non-colliding ext4 rootfs labels (`rvdk_sd_root` vs `rvdk_emmc_root`)
# and repair duplicate UUIDs across dual-populated SD + eMMC SBCs.
rvdk_bsp_converge_mmc_root_labels() {
    if [[ -f /etc/openwrt_release ]]; then
        log_skip "OpenWrt rootfs; skipping ext4 SD/eMMC label convergence"
        return 0
    fi
    if ! command -v e2label >/dev/null 2>&1 || ! command -v lsblk >/dev/null 2>&1 || ! command -v blkid >/dev/null 2>&1; then
        log_skip "e2label/lsblk/blkid not present; skipping SD/eMMC label convergence"
        return 0
    fi

    local live_root="" live_uuid=""
    if command -v findmnt >/dev/null 2>&1; then
        live_root="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    fi
    [[ -n "$live_root" && -b "$live_root" ]] && live_uuid="$(blkid -s UUID -o value "$live_root" 2>/dev/null || true)"

    local sys_mmc mmc_name dev_type want_lbl mmc_kind
    local found_any="false"
    for sys_mmc in /sys/block/mmcblk*; do
        [[ -e "$sys_mmc" ]] || continue
        mmc_name="$(basename "$sys_mmc")"
        [[ "$mmc_name" =~ ^mmcblk[0-9]+$ ]] || continue

        dev_type=""
        [[ -r "${sys_mmc}/device/type" ]] && dev_type="$(tr -d '[:space:]' < "${sys_mmc}/device/type" 2>/dev/null || true)"
        case "$dev_type" in
            SDIO) continue ;;
            SD|SDcombo)
                mmc_kind="SD"
                want_lbl="rvdk_sd_root"
                ;;
            MMC)
                mmc_kind="eMMC"
                want_lbl="rvdk_emmc_root"
                ;;
            *)
                case "$mmc_name" in
                    mmcblk0) mmc_kind="SD";   want_lbl="rvdk_sd_root" ;;
                    mmcblk2) mmc_kind="eMMC"; want_lbl="rvdk_emmc_root" ;;
                    *)       continue ;;
                esac
                ;;
        esac

        local root_part=""
        if [[ -n "$live_root" && "$live_root" == "/dev/${mmc_name}p"* ]]; then
            local live_fstype=""
            live_fstype="$(blkid -s TYPE -o value "$live_root" 2>/dev/null || true)"
            [[ "$live_fstype" == "ext4" ]] && root_part="$live_root"
        else
            local best_pref="" best_size_dev="" best_size=0
            local p_path p_type p_fs p_sz p_lbl p_lbl_lc
            while IFS=' ' read -r p_path p_type p_fs p_sz p_lbl; do
                [[ "$p_type" == "part" && "$p_fs" == "ext4" ]] || continue
                [[ "$p_sz" =~ ^[0-9]+$ ]] || p_sz=0
                (( p_sz >= 268435456 )) || continue
                p_lbl_lc="$(tr '[:upper:]' '[:lower:]' <<< "${p_lbl:-}")"
                case "$p_lbl_lc" in
                    boot|bootfs|opi_boot|armbi_boot|efi) continue ;;
                    opi_root|armbi_root|rootfs|cloudimg-rootfs|rvdk_*_root) best_pref="$p_path" ;;
                esac
                if (( p_sz > best_size )); then
                    best_size="$p_sz"
                    best_size_dev="$p_path"
                fi
            done < <(lsblk -ln -b -o PATH,TYPE,FSTYPE,SIZE,LABEL "/dev/${mmc_name}" 2>/dev/null || true)
            root_part="${best_pref:-$best_size_dev}"
        fi

        [[ -n "$root_part" && -b "$root_part" ]] || continue
        found_any="true"

        local cur_lbl=""
        cur_lbl="$(e2label "$root_part" 2>/dev/null | tr -d '[:space:]' || true)"

        # Repair duplicate root UUID on unmounted peer MMC device if both SD & eMMC came from identical raw images
        if [[ -n "$live_uuid" && "$root_part" != "$live_root" ]]; then
            local peer_uuid="" peer_mnt=""
            peer_uuid="$(blkid -s UUID -o value "$root_part" 2>/dev/null || true)"
            if command -v findmnt >/dev/null 2>&1; then
                peer_mnt="$(findmnt -rn -S "$root_part" -o TARGET 2>/dev/null | head -n1 || true)"
            fi
            if [[ -n "$peer_uuid" && "$peer_uuid" == "$live_uuid" && -z "$peer_mnt" ]] && command -v tune2fs >/dev/null 2>&1 && command -v e2fsck >/dev/null 2>&1; then
                local fsck_rc=0
                e2fsck -pf "$root_part" >/dev/null 2>&1 || fsck_rc=$?
                if (( fsck_rc <= 1 )); then
                    local new_uuid=""
                    new_uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
                    tune2fs -U "$new_uuid" "$root_part" >/dev/null
                    local tmp_mnt=""
                    tmp_mnt="$(mktemp -d "/tmp/rvdk_mmc_uuid.XXXXXX")"
                    if mount "$root_part" "$tmp_mnt" 2>/dev/null; then
                        local rel_cfg
                        for rel_cfg in etc/fstab boot/orangepiEnv.txt boot/armbianEnv.txt boot/env_k1-x.txt boot/spacemit/env_k1-x.txt boot/extlinux/extlinux.conf boot/efi/extlinux.conf; do
                            if [[ -f "${tmp_mnt}/${rel_cfg}" ]] && grep -qF "$peer_uuid" "${tmp_mnt}/${rel_cfg}" 2>/dev/null; then
                                sed -i "s|${peer_uuid}|${new_uuid}|g" "${tmp_mnt}/${rel_cfg}"
                            fi
                        done
                        sync
                        umount "$tmp_mnt" 2>/dev/null || true
                    fi
                    rmdir "$tmp_mnt" 2>/dev/null || true
                    log_ok "De-collided duplicate ${mmc_kind} ext4 UUID on ${root_part} -> ${new_uuid}"
                fi
            fi
        fi

        if [[ "$cur_lbl" != "$want_lbl" ]]; then
            if [[ "$root_part" == "$live_root" && -n "$cur_lbl" && -f /etc/fstab ]] && grep -qF "LABEL=${cur_lbl}" /etc/fstab 2>/dev/null; then
                sed -i "s|LABEL=${cur_lbl}|LABEL=${want_lbl}|g" /etc/fstab
            fi
            e2label "$root_part" "$want_lbl"
            log_ok "Labeled ${mmc_kind} ext4 rootfs: ${root_part} -> ${want_lbl}"
        else
            log_skip "${mmc_kind} ext4 rootfs label already converged (${root_part} = ${want_lbl})"
        fi
    done

    if [[ "$found_any" != "true" ]]; then
        log_skip "No ext4 SD/eMMC root partitions detected for label convergence"
    fi
}

# Optional extra systemd units may be passed via "$@" (e.g., apt-daily timers)
# shellcheck disable=SC2120
rvdk_bsp_mask_sleep_targets() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log_skip "systemd not present (procd); sleep target mask not required"
        return 0
    fi
    local units=(sleep.target suspend.target hibernate.target hybrid-sleep.target "$@")
    local need_mask="false"
    local u
    for u in "${units[@]}"; do
        [[ -z "$u" ]] && continue
        if [[ "$(systemctl is-enabled "$u" 2>/dev/null || true)" != "masked" ]]; then
            need_mask="true"
            break
        fi
    done

    if [[ "$need_mask" == "true" ]]; then
        systemctl mask "${units[@]}" >/dev/null 2>&1 || true
        log_ok "Masked unstable sleep/suspend/hibernate targets"
    else
        log_skip "Sleep/suspend targets already masked"
    fi
}

rvdk_bsp_lock_cpufreq_performance() {
    local unit_prefix="$1"
    local description="$2"

    # Prevent Armbian/OrangePi cpufrequtils hooks from resetting cpu0 back to ondemand
    if [[ -f /etc/default/cpufrequtils ]] && ! grep -Eq '^GOVERNOR="?performance"?$' /etc/default/cpufrequtils 2>/dev/null; then
        if grep -Eq '^GOVERNOR=' /etc/default/cpufrequtils 2>/dev/null; then
            sed -i 's/^GOVERNOR=.*/GOVERNOR="performance"/' /etc/default/cpufrequtils
        else
            printf '\nGOVERNOR="performance"\n' >> /etc/default/cpufrequtils
        fi
        log_ok "Pinned /etc/default/cpufrequtils GOVERNOR=\"performance\""
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if command -v powerprofilesctl >/dev/null 2>&1; then
            if [[ "$(powerprofilesctl get 2>/dev/null || true)" != "performance" ]]; then
                powerprofilesctl set performance 2>/dev/null && log_ok "Pinned power-profiles-daemon to 'performance'" || true
            fi
        fi

        local gov_unit="/etc/systemd/system/${unit_prefix}-cpufreq-performance.service"
        local want_unit="[Unit]
Description=${description}
After=multi-user.target power-profiles-daemon.service ondemand.service cpufrequtils.service orangepi-hardware-optimize.service armbian-hardware-optimize.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '[ -x /usr/bin/powerprofilesctl ] && /usr/bin/powerprofilesctl set performance >/dev/null 2>&1 || true; for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do [ -f \"\$g\" ] && echo performance > \"\$g\" || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"

        if ! printf '%s\n' "$want_unit" | cmp -s - "$gov_unit" 2>/dev/null; then
            printf '%s\n' "$want_unit" > "$gov_unit"
            chmod 0644 "$gov_unit"
            systemctl daemon-reload
            systemctl enable --now "${unit_prefix}-cpufreq-performance.service" >/dev/null
            if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
                log_ok "Enabled persistent performance governor service (${gov_unit})"
            else
                log_ok "Armed performance governor service (${gov_unit}; kernel uses firmware-fixed clock)"
            fi
        else
            systemctl start "${unit_prefix}-cpufreq-performance.service" 2>/dev/null || true
            log_skip "Performance governor service (${unit_prefix}) already active"
        fi
    elif [[ -f /etc/rc.common ]]; then
        local procd_gov="/etc/init.d/${unit_prefix}-cpufreq"
        local g
        for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
            [[ -f "$g" ]] && echo performance > "$g" 2>/dev/null || true
        done
        if [[ ! -x "$procd_gov" ]]; then
            cat <<'PROCD_EOF' > "$procd_gov"
#!/bin/sh /etc/rc.common
START=95
start() {
    for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -f "$g" ] && echo performance > "$g" 2>/dev/null || true
    done
}
PROCD_EOF
            chmod +x "$procd_gov"
            "$procd_gov" enable 2>/dev/null || true
            log_ok "Enabled OpenWrt procd performance governor (${procd_gov})"
        else
            log_skip "OpenWrt procd performance governor (${procd_gov}) already enabled"
        fi
    fi
}

# Unlock hardware PMU counters while preserving KASLR for unprivileged processes by default
# (kptr_restrict = 1 hides kallsyms from non-CAP_SYSLOG users while allowing root/perf profiling).
rvdk_bsp_unlock_pmu() {
    local sysctl_file="$1"
    local cpu_label="$2"
    local expose_kallsyms="${3:-false}"

    local kptr_val="1"
    if [[ "$expose_kallsyms" == "true" ]]; then
        kptr_val="0"
        log_warn "Explicit --expose-kallsyms enabled (kptr_restrict=${kptr_val}): kernel symbol addresses exposed to unprivileged users!"
    fi

    mkdir -p /etc/sysctl.d
    local want_pmu="# Unlock ${cpu_label} hardware performance counters (KASLR preserved for unprivileged users via kptr_restrict=${kptr_val})
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = ${kptr_val}"

    if ! printf '%s\n' "$want_pmu" | cmp -s - "$sysctl_file" 2>/dev/null; then
        printf '%s\n' "$want_pmu" > "$sysctl_file"
        chmod 0644 "$sysctl_file"
        sysctl --system >/dev/null 2>&1 || sysctl -p "$sysctl_file" >/dev/null 2>&1 || true
        log_ok "Unlocked ${cpu_label} PMU counters in ${sysctl_file} (kptr_restrict=${kptr_val})"
    else
        log_skip "${cpu_label} PMU sysctls already converged (${sysctl_file})"
    fi
}
