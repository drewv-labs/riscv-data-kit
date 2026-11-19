#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Utility: Factory Default User Migration & Purge
# Path: riscv-data-kit/utils/purge-user.sh
#
# Description:
#   1. Promotes any legacy /home/<target>/.rvdk/ artifacts (config.env, cache,
#      engine) into system space (/etc/rvdk, /var/cache/rvdk,
#      /usr/local/share/rvdk/engine) and migrates any caller-specified
#      --extra-dotdir user-space directories into the destination admin user's
#      home directory, updating /usr/bin/rvdk, /usr/local/bin/rvdk, and any
#      --relink-bin symlinks if they pointed into /home/<target>/.
#   2. Safely transfers ownership of files owned by <target>'s UID across
#      mounted data volumes (/mnt/*, /srv/*, or --reown-path) without clobbering
#      system/service subtrees (e.g. postgres, mosquitto).
#   3. Terminates lingering sessions/processes for <target>, removes sudoers
#      drop-ins, and purges the <target> user account + home directory.
#
# Usage:
#   sudo rvdk utils/purge-user.sh <target_user> [--to-user <admin_user>] [--overwrite-env]
#       [--extra-dotdir <rel_dir>] [--relink-bin <symlink_path>:<dest_rel_target>]
#       [--reown-path <dir>]
# ==============================================================================

# Ensure compatibility when invoked via `zsh` or `bash`
if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L ksh
    setopt PIPE_FAIL ERR_RETURN NO_UNSET
else
    set -Eeuo pipefail
