#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Orange Pi RV2 (SpacemiT K1 / Ky X1) SD -> eMMC Bootstrapper
# Path: riscv-data-kit/boards/orangepi/rv2/flash-emmc.sh
#
# Non-interactive, SSH-safe, deterministic replacement for `nand-sata-install`
# (Option 2: "Boot from eMMC - system on eMMC") per Orange Pi RV2 hardware flow:
#   1. Flash MicroSD on host (`rvdk flash rv2 sd <disk>`) -> `rvdk_sd_root`
#   2. Boot Orange Pi RV2 from MicroSD and converge Day-0 OS / BSP
#   3. Bootstrap onboard eMMC from the live SD card (`sudo rvdk flash rv2 emmc`):
#      • Preflights U-Boot SPL binaries (`bootinfo_emmc.bin`, `FSBL.bin`,
#        `u-boot-opensbi.itb`) BEFORE touching eMMC
#      • Partitions full eMMC capacity (16 MiB-aligned LBA 32768..99% MBR)
#      • Formats `/dev/mmcblk2p1` ext4 with fresh UUID & label `rvdk_emmc_root`
#      • Clones live SD rootfs via two-pass `rsync` (never killing DHCP/SSH!)
#      • Rewrites target `/etc/fstab` & `/boot/orangepiEnv.txt` to new eMMC UUID
#      • Seeds cold-RTC floor (`/etc/fake-hwclock.data` + timesync)
#      • Programs both `/dev/mmcblk2boot0` & `/dev/mmcblk2` Ky/SpacemiT SPL/ITB
# ==============================================================================

set -Eeuo pipefail

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

