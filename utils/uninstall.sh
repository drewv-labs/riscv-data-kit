#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Uninstaller (`remove` vs `--purge`)
# Path: riscv-data-kit/utils/uninstall.sh
#
# Follows Debian/FHS package lifecycle semantics (`apt remove` vs `apt purge`):
#
#   • Default (`sudo rvdk uninstall` / `remove`):
#       Removes CLI symlinks (`/usr/bin/rvdk`, `/usr/local/bin/rvdk`), the
#       system engine (`/usr/local/share/rvdk`), regenerable download/media
#       caches (`/var/cache/rvdk`), and runtime stamps (`/run/rvdk-*`), and
#       restores the default OS login MOTD/banner header.
#       PRESERVES `/etc/rvdk/` (`kit.env`, `deeptune.env`, `config.env`),
#       `/var/lib/rvdk/`, and active OS/BSP/DeepTune kernel drop-ins.
#
#   • Full Purge (`sudo rvdk uninstall --purge` / `sudo rvdk purge`):
#       Removes everything above PLUS restores preserved vendor configuration
#       backups under `/var/lib/rvdk/backups/{apt,dns,ntp,openwrt,registries}`
#       (unless `--no-restore-backups` is passed), removes `/etc/rvdk/`,
#       `/var/lib/rvdk/`, and all RVDK-authored systemd/procd tuning units,
#       sysctl/modprobe/journald/APT drop-ins, and `rvdk-net-guard` nftables
#       rules, then reloads `systemd`, `fw4` (OpenWrt), and `sysctl`.
#
#   • Hard Safety Boundary (NEVER touched even with `--purge`):
#       Provisioned POSIX users, SSH keys, `/etc/hostname`, primary NIC configs
#       (`/etc/netplan`, `/etc/network`, `/etc/config/network`), formatted
#       LVM/NVMe/Btrfs mounts (`/etc/fstab`, `/mnt/*`), and workload services
#       (`postgresql`, `mosquitto`, `ntfy`, `nfs-server`/`nfs-ganesha`,
#       `tailscaled`).
#
# Usage:
#   sudo rvdk uninstall [--purge] [--no-restore-backups] [--dry-run] [-y|--yes]
#   curl -fsSL https://rvdk.drewv-labs.dev/utils/uninstall.sh | sudo bash -s -- [--purge] [-y]
# ==============================================================================

if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L ksh
    setopt PIPE_FAIL ERR_RETURN NO_UNSET
else
    set -Eeuo pipefail
fi

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [[ -n "${ZSH_VERSION:-}" && "${0:-}" != "zsh" && "${0:-}" != "-zsh" && -f "${0:-}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/.." && pwd)"

# @RVDK_INLINE_LIBS: common motd
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:UNINSTALL]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_sanitize_locale() { export LANG=C LC_ALL=C; }
        rvdk_resolve_caller() { REAL_HOME="${HOME:-}"; }
        rvdk_atomic_write() {
            local _dst="$1" _mode="${2:-0644}" _owner="${3:-}" _tmp
            mkdir -p "$(dirname "$_dst")"
            _tmp="$(mktemp "$(dirname "$_dst")/.$(basename "$_dst").rvdk.XXXXXX")"
            cat > "$_tmp"
            chmod "$_mode" "$_tmp"
            [[ -n "$_owner" ]] && chown "$_owner" "$_tmp"
            mv -f "$_tmp" "$_dst"
        }
    fi
fi
if [[ -z "${_RVDK_MOTD_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/motd.sh" ]]; then
        # shellcheck source=lib/motd.sh
        source "${_REPO_ROOT}/lib/motd.sh"
    fi
fi

