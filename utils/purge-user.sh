#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Utility: Factory Default User Migration & Purge
# Path: riscv-data-kit/utils/purge-user.sh
#
# Description:
#   1. Copies /home/<target>/.brakerrak/ (node.env, snapshots, engine) and
#      /home/<target>/.rvdk/ (engine, cache) into the active admin user's home,
#      updating /usr/local/bin/{rvdk,brakerrak} symlinks if they pointed into
#      /home/<target>/.
#   2. Terminates lingering sessions/processes for <target>, removes sudoers
#      drop-ins, and purges the <target> user account + home directory.
#
# Usage:
#   sudo rvdk utils/purge-user.sh <target_user> [--to-user <admin_user>] [--overwrite-env]
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
            -h|--help)
                cat <<EOF
Usage: sudo rvdk utils/purge-user.sh <target_user> [--to-user <admin_user>] [--overwrite-env]

Migrates /home/<target_user>/.brakerrak (node.env, snapshots, engine) and
/home/<target_user>/.rvdk into ~/.brakerrak and ~/.rvdk, then deletes <target_user>.
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

    # 1. Migrate .brakerrak (node.env, snapshots, engine)
    if [[ -d "${src_home}/.brakerrak" ]]; then
        install -d -m 0750 -o "$dest_user" -g "$dest_grp" "${dest_home}/.brakerrak" "${dest_home}/.brakerrak/snapshots"

        if [[ -f "${src_home}/.brakerrak/node.env" ]]; then
            if [[ ! -f "${dest_home}/.brakerrak/node.env" || "$overwrite_env" == "true" ]]; then
                cp -a "${src_home}/.brakerrak/node.env" "${dest_home}/.brakerrak/node.env"
                sed -i "s/^ADMIN_USER=\"${target_user}\"/ADMIN_USER=\"${dest_user}\"/" "${dest_home}/.brakerrak/node.env" 2>/dev/null || true
                chown "${dest_user}:${dest_grp}" "${dest_home}/.brakerrak/node.env"
                chmod 0640 "${dest_home}/.brakerrak/node.env"
                log_ok "Migrated node.env -> ${dest_home}/.brakerrak/node.env"
            else
                log_skip "Preserved existing ${dest_home}/.brakerrak/node.env"
            fi
        fi

        if [[ -d "${src_home}/.brakerrak/snapshots" ]]; then
            local copied_snaps=0
            for sfile in "${src_home}/.brakerrak/snapshots/"*; do
                [[ -e "$sfile" ]] || continue
                local sbase
                sbase="$(basename "$sfile")"
                if [[ ! -e "${dest_home}/.brakerrak/snapshots/${sbase}" ]]; then
                    cp -a "$sfile" "${dest_home}/.brakerrak/snapshots/${sbase}"
                    copied_snaps=$(( copied_snaps + 1 ))
                fi
            done
            chown -R "${dest_user}:${dest_grp}" "${dest_home}/.brakerrak/snapshots"
            if (( copied_snaps > 0 )); then
                log_ok "Migrated ${copied_snaps} snapshot file(s) -> ${dest_home}/.brakerrak/snapshots/"
            else
                log_skip "No new snapshots to migrate from ${src_home}/.brakerrak/snapshots/"
            fi
        fi

        if [[ -d "${src_home}/.brakerrak/engine/.git" && ! -d "${dest_home}/.brakerrak/engine/.git" ]]; then
            cp -a "${src_home}/.brakerrak/engine" "${dest_home}/.brakerrak/engine"
            chown -R "${dest_user}:${dest_grp}" "${dest_home}/.brakerrak/engine"
            log_ok "Migrated BrakerRak engine -> ${dest_home}/.brakerrak/engine"
        fi
    fi

    if [[ -L /usr/local/bin/brakerrak ]]; then
        local brak_target
        brak_target="$(readlink -f /usr/local/bin/brakerrak 2>/dev/null || true)"
        if [[ "$brak_target" == "${src_home}/"* && -f "${dest_home}/.brakerrak/engine/forge.sh" ]]; then
            ln -sf "${dest_home}/.brakerrak/engine/forge.sh" /usr/local/bin/brakerrak
            log_ok "Re-linked /usr/local/bin/brakerrak -> ${dest_home}/.brakerrak/engine/forge.sh"
        fi
    fi

    # 2. Migrate .rvdk (engine & cache) so /usr/local/bin/rvdk stays valid
    if [[ -d "${src_home}/.rvdk" ]]; then
        install -d -m 0755 -o "$dest_user" -g "$dest_grp" "${dest_home}/.rvdk" "${dest_home}/.rvdk/cache"

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

    # Re-own fallback NFS vault directory if it was originally created under target_uid
    local mount_pt="/mnt/nvme_pgdata"
    if [[ -f "${dest_home}/.brakerrak/node.env" ]]; then
        local env_mp
        env_mp="$(awk -F= '/^MOUNT_POINT=/ {gsub(/"|\047/, "", $2); print $2}' "${dest_home}/.brakerrak/node.env" 2>/dev/null || true)"
        [[ -n "$env_mp" ]] && mount_pt="$env_mp"
    fi
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
