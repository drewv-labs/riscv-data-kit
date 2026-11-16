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
#       caches (`/var/cache/rvdk`), and runtime stamps (`/run/rvdk-*`).
#       PRESERVES `/etc/rvdk/` (`kit.env`, `deeptune.env`, `config.env`),
#       `/var/lib/rvdk/`, and active OS/BSP/DeepTune kernel drop-ins.
#
#   • Full Purge (`sudo rvdk uninstall --purge` / `sudo rvdk purge`):
#       Removes everything above PLUS `/etc/rvdk/`, `/var/lib/rvdk/`, and all
#       RVDK-authored systemd oneshot tuning units, sysctl/modprobe/journald
#       drop-ins, APT bootloader-protect hooks, and CVE nftables guards, then
#       reloads `systemd` and `sysctl --system`.
#
#   • Hard Safety Boundary (NEVER touched even with `--purge`):
#       Provisioned POSIX users, SSH keys, `/etc/hostname`, primary NIC configs
#       (`/etc/netplan`, `/etc/network`), formatted LVM/NVMe/Btrfs mounts
#       (`/etc/fstab`, `/mnt/*`), and workload services/data (`postgresql`,
#       `mosquitto`, `nfs-server`/`nfs-ganesha`, `tailscaled`).
#
# Usage:
#   sudo rvdk uninstall [--purge] [--dry-run] [-y|--yes]
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

# @RVDK_INLINE_LIBS: common
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${_REPO_ROOT}/lib/common.sh"
fi

