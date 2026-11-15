#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Utility: Factory Default User Migration & Purge
# Path: riscv-data-kit/utils/purge-user.sh
#
# Description:
#   1. Migrates /home/<target>/.rvdk/ (engine, cache, config.env) and any
#      caller-specified --extra-dotdir directories into the destination admin
#      user's home directory, updating /usr/local/bin/rvdk (and any --relink-bin
#      symlinks) if they pointed into /home/<target>/.
#   2. Terminates lingering sessions/processes for <target>, removes sudoers
#      drop-ins, and purges the <target> user account + home directory.
#
# Usage:
#   sudo rvdk utils/purge-user.sh <target_user> [--to-user <admin_user>] [--overwrite-env]
#       [--extra-dotdir <rel_dir>] [--relink-bin <symlink_path>:<dest_rel_target>]
#       [--mount-point <path>]
# ==============================================================================

# Ensure compatibility when invoked via `zsh` or `bash`
if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L ksh
    setopt PIPE_FAIL ERR_RETURN NO_UNSET
else
    set -Eeuo pipefail
fi

main() {
    local script_self="${BASH_SOURCE[0]:-}"
    if [[ $EUID -ne 0 ]]; then
        if [[ -n "$script_self" && -f "$script_self" ]]; then
            exec sudo -E bash "$script_self" "$@"
        else
            echo "[RVDK:FATAL] Run as root: sudo rvdk utils/purge-user.sh <target_user>" >&2
            exit 1
        fi
    fi

    log_info()  { printf "\033[1;36m[RVDK:PURGE]\033[0m %s\n" "$1"; }
    log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
    log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
    log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
    log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_fatal "purge-user.sh is only supported on Linux target nodes (detected $(uname -s))."
    fi

    cd /

    local caller_user="${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo root)}"
    local target_user=""
    local dest_user=""
    local overwrite_env="false"
    local cli_mount_pt=""
    local extra_dotdirs=()
    local relink_bins=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                target_user="${2:-}"
                shift 2
                ;;
            --to-user|--dest-user)
                dest_user="${2:-}"
                shift 2
                ;;
            --overwrite-env)
                overwrite_env="true"
                shift
                ;;
            --extra-dotdir|--migrate-dotdir)
                [[ -n "${2:-}" ]] && extra_dotdirs+=("${2#/}")
                shift 2
                ;;
            --relink-bin)
                [[ -n "${2:-}" ]] && relink_bins+=("$2")
                shift 2
                ;;
            --mount-point)
                cli_mount_pt="${2:-}"
                shift 2
                ;;
            -h|--help)
                cat <<EOF
Usage: sudo rvdk utils/purge-user.sh <target_user> [options]

Options:
  --to-user <admin_user>              Destination admin user (defaults to invoking sudo user)
  --overwrite-env                     Overwrite existing *.env files in destination dotdirs
  --extra-dotdir <rel_dir>            Additional home dot-directory to migrate (repeatable)
  --relink-bin <bin_path>:<rel_path>  Re-point symlink if targeting purged user's home (repeatable)
  --mount-point <path>                Data mount root for nfs_vault ownership transfer