# @RVDK_INLINE_LIBS: common
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:RV2-EMMC]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m  [WARN]\033[0m %s\n" "$1" >&2; }
        log_fatal() { printf "\033[1;31m  [FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_sanitize_locale() { export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=C; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_validate_hostname() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || log_fatal "Invalid hostname: $1"; }
        rvdk_sync_cold_clock() { :; }
    fi
fi

rvdk_log_init "RVDK:RV2-EMMC"

_EMMC_TMP_MNT=""
_STOPPED_SVCS=()
_rvdk_emmc_cleanup() {
    local svc
    for svc in ${_STOPPED_SVCS[@]+"${_STOPPED_SVCS[@]}"}; do
        systemctl start "$svc" 2>/dev/null || true
    done
    if [[ -n "${_EMMC_TMP_MNT:-}" && -d "${_EMMC_TMP_MNT}" ]]; then
        if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "${_EMMC_TMP_MNT}" 2>/dev/null; then
            umount "${_EMMC_TMP_MNT}" 2>/dev/null || umount -l "${_EMMC_TMP_MNT}" 2>/dev/null || true
        else
            umount "${_EMMC_TMP_MNT}" 2>/dev/null || true
        fi
        rmdir "${_EMMC_TMP_MNT}" 2>/dev/null || true
    fi
    declare -F _rvdk_cleanup_tmpfiles >/dev/null 2>&1 && _rvdk_cleanup_tmpfiles || true
}

print_emmc_usage() {
    cat <<'EOF'
Usage (run on Orange Pi RV2 booted from MicroSD):
  sudo rvdk flash rv2 emmc [options] [/dev/mmcblk2]

Options:
  -d, --device <path>       Target onboard eMMC device (default: auto-detect MMC, e.g. /dev/mmcblk2)
      --root-label <label>  Target eMMC ext4 label (default: rvdk_emmc_root)
      --hostname <name>     Optional RFC-1123 hostname override for the eMMC installation
  -n, --dry-run             Validate SD source, eMMC target, and U-Boot SPL files without modifying disk
      --force               Override SD-boot source check
  -y, --yes                 Skip interactive confirmation prompt
  -h, --help                Show this help message

Hardware Workflow:
  Orange Pi RV2 eMMC cannot be flashed directly from a host workstation.
  1. Flash MicroSD on host : rvdk flash rv2 sd <disk_num>
  2. Boot RV2 from MicroSD : BootROM prioritizes SD (rvdk_sd_root) over eMMC
  3. Bootstrap eMMC from SD: sudo rvdk flash rv2 emmc
EOF
}

main() {
    local orig_args=("$@")
    local target_dev=""
    local root_label="rvdk_emmc_root"
    local target_hostname=""
    local dry_run="false"
    local force_run="false"
    local skip_confirm="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--device)       target_dev="${2:-}"; shift 2 ;;
            --root-label)      root_label="${2:-}"; shift 2 ;;
            --hostname)        target_hostname="${2:-}"; shift 2 ;;
            -n|--dry-run)      dry_run="true"; shift ;;
            --force)           force_run="true"; shift ;;
            -y|--yes)          skip_confirm="true"; shift ;;
            -h|--help)         print_emmc_usage; return 0 ;;
            -*)                log_fatal "Unknown option: $1 (see --help)" ;;
            *)
                if [[ -z "$target_dev" ]]; then
                    target_dev="$1"
                    shift
                else
                    log_fatal "Unexpected positional argument: $1"
                fi
                ;;
        esac
    done

    local os_type
    os_type="$(uname -s)"
    if [[ "$os_type" != "Linux" ]]; then
        log_fatal "Orange Pi RV2 eMMC cannot be flashed from a ${os_type} workstation. Flash MicroSD first ('rvdk flash rv2 sd <disk>'), boot the RV2 from SD, then run 'sudo rvdk flash rv2 emmc' on the board."
    fi

    if [[ ! "$root_label" =~ ^[a-zA-Z0-9_.-]{1,16}$ ]]; then
        log_fatal "Invalid ext4 root label '${root_label}' (max 16 chars: [a-zA-Z0-9_.-])."
    fi

    if [[ -n "$target_hostname" ]]; then
        rvdk_validate_hostname "$target_hostname"
    fi

    if [[ "$dry_run" != "true" ]]; then
        rvdk_require_root "${BASH_SOURCE[0]:-}" ${orig_args[@]+"${orig_args[@]}"}
        declare -F rvdk_sync_cold_clock >/dev/null 2>&1 && rvdk_sync_cold_clock
    fi
    rvdk_sanitize_locale

    # --------------------------------------------------------------------------
    # 1. Verify Live Rootfs Is Running from MicroSD & Resolve Target eMMC
    # --------------------------------------------------------------------------
    local dt_model="Unknown"
    [[ -r /proc/device-tree/model ]] && dt_model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
    local dt_lc
    dt_lc="$(tr '[:upper:]' '[:lower:]' <<< "$dt_model")"
    if [[ "$force_run" != "true" ]]; then
        case "$dt_lc" in
            *"orangepi-rv2"*|*"orangepi rv2"*|*"orange pi rv2"*|*"ky x1"*|*"spacemit"*) ;;
            *) log_fatal "Host '${dt_model}' is not an Orange Pi RV2 / SpacemiT K1 board. Run this command on the booted RV2 (or pass --force)." ;;
        esac
    fi

    local live_root=""
    live_root="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [[ -z "$live_root" || ! -b "$live_root" ]] && log_fatal "Cannot determine live root block device ('findmnt -n -o SOURCE /')."

    local live_disk=""
    live_disk="/dev/$(lsblk -no PKNAME "$live_root" 2>/dev/null | head -n1 | xargs || true)"
    if [[ "$live_disk" == "/dev/" ]]; then
        live_disk="${live_root%p[0-9]*}"
    fi
    local live_base
    live_base="$(basename "$live_disk")"
    local live_mmc_type=""
    [[ -r "/sys/block/${live_base}/device/type" ]] && live_mmc_type="$(tr -d '[:space:]' < "/sys/block/${live_base}/device/type" 2>/dev/null || true)"

    if [[ "$force_run" != "true" ]]; then
        if [[ "$live_base" != mmcblk* || "$live_mmc_type" == "MMC" ]]; then
            log_fatal "System is currently booted from '${live_root}' (type=${live_mmc_type:-non-SD}), not MicroSD! Boot from the RVDK SD card first to bootstrap eMMC."
        fi
    fi

    if [[ -z "$target_dev" ]]; then
        local sys_mmc cand_name cand_type
        for sys_mmc in /sys/block/mmcblk*; do
            [[ -e "$sys_mmc" ]] || continue
            cand_name="$(basename "$sys_mmc")"
            [[ "$cand_name" =~ ^mmcblk[0-9]+$ ]] || continue
            [[ "/dev/${cand_name}" == "$live_disk" ]] && continue
            cand_type=""
            [[ -r "${sys_mmc}/device/type" ]] && cand_type="$(tr -d '[:space:]' < "${sys_mmc}/device/type" 2>/dev/null || true)"
            if [[ "$cand_type" == "MMC" ]]; then
                target_dev="/dev/${cand_name}"
                break
            fi
        done
    fi

    [[ -z "$target_dev" ]] && log_fatal "No onboard eMMC device (/sys/block/mmcblk*/device/type == MMC) detected. Verify the eMMC module is seated onto the RV2 socket."
    [[ ! -b "$target_dev" ]] && log_fatal "Target eMMC block device not found: ${target_dev}"

    case "$target_dev" in
        *boot[0-9]|*rpmb) log_fatal "Specify whole eMMC device (e.g. /dev/mmcblk2), not hardware sub-partition '${target_dev}'." ;;
    esac
    local target_type=""
    target_type="$(lsblk -dn -o TYPE "$target_dev" 2>/dev/null | head -n1 | xargs || true)"
    [[ "$target_type" == "part" ]] && log_fatal "Specify whole eMMC device (e.g. /dev/mmcblk2), not partition '${target_dev}'."
    [[ "$target_dev" == "$live_disk" ]] && log_fatal "Safety Interlock: target '${target_dev}' is the currently booted root disk!"

    local mnt_chk
    while IFS= read -r mnt_chk; do
        [[ -z "$mnt_chk" ]] && continue
        case "$mnt_chk" in
            /|/boot|/boot/*|/usr|/var|/home|"[SWAP]")
                log_fatal "Safety Interlock: ${target_dev} backs active system mount/swap (${mnt_chk})! Aborting."
                ;;
        esac
    done < <(lsblk -rn -o MOUNTPOINTS "$target_dev" 2>/dev/null || lsblk -rn -o MOUNTPOINT "$target_dev" 2>/dev/null || true)

    local emmc_bytes=0 min_bytes=$(( 8 * 1024 * 1024 * 1024 ))
    emmc_bytes="$(lsblk -b -dn -o SIZE "$target_dev" 2>/dev/null | head -n1 | tr -dc '0-9' || echo 0)"
    [[ -z "$emmc_bytes" ]] && emmc_bytes=0
    if (( emmc_bytes < min_bytes )); then
        log_fatal "Target eMMC ${target_dev} (${emmc_bytes} bytes) is smaller than minimum 8 GiB."
    fi

    # --------------------------------------------------------------------------
    # 2. Preflight U-Boot SPL Artifacts & Required Tools BEFORE Touching eMMC
    # --------------------------------------------------------------------------
    local uboot_dir=""
    if [[ -f /usr/lib/u-boot/platform_install.sh ]]; then
        uboot_dir="$(awk -F= '/^DIR=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' /usr/lib/u-boot/platform_install.sh 2>/dev/null || true)"
    fi
    if [[ -z "$uboot_dir" || ! -d "$uboot_dir" ]]; then
        local cand_ub
        for cand_ub in /usr/lib/linux-u-boot-*; do
            if [[ -d "$cand_ub" ]]; then
                uboot_dir="$cand_ub"
                break
            fi
        done
    fi
    [[ -z "$uboot_dir" || ! -d "$uboot_dir" ]] && log_fatal "Cannot locate Orange Pi RV2 U-Boot directory (/usr/lib/linux-u-boot-*)."

    local req_bin
    for req_bin in bootinfo_emmc.bin bootinfo_sd.bin FSBL.bin u-boot-opensbi.itb; do
        [[ -f "${uboot_dir}/${req_bin}" ]] || log_fatal "Missing required SpacemiT/Ky bootloader binary: ${uboot_dir}/${req_bin}"
    done

    local total_sectors=$(( emmc_bytes / 512 ))
    local first_sector=32768
    local last_sector=$(( 32768 * (total_sectors * 99 / 3276800) - 1 ))
    if (( last_sector <= first_sector + 1048576 )); then
        last_sector=$(( total_sectors - 2048 ))
    fi

    local emmc_human
    emmc_human="$(lsblk -dn -o SIZE "$target_dev" 2>/dev/null | head -n1 | xargs || echo "${emmc_bytes}B")"
    local live_uuid=""
    live_uuid="$(blkid -s UUID -o value "$live_root" 2>/dev/null || true)"

    log_info "Board Model        : ${dt_model}"
    log_info "Source SD Root     : ${live_root} (UUID=${live_uuid:-unknown})"
    log_info "Target eMMC        : ${target_dev} (${emmc_human} | LBA ${first_sector}..${last_sector} -> ${root_label})"
    log_info "Bootloader Payload : ${uboot_dir} -> ${target_dev}boot0 + ${target_dev}"
    [[ -n "$target_hostname" ]] && log_info "Target Hostname    : ${target_hostname}"

    if [[ "$dry_run" == "true" ]]; then
        log_ok "[DRY-RUN] Preflight succeeded; ${target_dev} was not modified."
        return 0
    fi

    local missing_pkgs=()
    command -v parted >/dev/null 2>&1 || missing_pkgs+=(parted)
    command -v rsync >/dev/null 2>&1  || missing_pkgs+=(rsync)
    command -v mkfs.ext4 >/dev/null 2>&1 || missing_pkgs+=(e2fsprogs)
    if [[ -f /boot/boot.cmd ]] && ! command -v mkimage >/dev/null 2>&1; then
        missing_pkgs+=(u-boot-tools)
    fi
    if (( ${#missing_pkgs[@]} > 0 )) && command -v apt-get >/dev/null 2>&1; then
        log_info "Installing required bootstrap utilities (${missing_pkgs[*]})..."
        DEBIAN_FRONTEND=noninteractive apt-get update -y -q
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing_pkgs[@]}"
    fi
    for tool_cmd in parted rsync mkfs.ext4 e2label blkid; do
        command -v "$tool_cmd" >/dev/null 2>&1 || log_fatal "Required utility '${tool_cmd}' is not installed."
    done

    local used_mb avail_emmc_mb
    used_mb="$(df -BM / | awk 'NR==2 {gsub(/[^0-9]/, "", $3); print $3}')"
    avail_emmc_mb=$(( ((last_sector - first_sector) * 512) / 1048576 ))
    if [[ -n "$used_mb" ]] && (( used_mb + 512 >= avail_emmc_mb )); then
        log_fatal "Live SD rootfs uses ${used_mb} MiB, exceeding eMMC partition capacity (${avail_emmc_mb} MiB)."
    fi

    if [[ "$skip_confirm" != "true" ]]; then
        printf "\033[1;33m[CONFIRM]\033[0m Erase onboard eMMC %s (%s) and bootstrap live SD system -> '%s'? [y/N]: " \
            "$target_dev" "$emmc_human" "$root_label"
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

    trap '_rvdk_emmc_cleanup' EXIT INT TERM

    # --------------------------------------------------------------------------
    # 3. Partition Full eMMC (16 MiB-Aligned MBR) & Format `rvdk_emmc_root`
    # --------------------------------------------------------------------------
    log_info "Unmounting and partitioning ${target_dev} (msdos | ${first_sector}s..${last_sector}s)..."
    local sub_p
    for sub_p in "${target_dev}"*; do
        [[ "$sub_p" == "$target_dev" ]] && continue
        umount "$sub_p" 2>/dev/null || umount -l "$sub_p" 2>/dev/null || true
    done

    command -v wipefs >/dev/null 2>&1 && wipefs -af "$target_dev" >/dev/null 2>&1 || true
    dd if=/dev/zero of="$target_dev" bs=512 seek=$(( total_sectors - 2048 )) count=2048 status=none 2>/dev/null || true
    dd if=/dev/zero of="$target_dev" bs=1 seek=446 count=64 status=none 2>/dev/null || true

    parted -s "$target_dev" -- mklabel msdos
    parted -s "$target_dev" -- mkpart primary ext4 "${first_sector}s" "${last_sector}s"
    partprobe "$target_dev" 2>/dev/null || blockdev --rereadpt "$target_dev" 2>/dev/null || true
    command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || sleep 2

    local emmc_part="${target_dev}p1"
    [[ ! -b "$emmc_part" ]] && log_fatal "Expected eMMC root partition '${emmc_part}' did not appear after parted."

    log_info "Formatting ${emmc_part} as ext4 (label=${root_label})..."
    mkfs.ext4 -F -q -L "$root_label" "$emmc_part"
    sync

    local emmc_uuid="" emmc_partuuid="" live_partuuid=""
    emmc_uuid="$(blkid -s UUID -o value "$emmc_part" 2>/dev/null || true)"
    emmc_partuuid="$(blkid -s PARTUUID -o value "$emmc_part" 2>/dev/null || true)"
    live_partuuid="$(blkid -s PARTUUID -o value "$live_root" 2>/dev/null || true)"
    [[ -z "$emmc_uuid" ]] && log_fatal "Failed to read ext4 UUID from newly formatted ${emmc_part}."
    [[ "$emmc_uuid" == "$live_uuid" ]] && log_fatal "UUID collision detected (${emmc_uuid}); refusing unsafe clone."
    log_ok "Formatted ${emmc_part} : LABEL=${root_label} | UUID=${emmc_uuid} | PARTUUID=${emmc_partuuid}"

    # --------------------------------------------------------------------------
    # 4. Two-Pass Live Rootfs Bootstrap via `rsync` (SSH & DHCP Safe)
    # --------------------------------------------------------------------------
    _EMMC_TMP_MNT="$(mktemp -d "/tmp/rvdk_rv2_emmc.XXXXXX")"
    mount -o noatime "$emmc_part" "$_EMMC_TMP_MNT"

    mkdir -p \
        "${_EMMC_TMP_MNT}/boot" \
        "${_EMMC_TMP_MNT}/dev" \
        "${_EMMC_TMP_MNT}/proc" \
        "${_EMMC_TMP_MNT}/sys" \
        "${_EMMC_TMP_MNT}/run" \
        "${_EMMC_TMP_MNT}/mnt" \
        "${_EMMC_TMP_MNT}/media" \
        "${_EMMC_TMP_MNT}/tmp"
    chmod 1777 "${_EMMC_TMP_MNT}/tmp"

    local rsync_excludes=(
        --exclude=/boot/*
        --exclude=/dev/*
        --exclude=/proc/*
        --exclude=/sys/*
        --exclude=/media/*
        --exclude=/mnt/*
        --exclude=/run/*
        --exclude=/tmp/*
        --exclude=/ddbr/*
        --exclude=/lost+found
        --exclude=/var/cache/rvdk/*
        --exclude=/var/cache/apt/archives/*.deb
        --exclude=/var/log/journal/*
        --exclude=/var/log.hdd/*
        --exclude=/var/swap
        --exclude=/swapfile
    )
    if [[ -f /usr/lib/nand-sata-install/exclude.txt ]]; then
        rsync_excludes+=(--exclude-from=/usr/lib/nand-sata-install/exclude.txt)
    fi

    log_info "Pass 1/2: Cloning live SD rootfs (${used_mb:-?} MiB) -> ${emmc_part}..."
    rsync -aHAX --numeric-ids --delete "${rsync_excludes[@]}" / "${_EMMC_TMP_MNT}/"

    # Briefly quiesce local stateful services (NEVER ssh, systemd-networkd, NetworkManager, or dhclient!)
    local cand_svc
    if command -v systemctl >/dev/null 2>&1; then
        for cand_svc in postgresql.service mosquitto.service ntfy.service cron.service; do
            if systemctl is-active --quiet "$cand_svc" 2>/dev/null; then
                systemctl stop "$cand_svc" 2>/dev/null || true
                _STOPPED_SVCS+=("$cand_svc")
            fi
        done
    fi

    log_info "Pass 2/2: Syncing delta & staging /boot kernel/DTB/initramfs..."
    rsync -aHAX --numeric-ids --delete "${rsync_excludes[@]}" / "${_EMMC_TMP_MNT}/"
    rsync -aHAX --numeric-ids --delete /boot/ "${_EMMC_TMP_MNT}/boot/"

    for cand_svc in ${_STOPPED_SVCS[@]+"${_STOPPED_SVCS[@]}"}; do
        systemctl start "$cand_svc" 2>/dev/null || true
    done
    _STOPPED_SVCS=()

    mkdir -p "${_EMMC_TMP_MNT}/var/log/journal"

    # Disable first-boot resize service on eMMC since p1 already spans full capacity
    if [[ -f "${_EMMC_TMP_MNT}/lib/systemd/system/orangepi-resize-filesystem.service" || -f "${_EMMC_TMP_MNT}/usr/lib/systemd/system/orangepi-resize-filesystem.service" ]]; then
        mkdir -p "${_EMMC_TMP_MNT}/etc/systemd/system"
        ln -sf /dev/null "${_EMMC_TMP_MNT}/etc/systemd/system/orangepi-resize-filesystem.service"
    fi

    # Force RVDK kit.env refresh on first eMMC boot & seed cold-RTC floor
    rm -f "${_EMMC_TMP_MNT}/etc/rvdk/kit.env" 2>/dev/null || true
    if (( $(date -u +%s 2>/dev/null || echo 0) >= 1767225600 )); then
        date -u '+%Y-%m-%d %H:%M:%S' > "${_EMMC_TMP_MNT}/etc/fake-hwclock.data" 2>/dev/null || true
        chmod 0644 "${_EMMC_TMP_MNT}/etc/fake-hwclock.data" 2>/dev/null || true
        if [[ -d "${_EMMC_TMP_MNT}/var/lib/systemd/timesync" ]]; then
            : > "${_EMMC_TMP_MNT}/var/lib/systemd/timesync/clock" 2>/dev/null || true
        fi
    fi

    # --------------------------------------------------------------------------
    # 5. Converge Target `/etc/fstab`, `/boot/orangepiEnv.txt` & Hostname
    # --------------------------------------------------------------------------
    local fstab_out="${_EMMC_TMP_MNT}/etc/fstab"
    {
        printf "# Managed by RVDK (boards/orangepi/rv2/flash-emmc.sh | root=%s)\n" "$root_label"
        printf "UUID=%s\t/\text4\tdefaults,noatime,errors=remount-ro\t0\t1\n" "$emmc_uuid"
        printf "tmpfs\t/tmp\ttmpfs\tdefaults,nosuid\t0\t0\n"
        if [[ -f /etc/fstab ]]; then
            awk '
                /^[[:space:]]*#/ || NF < 3 { next }
                $2 == "/" || $2 == "/boot" || $2 == "/tmp" || $3 == "swap" { next }
                $1 ~ /mmcblk/ { next }
                $2 ~ /^\/mnt\// { print $0 }
            ' /etc/fstab
        fi
    } > "$fstab_out"
    chmod 0644 "$fstab_out"

    # Ensure mountpoint directories exist for any preserved /mnt/* NVMe LVM volumes
    if [[ -f "$fstab_out" ]]; then
        local preserved_mp
        while IFS= read -r preserved_mp; do
            [[ -n "$preserved_mp" ]] && mkdir -p "${_EMMC_TMP_MNT}${preserved_mp}"
        done < <(awk '!/^[[:space:]]*#/ && $2 ~ /^\/mnt\// {print $2}' "$fstab_out")
    fi
    log_ok "Wrote de-collided eMMC /etc/fstab (UUID=${emmc_uuid})"

    local env_txt="${_EMMC_TMP_MNT}/boot/orangepiEnv.txt"
    if [[ -f "$env_txt" ]]; then
        if grep -q '^rootdev=' "$env_txt"; then
            sed -i "s|^rootdev=.*|rootdev=UUID=${emmc_uuid}|" "$env_txt"
        else
            printf "rootdev=UUID=%s\n" "$emmc_uuid" >> "$env_txt"
        fi
        if grep -q '^rootfstype=' "$env_txt"; then
            sed -i "s|^rootfstype=.*|rootfstype=ext4|" "$env_txt"
        else
            printf "rootfstype=ext4\n" >> "$env_txt"
        fi
        rm -f "${env_txt}.factory.bak" 2>/dev/null || true
        log_ok "Updated target /boot/orangepiEnv.txt -> rootdev=UUID=${emmc_uuid}"
    fi

    local extra_boot_cfg
    for extra_boot_cfg in \
        "${_EMMC_TMP_MNT}/boot/armbianEnv.txt" \
        "${_EMMC_TMP_MNT}/boot/env_k1-x.txt" \
        "${_EMMC_TMP_MNT}/boot/spacemit/env_k1-x.txt" \
        "${_EMMC_TMP_MNT}/boot/extlinux/extlinux.conf" \
        "${_EMMC_TMP_MNT}/boot/efi/extlinux.conf"; do
        if [[ -f "$extra_boot_cfg" && -n "$live_uuid" ]] && grep -qF "$live_uuid" "$extra_boot_cfg" 2>/dev/null; then
            sed -i "s|${live_uuid}|${emmc_uuid}|g" "$extra_boot_cfg"
            log_ok "Updated target ${extra_boot_cfg#"$_EMMC_TMP_MNT"} -> UUID=${emmc_uuid}"
        fi
    done

    if [[ -f "${_EMMC_TMP_MNT}/boot/boot.cmd" ]] && command -v mkimage >/dev/null 2>&1; then
        if [[ -n "$live_uuid" ]] && grep -qF "$live_uuid" "${_EMMC_TMP_MNT}/boot/boot.cmd" 2>/dev/null; then
            sed -i "s|${live_uuid}|${emmc_uuid}|g" "${_EMMC_TMP_MNT}/boot/boot.cmd"
        fi
        mkimage -C none -A arm -T script -d "${_EMMC_TMP_MNT}/boot/boot.cmd" "${_EMMC_TMP_MNT}/boot/boot.scr" >/dev/null
        log_ok "Compiled target /boot/boot.scr via mkimage"
    fi

    if [[ -n "$target_hostname" ]]; then
        local old_host=""
        [[ -f "${_EMMC_TMP_MNT}/etc/hostname" ]] && old_host="$(tr -d '[:space:]' < "${_EMMC_TMP_MNT}/etc/hostname" || true)"
        printf "%s\n" "$target_hostname" > "${_EMMC_TMP_MNT}/etc/hostname"
        if [[ -f "${_EMMC_TMP_MNT}/etc/hosts" ]]; then
            if grep -qE '^127\.0\.1\.1[[:space:]]' "${_EMMC_TMP_MNT}/etc/hosts"; then
                sed -i -E "s|^127\.0\.1\.1[[:space:]].*$|127.0.1.1\t${target_hostname}|" "${_EMMC_TMP_MNT}/etc/hosts"
            elif [[ -n "$old_host" ]] && grep -qw "$old_host" "${_EMMC_TMP_MNT}/etc/hosts"; then
                sed -i "s|${old_host}|${target_hostname}|g" "${_EMMC_TMP_MNT}/etc/hosts"
            else
                printf "127.0.1.1\t%s\n" "$target_hostname" >> "${_EMMC_TMP_MNT}/etc/hosts"
            fi
        fi
        log_ok "Configured eMMC hostname -> ${target_hostname} (preserved SSH host keys for seamless role switching)"
    fi

    sync
    umount "$_EMMC_TMP_MNT"
    rmdir "$_EMMC_TMP_MNT"
    _EMMC_TMP_MNT=""

    # --------------------------------------------------------------------------
    # 6. Program SpacemiT/Ky eMMC `boot0` SPL & User-Area U-Boot/OpenSBI
    # --------------------------------------------------------------------------
    local boot0_dev="${target_dev}boot0"
    if [[ -b "$boot0_dev" ]]; then
        local boot0_ro
        boot0_ro="/sys/block/$(basename "$boot0_dev")/force_ro"
        [[ -f "$boot0_ro" ]] && printf '0\n' > "$boot0_ro"
        dd if="${uboot_dir}/bootinfo_emmc.bin" of="$boot0_dev" bs=512 seek=0 conv=notrunc,fsync status=none
        dd if="${uboot_dir}/FSBL.bin" of="$boot0_dev" bs=1 seek=512 conv=notrunc,fsync status=none
        sync
        [[ -f "$boot0_ro" ]] && printf '1\n' > "$boot0_ro"
        log_ok "Programmed eMMC hardware boot0 SPL (${boot0_dev} <- bootinfo_emmc.bin + FSBL.bin)"
    else
        log_warn "Block device ${boot0_dev} not exposed by kernel; writing user-area SPL/U-Boot only."
    fi

    # Write user-area bootinfo (<440B, preserving MBR Disk Signature & Partition Table at 0x1B8..0x1FF),
    # FSBL (@ LBA 256), default env (@ LBA 768), and OpenSBI+U-Boot FIT (@ LBA 1664 < LBA 32768).
    head -c 440 "${uboot_dir}/bootinfo_sd.bin" | dd of="$target_dev" bs=1 seek=0 conv=notrunc,fsync status=none
    dd if="${uboot_dir}/FSBL.bin" of="$target_dev" bs=512 seek=256 conv=notrunc,fsync status=none
    if [[ -f "${uboot_dir}/u-boot-env-default.bin" ]]; then
        dd if="${uboot_dir}/u-boot-env-default.bin" of="$target_dev" bs=512 seek=768 conv=notrunc,fsync status=none
    fi
    dd if="${uboot_dir}/u-boot-opensbi.itb" of="$target_dev" bs=512 seek=1664 conv=notrunc,fsync status=none
    sync
    log_ok "Programmed eMMC OpenSBI + U-Boot ITB (${target_dev} @ LBA 0/256/768/1664)"

    # --------------------------------------------------------------------------
    # 7. Final Dual-Media Label & UUID Verification
    # --------------------------------------------------------------------------
    local sd_lbl=""
    sd_lbl="$(e2label "$live_root" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$sd_lbl" != "rvdk_sd_root" ]]; then
        e2label "$live_root" "rvdk_sd_root" 2>/dev/null || true
        sd_lbl="$(e2label "$live_root" 2>/dev/null | tr -d '[:space:]' || true)"
    fi

    local verified_emmc_lbl=""
    verified_emmc_lbl="$(e2label "$emmc_part" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$verified_emmc_lbl" != "$root_label" ]] && log_fatal "Failed to verify ext4 label '${root_label}' on ${emmc_part}."

    log_ok "Orange Pi RV2 dual-media bootstrap complete!"
    printf "\n"
    printf "  • SD Root (Active) : %-16s LABEL=%-16s UUID=%s PARTUUID=%s\n" "$live_root" "${sd_lbl:-rvdk_sd_root}" "${live_uuid:-n/a}" "${live_partuuid:-n/a}"
    printf "  • eMMC Root (Ready): %-16s LABEL=%-16s UUID=%s PARTUUID=%s\n" "$emmc_part" "$verified_emmc_lbl" "$emmc_uuid" "${emmc_partuuid:-n/a}"
    printf "\n"
    printf "  Boot Role Switching (SpacemiT/Ky Native SD-Priority Boot Order):\n"
    printf "    • Keep MicroSD inserted  -> Boots SD role (%s)\n" "${sd_lbl:-rvdk_sd_root}"
    printf "    • Power off & eject SD   -> Boots onboard eMMC role (%s)\n" "$verified_emmc_lbl"
}

main "$@"