print_uninstall_help() {
    cat <<'EOF'
Usage:
  sudo rvdk uninstall [options]
  sudo rvdk uninstall --purge [options]

Options:
  --purge                Also restore preserved vendor config backups under
                         /var/lib/rvdk/backups/, remove /etc/rvdk (kit.env,
                         deeptune.env, config.env), /var/lib/rvdk, and all
                         RVDK-managed sysctl/modprobe/systemd/fw4/APT drop-ins
                         (`apt purge` semantics). Note: default OS login
                         MOTD/banner headers are restored in both modes.
  --no-restore-backups   During --purge, skip restoring /var/lib/rvdk/backups/*
                         and leave current APT/DNS/NTP/UCI configs in place
  -n, --dry-run          Preview every path, backup, and unit that would be
                         restored or removed (no root needed)
  -y, --yes              Skip interactive confirmation prompt
  -h, --help             Show this help message

Safety Boundary:
  User accounts, SSH keys, network interface configs (/etc/netplan,
  /etc/config/network), formatted storage volumes (/mnt/*, vg_rvdk, /etc/fstab),
  and workload services/databases (PostgreSQL, Mosquitto, ntfy, NFS, Tailscale)
  are NEVER modified or removed.
EOF
}

main() {
    rvdk_log_init "RVDK:UNINSTALL"

    local purge="false"
    local restore_backups="true"
    local dry_run="false"
    local skip_confirm="false"
    local orig_args=("$@")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge|purge)         purge="true"; shift ;;
            --no-restore-backups)  restore_backups="false"; shift ;;
            --restore-backups)     restore_backups="true"; shift ;;
            -n|--dry-run)          dry_run="true"; shift ;;
            -y|--yes|--force)      skip_confirm="true"; shift ;;
            -h|--help|help)        print_uninstall_help; return 0 ;;
            *)                     log_fatal "Unknown option: $1 (see --help)" ;;
        esac
    done

    if [[ "$dry_run" != "true" ]]; then
        local script_self="${BASH_SOURCE[0]:-}"
        if [[ -z "$script_self" && -n "${ZSH_VERSION:-}" && -f "${0:-}" ]]; then
            script_self="$0"
        fi
        rvdk_require_root "$script_self" ${orig_args[@]+"${orig_args[@]}"}
    fi

    rvdk_sanitize_locale
    rvdk_resolve_caller

    # Move CWD out of /usr/local/share/rvdk/engine prior to unlinking engine directory
    cd /

    local sys_engine="${RVDK_ENGINE_DIR:-/usr/local/share/rvdk/engine}"
    local sys_share_parent
    sys_share_parent="$(dirname "$sys_engine")"
    local sys_cache="${RVDK_CACHE_DIR:-/var/cache/rvdk}"
    local state_root="${RVDK_STATE_DIR:-/var/lib/rvdk}"
    local backup_root="${RVDK_BACKUP_ROOT:-${state_root}/backups}"
    local os_type
    os_type="$(uname -s)"

    # Safety guard against dangerous RVDK_ENGINE_DIR / RVDK_CACHE_DIR / RVDK_STATE_DIR overrides
    case "$sys_engine" in
        ""|"/"|"/usr"|"/usr/local"|"/usr/local/share"|"/etc"|"/var"|"/home"|"$REAL_HOME")
            log_fatal "Refusing unsafe RVDK_ENGINE_DIR='${sys_engine}'."
            ;;
    esac
    case "$sys_cache" in
        ""|"/"|"/var"|"/var/cache"|"/etc"|"/usr"|"/home"|"$REAL_HOME")
            log_fatal "Refusing unsafe RVDK_CACHE_DIR='${sys_cache}'."
            ;;
    esac
    case "$state_root" in
        ""|"/"|"/var"|"/var/lib"|"/etc"|"/usr"|"/home"|"$REAL_HOME")
            log_fatal "Refusing unsafe RVDK_STATE_DIR='${state_root}'."
            ;;
    esac

    local mode_desc="Standard Uninstall (restoring default login header; preserving /etc/rvdk, ${state_root} & active tuning)"
    if [[ "$purge" == "true" ]]; then
        if [[ "$restore_backups" == "true" ]]; then
            mode_desc="Full Purge (restoring login header & ${backup_root}, removing engine, caches, /etc/rvdk, ${state_root} & RVDK drop-ins)"
        else
            mode_desc="Full Purge (restoring login header without config backup restore; removing engine, caches, /etc/rvdk, ${state_root} & RVDK drop-ins)"
        fi
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY-RUN] Mode: ${mode_desc}"
    else
        log_info "Mode: ${mode_desc}"
        if [[ "$skip_confirm" != "true" ]]; then
            if [[ -t 1 && -r /dev/tty ]]; then
                local prompt_msg="Remove RVDK CLI, engine, and caches, and restore default login header (keeping /etc/rvdk & tuning)?"
                [[ "$purge" == "true" ]] && prompt_msg="PURGE RVDK CLI, engine, /etc/rvdk, ${state_root}, and all RVDK tuning drop-ins?"
                printf "\033[1;33m[CONFIRM]\033[0m %s [y/N]: " "$prompt_msg"
                local reply=""
                read -r reply < /dev/tty || true
                case "$reply" in
                    [Yy]|[Yy][Ee][Ss]) ;;
                    *) log_fatal "Aborted by user." ;;
                esac
            elif [[ "$purge" == "true" ]]; then
                log_fatal "Non-interactive '--purge' requires '-y' / '--yes'."
            fi
        fi
    fi

    local removed_count=0

    remove_path() {
        local p="$1"
        [[ -n "$p" ]] || return 0
        if [[ -L "$p" || -e "$p" ]]; then
            if [[ "$dry_run" == "true" ]]; then
                log_info "[DRY-RUN] Would remove: ${p}"
            else
                rm -rf "$p"
                log_ok "Removed ${p}"
            fi
            removed_count=$(( removed_count + 1 ))
        fi
    }

    stop_disable_systemd_unit() {
        local unit_name="$1"
        local unit_file="/etc/systemd/system/${unit_name}"
        [[ -L "$unit_file" || -f "$unit_file" ]] || return 0
        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY-RUN] Would disable & remove systemd unit: ${unit_file}"
        else
            if command -v systemctl >/dev/null 2>&1; then
                systemctl disable --now "$unit_name" >/dev/null 2>&1 || true
            fi
            rm -f "$unit_file"
            log_ok "Disabled & removed systemd unit: ${unit_file}"
        fi
        removed_count=$(( removed_count + 1 ))
    }

    stop_disable_openwrt_init() {
        local init_path="$1"
        [[ -f "$init_path" ]] || return 0
        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY-RUN] Would disable & remove procd init script: ${init_path}"
        else
            "$init_path" disable >/dev/null 2>&1 || true
            "$init_path" stop >/dev/null 2>&1 || true
            rm -f "$init_path"
            log_ok "Disabled & removed procd init script: ${init_path}"
        fi
        removed_count=$(( removed_count + 1 ))
    }

    restore_preserved_backups() {
        [[ -d "$backup_root" ]] || return 0
        local cat_name cat_dir bfile bbase stem dest bmode bowner
        local openwrt_uci_restored="false"

        for cat_name in apt dns ntp openwrt registries; do
            cat_dir="${backup_root}/${cat_name}"
            [[ -d "$cat_dir" ]] || continue

            for bfile in "${cat_dir}"/*.orig; do
                [[ -f "$bfile" && ! -L "$bfile" ]] || continue
                bbase="$(basename "$bfile")"
                stem="${bbase%.orig}"
                dest=""

                if [[ "$stem" == *__* ]]; then
                    dest="/${stem//__//}"
                else
                    case "$cat_name" in
                        apt)
                            dest="/etc/apt/${stem}"
                            ;;
                        dns)
                            if [[ "$stem" == "resolv.conf" ]]; then
                                dest="/etc/resolv.conf"
                            elif [[ "$stem" == "resolved.conf" ]]; then
                                dest="/etc/systemd/resolved.conf"
                            else
                                dest="/etc/systemd/resolved.conf.d/${stem}"
                            fi
                            ;;
                        ntp)
                            if [[ "$stem" == "chrony.conf" ]]; then
                                if [[ -d /etc/chrony || -f /etc/chrony/chrony.conf ]]; then
                                    dest="/etc/chrony/chrony.conf"
                                else
                                    dest="/etc/chrony.conf"
                                fi
                            else
                                dest="/etc/${stem}"
                            fi
                            ;;
                        openwrt)
                            case "$stem" in
                                distfeeds.conf|customfeeds.conf) dest="/etc/opkg/${stem}" ;;
                                repositories)                    dest="/etc/apk/repositories" ;;
                                system|dhcp)                     dest="/etc/config/${stem}" ;;
                            esac
                            ;;
                    esac
                fi

                [[ -n "$dest" && "$dest" == /* && "$dest" != *".."* ]] || continue
                # Hard safety invariant: NEVER touch `/etc/config/network` on OpenWrt
                [[ "$dest" == "/etc/config/network" ]] && continue
                # Do not clobber symlinks (e.g. systemd-resolved stub /etc/resolv.conf)
                [[ -L "$dest" ]] && continue

                if [[ "$dry_run" == "true" ]]; then
                    log_info "[DRY-RUN] Would restore backup: ${bfile} -> ${dest}"
                    removed_count=$(( removed_count + 1 ))
                else
                    bmode="$(stat -c '0%a' "$bfile" 2>/dev/null || echo 0644)"
                    bowner="$(stat -c '%u:%g' "$bfile" 2>/dev/null || echo "")"
                    rvdk_atomic_write "$dest" "$bmode" "$bowner" < "$bfile"
                    log_ok "Restored ${dest} from ${bfile}"
                    removed_count=$(( removed_count + 1 ))
                    if [[ "$dest" == "/etc/config/system" || "$dest" == "/etc/config/dhcp" ]]; then
                        openwrt_uci_restored="true"
                    fi
                fi
            done
        done

        if [[ "$dry_run" != "true" && "$openwrt_uci_restored" == "true" ]]; then
            [[ -x /etc/init.d/sysntpd ]] && /etc/init.d/sysntpd reload >/dev/null 2>&1 || true
            [[ -x /etc/init.d/dnsmasq ]] && /etc/init.d/dnsmasq reload >/dev/null 2>&1 || true
        fi
    }

    # ==========================================================================
    # TIER 1: CLI Symlinks, Engine Tree, Regenerable Caches, Stamps & Login MOTD
    # ==========================================================================
    remove_path "/usr/bin/rvdk"
    remove_path "/usr/local/bin/rvdk"
    remove_path "$sys_engine"

    if [[ "$sys_share_parent" == "/usr/local/share/rvdk" && -d "$sys_share_parent" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY-RUN] Would remove directory if empty: ${sys_share_parent}"
        else
            rmdir "$sys_share_parent" 2>/dev/null && log_ok "Removed ${sys_share_parent}" || true
        fi
    fi

    remove_path "$sys_cache"
    if [[ "$os_type" == "Darwin" && -n "$REAL_HOME" ]]; then
        remove_path "${REAL_HOME}/Library/Caches/rvdk"
    elif [[ -n "$REAL_HOME" ]]; then
        remove_path "${XDG_CACHE_HOME:-${REAL_HOME}/.cache}/rvdk"
    fi
    if [[ -n "$REAL_HOME" && -d "${REAL_HOME}/.rvdk" ]]; then
        remove_path "${REAL_HOME}/.rvdk"
    fi

    local stamp
    for stamp in /run/rvdk-*; do
        [[ -e "$stamp" || -L "$stamp" ]] || continue
        remove_path "$stamp"
    done
    if [[ -d /run/rvdk ]]; then
        remove_path "/run/rvdk"
    fi

    if [[ "$os_type" == "Linux" ]] && declare -F rvdk_restore_login_motd >/dev/null 2>&1; then
        if rvdk_restore_login_motd "$dry_run"; then
            removed_count=$(( removed_count + 1 ))
        fi
    fi

    # ==========================================================================
    # TIER 2: Full Purge (`--purge` only)
    # ==========================================================================
    if [[ "$purge" == "true" ]]; then
        local systemd_dirty="false"
        local sysctl_dirty="false"
        local fw4_dirty="false"

        if [[ "$os_type" == "Linux" ]]; then
            local unit_base
            for unit_base in \
                rvdk-thp-tune.service \
                rvdk-net-guard.service \
                cve-2026-98432-guard.service \
                eic7700x-thp-tune.service \
                eic7700x-irq-affinity.service \
                spacemit-k1-irq-affinity.service \
                rvdk-p550-hdmi-off.service \
                eic7700x-cpufreq-performance.service \
                jh7110-cpufreq-performance.service \
                fu740-cpufreq-performance.service \
                spacemit-k1-cpufreq-performance.service \
                spacemit-k3-cpufreq-performance.service \
                dp1000-cpufreq-performance.service \
                atlantis-cpufreq-performance.service \
                ultrarisc-dp1000-cpufreq-performance.service \
                tenstorrent-atlantis-cpufreq-performance.service; do
                if [[ -L "/etc/systemd/system/${unit_base}" || -f "/etc/systemd/system/${unit_base}" ]]; then
                    stop_disable_systemd_unit "$unit_base"
                    systemd_dirty="true"
                fi
            done

            local helper_sbin
            for helper_sbin in \
                /usr/local/sbin/rvdk-eic7700x-irq-tune \
                /usr/local/sbin/rvdk-spacemit-k1-irq-tune \
                /usr/local/sbin/rvdk-p550-hdmi-off; do
                [[ -e "$helper_sbin" || -L "$helper_sbin" ]] && remove_path "$helper_sbin"
            done

            local init_script
            for init_script in \
                /etc/init.d/rvdk-thp-tune \
                /etc/init.d/rvdk-net-guard \
                /etc/init.d/cve-2026-98432-guard \
                /etc/init.d/eic7700x-cpufreq \
                /etc/init.d/jh7110-cpufreq \
                /etc/init.d/fu740-cpufreq \
                /etc/init.d/spacemit-k1-cpufreq \
                /etc/init.d/spacemit-k3-cpufreq \
                /etc/init.d/dp1000-cpufreq \
                /etc/init.d/atlantis-cpufreq \
                /etc/init.d/ultrarisc-dp1000-cpufreq \
                /etc/init.d/tenstorrent-atlantis-cpufreq; do
                stop_disable_openwrt_init "$init_script"
            done

            local nft_dropin
            for nft_dropin in \
                /etc/systemd/system/nftables.service.d/90-rvdk-net-guard.conf \
                /etc/systemd/system/nftables.service.d/90-rvdk-cve-2026-98432.conf; do
                if [[ -f "$nft_dropin" || -L "$nft_dropin" ]]; then
                    remove_path "$nft_dropin"
                    systemd_dirty="true"
                fi
            done
            [[ "$dry_run" != "true" ]] && rmdir /etc/systemd/system/nftables.service.d 2>/dev/null || true

            if [[ -f /etc/systemd/journald.conf.d/90-rvdk-deeptune.conf ]]; then
                remove_path "/etc/systemd/journald.conf.d/90-rvdk-deeptune.conf"
                [[ "$dry_run" != "true" ]] && rmdir /etc/systemd/journald.conf.d 2>/dev/null || true
                systemd_dirty="true"
            fi

            if [[ -f /etc/systemd/timesyncd.conf.d/10-rvdk-ntp.conf ]]; then
                remove_path "/etc/systemd/timesyncd.conf.d/10-rvdk-ntp.conf"
                [[ "$dry_run" != "true" ]] && rmdir /etc/systemd/timesyncd.conf.d 2>/dev/null || true
                systemd_dirty="true"
            fi

            if [[ -f /etc/systemd/resolved.conf.d/10-rvdk-dns.conf ]]; then
                remove_path "/etc/systemd/resolved.conf.d/10-rvdk-dns.conf"
                [[ "$dry_run" != "true" ]] && rmdir /etc/systemd/resolved.conf.d 2>/dev/null || true
                systemd_dirty="true"
            fi

            remove_path "/etc/nftables.d/10-rvdk-ip-options.nft"
            remove_path "/etc/rvdk-net-guard.nft"
            remove_path "/etc/nftables.d/10-cve-2026-98432.nft"
            remove_path "/etc/nftables.d/cve-2026-98432.nft"
            remove_path "/etc/cve-2026-98432.nft"

            local fw4_snippet
            for fw4_snippet in \
                /usr/share/nftables.d/ruleset-post/10-rvdk-net-guard.nft \
                /usr/share/nftables.d/ruleset-post/10-cve-2026-98432.nft; do
                if [[ -e "$fw4_snippet" || -L "$fw4_snippet" ]]; then
                    remove_path "$fw4_snippet"
                    fw4_dirty="true"
                fi
            done

            if command -v nft >/dev/null 2>&1; then
                local nft_tbl
                for nft_tbl in rvdk_net_guard cve_2026_98432; do
                    if nft list table ip "$nft_tbl" >/dev/null 2>&1; then
                        if [[ "$dry_run" == "true" ]]; then
                            log_info "[DRY-RUN] Would flush & delete nftables table: ip ${nft_tbl}"
                            removed_count=$(( removed_count + 1 ))
                        else
                            nft delete table ip "$nft_tbl" 2>/dev/null || true
                            log_ok "Deleted live nftables table: ip ${nft_tbl}"
                            removed_count=$(( removed_count + 1 ))
                        fi
                    fi
                done
            fi

            if [[ "$fw4_dirty" == "true" ]]; then
                if [[ "$dry_run" == "true" ]]; then
                    log_info "[DRY-RUN] Would reload OpenWrt fw4 firewall ruleset"
                else
                    fw4 reload >/dev/null 2>&1 || true
                fi
            fi

            local sc_file
            for sc_file in \
                /etc/sysctl.d/89-rvdk-io-uring.conf \
                /etc/sysctl.d/90-rvdk-*.conf \
                /etc/sysctl.d/95-rvdk-deeptune.conf \
                /etc/sysctl.d/99-rvdk-net-guard.conf \
                /etc/sysctl.d/99-cve-2026-98432-tcp.conf \
                /etc/sysctl.d/90-sifive-p550-pmu.conf \
                /etc/sysctl.d/90-sifive-u74-pmu.conf \
                /etc/sysctl.d/90-starfive-u74-pmu.conf \
                /etc/sysctl.d/90-spacemit-x60-pmu.conf \
                /etc/sysctl.d/90-spacemit-x100-pmu.conf \
                /etc/sysctl.d/90-ultrarisc-cp100-pmu.conf \
                /etc/sysctl.d/90-tenstorrent-ascalon-pmu.conf; do
                if [[ -e "$sc_file" || -L "$sc_file" ]]; then
                    remove_path "$sc_file"
                    sysctl_dirty="true"
                fi
            done

            local mp_file
            for mp_file in \
                /etc/modprobe.d/85-rvdk-os-deeptune.conf \
                /etc/modprobe.d/90-rvdk-*.conf \
                /etc/needrestart/conf.d/90-rvdk-stateful.conf \
                /etc/apt/preferences.d/nosnap.pref \
                /etc/apt/apt.conf.d/90-p550-bsp-protect \
                /etc/apt/apt.conf.d/90-starfive-bsp-protect \
                /etc/apt/apt.conf.d/90-spacemit-bsp-protect \
                /etc/apt/apt.conf.d/90-sifive-fu740-bsp-protect \
                /etc/apt/apt.conf.d/90-ultrarisc-bsp-protect \
                /etc/apt/apt.conf.d/90-tenstorrent-bsp-protect \
                /etc/apt/sources.list.d/rvdk-local-pgdg.list; do
                [[ -e "$mp_file" || -L "$mp_file" ]] && remove_path "$mp_file"
            done

            if [[ "$restore_backups" == "true" ]]; then
                restore_preserved_backups
            elif [[ -d "$backup_root" ]]; then
                log_skip "Skipped restoring config backups from ${backup_root} (--no-restore-backups)"
            fi
        fi

        remove_path "/etc/rvdk"
        remove_path "$state_root"

        if [[ "$dry_run" != "true" && "$os_type" == "Linux" ]]; then
            if [[ "$systemd_dirty" == "true" ]] && command -v systemctl >/dev/null 2>&1; then
                systemctl daemon-reload >/dev/null 2>&1 || true
            fi
            if [[ "$sysctl_dirty" == "true" ]] && command -v sysctl >/dev/null 2>&1; then
                sysctl --system >/dev/null 2>&1 || true
            fi
        fi
    else
        if [[ -d /etc/rvdk || -d "$state_root" ]]; then
            log_skip "Preserved /etc/rvdk & ${state_root} (pass '--purge' to remove state & tuning drop-ins)"
        fi
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_ok "Dry-run complete (${removed_count} item(s) matched)."
    elif (( removed_count == 0 )); then
        log_skip "RVDK artifacts already absent; nothing to remove."
    else
        log_ok "RVDK uninstall complete (${removed_count} item(s) removed/restored)."
    fi
}

main "$@"; exit 0