Migrates /home/<target_user>/.rvdk (and any --extra-dotdir directories) into the
destination user's home directory, then deletes <target_user>.
EOF
                exit 0
                ;;
            -*)
                log_fatal "Unknown option: $1"
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
        root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|nobody|systemd-*|postgres|mosquitto|_*)
            log_fatal "Safety Interlock: Refusing to purge protected system user '${target_user}'."
            ;;
    esac

    if [[ ! "$target_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log_fatal "Invalid POSIX username: '${target_user}'."
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

    log_info "Migrating state from ${src_home} -> ${dest_home} (owner: ${dest_user}:${dest_grp})..."

    # 1. Migrate .rvdk (engine, cache, config.env) so /usr/local/bin/rvdk stays valid
    if [[ -d "${src_home}/.rvdk" ]]; then
        install -d -m 0755 -o "$dest_user" -g "$dest_grp" "${dest_home}/.rvdk" "${dest_home}/.rvdk/cache"

        if [[ -f "${src_home}/.rvdk/config.env" ]] && [[ ! -f "${dest_home}/.rvdk/config.env" || "$overwrite_env" == "true" ]]; then
            cp -a "${src_home}/.rvdk/config.env" "${dest_home}/.rvdk/config.env"
            chown "${dest_user}:${dest_grp}" "${dest_home}/.rvdk/config.env"
            chmod 0640 "${dest_home}/.rvdk/config.env"
            log_ok "Migrated config.env -> ${dest_home}/.rvdk/config.env"
        fi

        if [[ -d "${src_home}/.rvdk/cache" ]]; then
            for cfile in "${src_home}/.rvdk/cache/"*; do
                [[ -e "$cfile" ]] || continue
                local cbase
                cbase="$(basename "$cfile")"
                if [[ ! -e "${dest_home}/.rvdk/cache/${cbase}" ]]; then
                    cp -a "$cfile" "${dest_home}/.rvdk/cache/${cbase}"
                fi
            done
            chown -R "${dest_user}:${dest_grp}" "${dest_home}/.rvdk/cache"
        fi

        if [[ -d "${src_home}/.rvdk/engine/.git" && ! -d "${dest_home}/.rvdk/engine/.git" ]]; then
            cp -a "${src_home}/.rvdk/engine" "${dest_home}/.rvdk/engine"
            chown -R "${dest_user}:${dest_grp}" "${dest_home}/.rvdk/engine"
            log_ok "Migrated RVDK engine -> ${dest_home}/.rvdk/engine"
        fi
    fi

    if [[ -L /usr/local/bin/rvdk ]]; then
        local rvdk_target
        rvdk_target="$(readlink -f /usr/local/bin/rvdk 2>/dev/null || true)"
        if [[ "$rvdk_target" == "${src_home}/"* && -f "${dest_home}/.rvdk/engine/bootstrap.sh" ]]; then
            ln -sf "${dest_home}/.rvdk/engine/bootstrap.sh" /usr/local/bin/rvdk
            log_ok "Re-linked /usr/local/bin/rvdk -> ${dest_home}/.rvdk/engine/bootstrap.sh"
        fi
    fi

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
                    cp -a "$entry" "${d_dir}/${ebase}"
                    sed -i "s/^ADMIN_USER=\"${target_user}\"/ADMIN_USER=\"${dest_user}\"/" "${d_dir}/${ebase}" 2>/dev/null || true
                    chown "${dest_user}:${dest_grp}" "${d_dir}/${ebase}"
                    chmod 0640 "${d_dir}/${ebase}"
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

    # Re-own fallback NFS vault directory if it was originally created under target_uid
    local mount_pt="${cli_mount_pt:-}"
    if [[ -z "$mount_pt" ]]; then
        local env_cand="${RVDK_ENV_FILE:-${dest_home}/.rvdk/config.env}"
        if [[ -f "$env_cand" ]]; then
            mount_pt="$(awk -F= '/^MOUNT_POINT=/ {gsub(/"|\047/, "", $2); print $2}' "$env_cand" 2>/dev/null || true)"
        fi
    fi
    mount_pt="${mount_pt:-/mnt/nvme_pgdata}"

    if [[ -n "$target_uid" && -d "${mount_pt}/nfs_vault" ]]; then
        if [[ "$(stat -c '%u' "${mount_pt}/nfs_vault" 2>/dev/null || echo "")" == "$target_uid" ]]; then
            chown -R "${dest_user}:${dest_grp}" "${mount_pt}/nfs_vault"
            log_ok "Transferred ownership of ${mount_pt}/nfs_vault -> ${dest_user}:${dest_grp}"
        fi
    fi

    # 3. Terminate lingering processes, remove sudoers rules, and delete target_user
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