print_uninstall_help() {
    cat <<'EOF'
Usage:
  sudo rvdk uninstall [options]
  sudo rvdk uninstall --purge [options]

Options:
  --purge        Also remove /etc/rvdk (kit.env, deeptune.env, config.env),
                 /var/lib/rvdk, and all RVDK-managed sysctl/modprobe/systemd
                 tuning & BSP drop-ins (`apt purge` semantics)
  -n, --dry-run  Preview every path and unit that would be removed (no root needed)
  -y, --yes      Skip interactive confirmation prompt
  -h, --help     Show this help message

Safety Boundary:
  User accounts, SSH keys, network interface configs, formatted storage volumes
  (/mnt/*, vg_rvdk, /etc/fstab), and workload services/databases (PostgreSQL,
  Mosquitto, NFS, Tailscale) are NEVER modified or removed.
EOF
}

main() {
    rvdk_log_init "RVDK:UNINSTALL"

    local purge="false"
    local dry_run="false"
    local skip_confirm="false"
    local orig_args=("$@")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge|purge)       purge="true"; shift ;;
            -n|--dry-run)        dry_run="true"; shift ;;
            -y|--yes|--force)    skip_confirm="true"; shift ;;
            -h|--help|help)      print_uninstall_help; return 0 ;;
            *)                   log_fatal "Unknown option: $1 (see --help)" ;;
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
    local os_type
    os_type="$(uname -s)"

    # Safety guard against dangerous RVDK_ENGINE_DIR / RVDK_CACHE_DIR overrides
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

    local mode_desc="Standard Uninstall (preserving /etc/rvdk, /var/lib/rvdk & active tuning)"
    [[ "$purge" == "true" ]] && mode_desc="Full Purge (removing engine, caches, /etc/rvdk, /var/lib/rvdk & RVDK drop-ins)"

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY-RUN] Mode: ${mode_desc}"
    else
        log_info "Mode: ${mode_desc}"
        if [[ "$skip_confirm" != "true" ]]; then
            if [[ -t 1 && -r /dev/tty ]]; then
                local prompt_msg="Remove RVDK CLI, engine, and caches (keeping /etc/rvdk & tuning)?"
                [[ "$purge" == "true" ]] && prompt_msg="PURGE RVDK CLI, engine, /etc/rvdk, /var/lib/rvdk, and all RVDK tuning drop-ins?"
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

    # ==========================================================================
    # TIER 1: CLI Symlinks, Engine Tree, Regenerable Caches & Runtime Stamps
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

    # ==========================================================================
    # TIER 2: Full Purge (`--purge` only)
    # ==========================================================================
    if [[ "$purge" == "true" ]]; then
        local systemd_dirty="false"
        local sysctl_dirty="false"

        if [[ "$os_type" == "Linux" ]]; then
            local unit_base
            for unit_base in \
                rvdk-thp-tune.service \
                eic7700x-thp-tune.service \
                eic7700x-irq-affinity.service \
                rvdk-p550-hdmi-off.service \
                cve-2026-98432-guard.service \
                eic7700x-cpufreq-performance.service \
                jh7110-cpufreq-performance.service \
                fu740-cpufreq-performance.service \
                spacemit-k1-cpufreq-performance.service \
                spacemit-k3-cpufreq-performance.service \
                ultrarisc-dp1000-cpufreq-performance.service \
                tenstorrent-atlantis-cpufreq-performance.service; do
                if [[ -L "/etc/systemd/system/${unit_base}" || -f "/etc/systemd/system/${unit_base}" ]]; then
                    stop_disable_systemd_unit "$unit_base"
                    systemd_dirty="true"
                fi
            done

            local init_script
            for init_script in \
                /etc/init.d/rvdk-thp-tune \
                /etc/init.d/cve-2026-98432-guard \
                /etc/init.d/eic7700x-cpufreq \
                /etc/init.d/jh7110-cpufreq \
                /etc/init.d/fu740-cpufreq \
                /etc/init.d/spacemit-k1-cpufreq \
                /etc/init.d/spacemit-k3-cpufreq \
                /etc/init.d/ultrarisc-dp1000-cpufreq \
                /etc/init.d/tenstorrent-atlantis-cpufreq; do
                stop_disable_openwrt_init "$init_script"
            done

            if [[ -f /etc/systemd/system/nftables.service.d/90-rvdk-cve-2026-98432.conf ]]; then
                remove_path "/etc/systemd/system/nftables.service.d/90-rvdk-cve-2026-98432.conf"
                [[ "$dry_run" != "true" ]] && rmdir /etc/systemd/system/nftables.service.d 2>/dev/null || true
                systemd_dirty="true"
            fi

            if [[ -f /etc/systemd/journald.conf.d/90-rvdk-deeptune.conf ]]; then
                remove_path "/etc/systemd/journald.conf.d/90-rvdk-deeptune.conf"
                [[ "$dry_run" != "true" ]] && rmdir /etc/systemd/journald.conf.d 2>/dev/null || true
                systemd_dirty="true"
            fi

            remove_path "/etc/nftables.d/10-cve-2026-98432.nft"
            remove_path "/etc/nftables.d/cve-2026-98432.nft"
            remove_path "/etc/cve-2026-98432.nft"
            if command -v nft >/dev/null 2>&1 && nft list table ip cve_2026_98432 >/dev/null 2>&1; then
                if [[ "$dry_run" == "true" ]]; then
                    log_info "[DRY-RUN] Would flush & delete nftables table: ip cve_2026_98432"
                else
                    nft delete table ip cve_2026_98432 2>/dev/null || true
                    log_ok "Deleted live nftables table: ip cve_2026_98432"
                fi
            fi

            local sc_file
            for sc_file in \
                /etc/sysctl.d/89-rvdk-io-uring.conf \
                /etc/sysctl.d/90-rvdk-*.conf \
                /etc/sysctl.d/95-rvdk-deeptune.conf \
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
                /etc/apt/apt.conf.d/90-p550-bsp-protect \
                /etc/apt/apt.conf.d/90-starfive-bsp-protect \
                /etc/apt/apt.conf.d/90-spacemit-bsp-protect \
                /etc/apt/apt.conf.d/90-sifive-fu740-bsp-protect \
                /etc/apt/apt.conf.d/90-ultrarisc-bsp-protect \
                /etc/apt/apt.conf.d/90-tenstorrent-bsp-protect \
                /etc/apt/sources.list.d/rvdk-local-pgdg.list; do
                [[ -e "$mp_file" || -L "$mp_file" ]] && remove_path "$mp_file"
            done
        fi

        remove_path "/etc/rvdk"
        remove_path "/var/lib/rvdk"

        if [[ "$dry_run" != "true" && "$os_type" == "Linux" ]]; then
            if [[ "$systemd_dirty" == "true" ]] && command -v systemctl >/dev/null 2>&1; then
                systemctl daemon-reload >/dev/null 2>&1 || true
            fi
            if [[ "$sysctl_dirty" == "true" ]] && command -v sysctl >/dev/null 2>&1; then
                sysctl --system >/dev/null 2>&1 || true
            fi
        fi
    else
        if [[ -d /etc/rvdk || -d /var/lib/rvdk ]]; then
            log_skip "Preserved /etc/rvdk & /var/lib/rvdk (pass '--purge' to remove state & tuning drop-ins)"
        fi
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_ok "Dry-run complete (${removed_count} item(s) matched)."
    elif (( removed_count == 0 )); then
        log_skip "RVDK artifacts already absent; nothing to remove."
    else
        log_ok "RVDK uninstall complete (${removed_count} item(s) removed)."
    fi
}

main "$@"; exit 0