fi

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
        log_info()  { printf "\033[1;36m[RVDK:PURGE]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_sanitize_locale() { export LANG=C LC_ALL=C; }
        rvdk_resolve_caller() { REAL_USER="${SUDO_USER:-root}"; }
        rvdk_validate_username() { [[ "${1:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
        rvdk_kv_load() { :; }
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

print_purge_help() {
    cat <<'EOF'
Usage: sudo rvdk utils/purge-user.sh <target_user> [options]

Options:
  --to-user <admin_user>              Destination admin user (defaults to invoking sudo user)
  --overwrite-env                     Overwrite existing *.env files in destination dotdirs
  --extra-dotdir <rel_dir>            User-space home dot-directory to migrate (repeatable)
  --relink-bin <bin_path>:<rel_path>  Re-point symlink if targeting purged user's home (repeatable)
  --reown-path <path>                 Additional directory tree to re-own from <target_user> (repeatable)

Promotes any legacy /home/<target_user>/.rvdk artifacts into system space (/etc/rvdk,
/var/cache/rvdk, /usr/local/share/rvdk/engine), migrates caller-requested --extra-dotdir
user-space directories into the destination user's home, re-owns data files belonging to
<target_user>'s UID on local mounted volumes (/mnt/*, /srv/*), and deletes <target_user>.
EOF
}

main() {
    rvdk_log_init "RVDK:PURGE"

    local arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                print_purge_help
                exit 0
                ;;
        esac
    done

    local script_self="${BASH_SOURCE[0]:-}"
    rvdk_require_root "$script_self" "$@"
    rvdk_sanitize_locale
    rvdk_resolve_caller

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_fatal "purge-user.sh is only supported on Linux target nodes (detected $(uname -s))."
    fi

    cd /

    local caller_user="$REAL_USER"
    local target_user=""
    local dest_user=""
    local overwrite_env="false"
    local reown_paths=()
    local extra_dotdirs=()
    local relink_bins=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                [[ -z "${2:-}" || "${2:-}" == --* ]] && log_fatal "Option '$1' requires a username."
                target_user="$2"
                shift 2
                ;;
            --to-user|--dest-user)
                [[ -z "${2:-}" || "${2:-}" == --* ]] && log_fatal "Option '$1' requires a username."
                dest_user="$2"
                shift 2
                ;;
            --overwrite-env)
                overwrite_env="true"
                shift
                ;;
            --extra-dotdir|--migrate-dotdir)
                [[ -z "${2:-}" || "${2:-}" == --* ]] && log_fatal "Option '$1' requires a relative directory."
                extra_dotdirs+=("${2#/}")
                shift 2
                ;;
            --relink-bin)
                [[ -z "${2:-}" || "${2:-}" == --* ]] && log_fatal "Option '$1' requires <bin_path>:<rel_path>."
                relink_bins+=("$2")
                shift 2
                ;;
            --reown-path|--mount|--mount-point|--nfs-mount|--secondary-mount)
                [[ -z "${2:-}" || "${2:-}" == --* ]] && log_fatal "Option '$1' requires a path."
                reown_paths+=("$2")
                shift 2
                ;;
            -*)
                log_fatal "Unknown option: $1 (try --help)"
                ;;
            *)
                if [[ -z "$target_user" ]]; then
                    target_user="$1"
                else
                    log_fatal "Unexpected positional argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -z "$target_user" ]] && log_fatal "Missing target username. Usage: sudo rvdk utils/purge-user.sh <target_user>"
    dest_user="${dest_user:-$caller_user}"

    # Safety Interlocks
    case "$target_user" in
        root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|nobody|systemd-*|postgres|mosquitto|ntfy|_* )
            log_fatal "Safety Interlock: Refusing to purge protected system user '${target_user}'."
            ;;
    esac

    if ! rvdk_validate_username "$target_user"; then
        log_fatal "Invalid POSIX username: '${target_user}'."
    fi
    if ! rvdk_validate_username "$dest_user"; then
        log_fatal "Invalid destination POSIX username: '${dest_user}'."
    fi

    if [[ "$target_user" == "$dest_user" || "$target_user" == "$caller_user" ]]; then
        log_fatal "Safety Interlock: Cannot purge '${target_user}' while running from '${caller_user}' (destination: '${dest_user}'). Log in as your admin user first."
    fi

    local target_exists="false"
    local target_uid=""
    if id -u "$target_user" >/dev/null 2>&1; then
        target_exists="true"
        target_uid="$(id -u "$target_user")"
        if (( target_uid < 1000 )); then
            log_fatal "Safety Interlock: Refusing to purge UID ${target_uid} (< 1000) for '${target_user}'."
        fi
    fi

    local src_home=""
    if [[ "$target_exists" == "true" ]]; then
        src_home="$(getent passwd "$target_user" 2>/dev/null | cut -d: -f6 || true)"
    fi
    [[ -z "$src_home" ]] && src_home="/home/${target_user}"

    if [[ "$target_exists" == "false" && ! -d "$src_home" ]]; then
        log_skip "User '${target_user}' and ${src_home} are already absent; nothing to purge."
        exit 0
    fi

    if ! id -u "$dest_user" >/dev/null 2>&1; then
        log_fatal "Destination user '${dest_user}' does not exist on this system."
    fi

    local dest_grp
    dest_grp="$(id -gn "$dest_user" 2>/dev/null || echo "$dest_user")"
    local dest_home
    dest_home="$(getent passwd "$dest_user" 2>/dev/null | cut -d: -f6 || true)"
    [[ -z "$dest_home" ]] && dest_home="/home/${dest_user}"

    log_info "Migrating user-space state from ${src_home} -> ${dest_home} (owner: ${dest_user}:${dest_grp})..."

    # 1. Promote any legacy ${src_home}/.rvdk artifacts into system space
    #    (/etc/rvdk, /var/cache/rvdk, /usr/local/share/rvdk/engine) — zero ~/.rvdk in dest_home!
    local sys_engine="${RVDK_ENGINE_DIR:-/usr/local/share/rvdk/engine}"
    local sys_cache="${RVDK_CACHE_DIR:-/var/cache/rvdk}"
    if [[ -d "${src_home}/.rvdk" ]]; then
        if [[ -f "${src_home}/.rvdk/config.env" ]] && [[ ! -f /etc/rvdk/config.env || "$overwrite_env" == "true" ]]; then
            install -d -m 0755 -o root -g root /etc/rvdk
            rvdk_atomic_write /etc/rvdk/config.env 0640 "0:0" < "${src_home}/.rvdk/config.env"
            log_ok "Promoted legacy config.env -> /etc/rvdk/config.env"
        fi

        if [[ -d "${src_home}/.rvdk/cache" ]]; then
            install -d -m 0755 -o root -g root "$sys_cache"
            local cfile cbase
            for cfile in "${src_home}/.rvdk/cache/"*; do
                [[ -e "$cfile" ]] || continue
                cbase="$(basename "$cfile")"
                if [[ ! -e "${sys_cache}/${cbase}" ]]; then
                    cp -a "$cfile" "${sys_cache}/${cbase}"
                    chown -R 0:0 "${sys_cache}/${cbase}"
                fi
            done
        fi

        if [[ -d "${src_home}/.rvdk/engine/.git" && ! -d "${sys_engine}/.git" ]]; then
            install -d -m 0755 -o root -g root "$(dirname "$sys_engine")"
            chmod 0755 /usr/local /usr/local/share "$(dirname "$sys_engine")" 2>/dev/null || true
            rm -rf "$sys_engine"
            cp -a "${src_home}/.rvdk/engine" "$sys_engine"
            chown -R 0:0 "$sys_engine"
            chmod -R a+rX "$sys_engine"
            chmod 0755 "$sys_engine"
            log_ok "Promoted legacy RVDK engine -> ${sys_engine}"
        fi
    fi

    local bin_link rvdk_target
    for bin_link in /usr/local/bin/rvdk /usr/bin/rvdk; do
        if [[ -L "$bin_link" ]]; then
            rvdk_target="$(readlink -f "$bin_link" 2>/dev/null || true)"
            if [[ "$rvdk_target" == "${src_home}/"* && -f "${sys_engine}/bootstrap.sh" ]]; then
                ln -sf "${sys_engine}/bootstrap.sh" /usr/local/bin/rvdk
                [[ -d /usr/bin ]] && ln -sf "${sys_engine}/bootstrap.sh" /usr/bin/rvdk 2>/dev/null || true
                log_ok "Re-linked /usr/bin/rvdk & /usr/local/bin/rvdk -> ${sys_engine}/bootstrap.sh"
                break
            fi
        fi
    done

    # 2. Migrate any caller-requested --extra-dotdir directories & --relink-bin symlinks
    local ddir
    for ddir in ${extra_dotdirs[@]+"${extra_dotdirs[@]}"}; do
        [[ -z "$ddir" || "$ddir" == *".."* ]] && continue
        local s_dir="${src_home}/${ddir}"
        local d_dir="${dest_home}/${ddir}"
        [[ -d "$s_dir" ]] || continue

        install -d -m 0750 -o "$dest_user" -g "$dest_grp" "$d_dir"
        local entry ebase
        for entry in "${s_dir}/"*; do
            [[ -e "$entry" ]] || continue
            ebase="$(basename "$entry")"
            if [[ -f "$entry" && "$ebase" == *.env ]]; then
                if [[ ! -f "${d_dir}/${ebase}" || "$overwrite_env" == "true" ]]; then
                    rvdk_atomic_write "${d_dir}/${ebase}" 0640 "${dest_user}:${dest_grp}" < "$entry"
                    log_ok "Migrated ${ddir}/${ebase} -> ${d_dir}/${ebase}"
                else
                    log_skip "Preserved existing ${d_dir}/${ebase}"
                fi
            elif [[ -d "$entry" && -d "${entry}/.git" ]]; then
                if [[ ! -d "${d_dir}/${ebase}/.git" ]]; then
                    cp -a "$entry" "${d_dir}/${ebase}"
                    chown -R "${dest_user}:${dest_grp}" "${d_dir}/${ebase}"
                    log_ok "Migrated git tree -> ${d_dir}/${ebase}"
                fi
            elif [[ -d "$entry" ]]; then
                install -d -m 0750 -o "$dest_user" -g "$dest_grp" "${d_dir}/${ebase}"
                local subf sbase copied_cnt=0
                for subf in "${entry}/"*; do
                    [[ -e "$subf" ]] || continue
                    sbase="$(basename "$subf")"
                    if [[ ! -e "${d_dir}/${ebase}/${sbase}" ]]; then
                        cp -a "$subf" "${d_dir}/${ebase}/${sbase}"
                        copied_cnt=$(( copied_cnt + 1 ))
                    fi
                done
                chown -R "${dest_user}:${dest_grp}" "${d_dir}/${ebase}"
                if (( copied_cnt > 0 )); then
                    log_ok "Migrated ${copied_cnt} item(s) -> ${d_dir}/${ebase}/"
                fi
            elif [[ ! -e "${d_dir}/${ebase}" ]]; then
                cp -a "$entry" "${d_dir}/${ebase}"
                chown -R "${dest_user}:${dest_grp}" "${d_dir}/${ebase}"
            fi
        done
    done

    local rspec r_bin r_rel r_cur
    for rspec in ${relink_bins[@]+"${relink_bins[@]}"}; do
        r_bin="${rspec%%:*}"
        r_rel="${rspec#*:}"
        [[ -z "$r_bin" || -z "$r_rel" || "$r_bin" == "$r_rel" ]] && continue
        if [[ -L "$r_bin" ]]; then
            r_cur="$(readlink -f "$r_bin" 2>/dev/null || true)"
            if [[ "$r_cur" == "${src_home}/"* && -f "${dest_home}/${r_rel#/}" ]]; then
                ln -sf "${dest_home}/${r_rel#/}" "$r_bin"
                log_ok "Re-linked ${r_bin} -> ${dest_home}/${r_rel#/}"
            fi
        fi
    done

    # 3. Safely transfer ownership of UID-matched files on configured or mounted local data volumes
    if [[ -n "$target_uid" ]]; then
        local MOUNT_POINT="" SECONDARY_MOUNT_POINT="" NFS_MOUNT_POINT=""
        local env_cand="${RVDK_ENV_FILE:-/etc/rvdk/config.env}"
        if [[ -r "$env_cand" ]]; then
            rvdk_kv_load "$env_cand" MOUNT_POINT SECONDARY_MOUNT_POINT NFS_MOUNT_POINT
        fi
        [[ -n "$MOUNT_POINT" ]] && reown_paths+=("$MOUNT_POINT")
        [[ -n "$SECONDARY_MOUNT_POINT" ]] && reown_paths+=("$SECONDARY_MOUNT_POINT")
        [[ -n "$NFS_MOUNT_POINT" ]] && reown_paths+=("$NFS_MOUNT_POINT")

        if [[ -r /proc/mounts ]]; then
            local m_pt m_fs
            while read -r _ m_pt m_fs _; do
                case "$m_fs" in
                    xfs|ext4|ext3|btrfs|f2fs)
                        case "$m_pt" in
                            /mnt/*|/srv/*) reown_paths+=("$m_pt") ;;
                        esac
                        ;;
                esac
            done < /proc/mounts
        fi

        local seen_paths=" "
        local vdir
        for vdir in ${reown_paths[@]+"${reown_paths[@]}"}; do
            [[ -n "$vdir" && -d "$vdir" ]] || continue
            [[ "$vdir" == "/" || "$vdir" == "/home" || "$vdir" == "$src_home" ]] && continue
            [[ "$seen_paths" == *"|${vdir}|"* ]] && continue
            seen_paths="${seen_paths}|${vdir}|"

            if find "$vdir" -xdev -user "$target_uid" -print -quit 2>/dev/null | grep -q .; then
                find "$vdir" -xdev -user "$target_uid" -exec chown -h "${dest_user}:${dest_grp}" {} +
                log_ok "Transferred UID ${target_uid} files under ${vdir} -> ${dest_user}:${dest_grp}"
            fi
        done
    fi

    # 4. Terminate lingering processes, remove sudoers rules, and delete target_user
    if [[ -n "$target_uid" ]]; then
        loginctl disable-linger "$target_user" 2>/dev/null || true
        loginctl terminate-user "$target_user" 2>/dev/null || true
        systemctl stop "user@${target_uid}.service" "user-runtime-dir@${target_uid}.service" 2>/dev/null || true
        pkill -KILL -u "$target_uid" 2>/dev/null || true
        sleep 1
    fi

    rm -f "/etc/sudoers.d/010_${target_user}-nopasswd" \
          "/etc/sudoers.d/90-cloud-init-users-${target_user}" \
          "/etc/sudoers.d/${target_user}" 2>/dev/null || true

    if [[ "$target_exists" == "true" ]]; then
        userdel -r -f "$target_user" 2>/dev/null || \
        deluser --remove-home "$target_user" 2>/dev/null || \
        userdel -f "$target_user"
    fi

    if [[ -d "$src_home" && "$src_home" == /home/* ]]; then
        rm -rf "$src_home"
    fi

    log_ok "Purged user '${target_user}' and removed ${src_home}"
}

main "$@"
