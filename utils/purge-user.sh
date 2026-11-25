#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Utility: Factory Default User Migration & Purge
# Path: riscv-data-kit/utils/purge-user.sh
#
# Description:
#   1. Migrates legacy /home/<target>/.rvdk/ caches (and optionally safe
#      allowlisted keys from config.env with --promote-legacy-config) into
#      system space (/etc/rvdk, /var/cache/rvdk) and migrates caller-specified
#      --extra-dotdir user-space directories into the destination admin user's
#      home directory, updating /usr/bin/rvdk, /usr/local/bin/rvdk (only when
#      a trusted root-owned system engine exists), and any --relink-bin
#      symlinks if they pointed into /home/<target>/.
#   2. Safely transfers ownership of files owned by <target>'s UID across
#      mounted data volumes (/mnt/*, /srv/*, or --reown-path) without clobbering
#      system/service subtrees (e.g. postgres, mosquitto).
#   3. Locks <target>, terminates lingering sessions/processes prior to reading
#      home state, removes sudoers drop-ins, and purges the <target> account +
#      home directory.
#
# Usage:
#   sudo rvdk utils/purge-user.sh <target_user> [--to-user <admin_user>] [--overwrite-env]
#       [--promote-legacy-config] [--extra-dotdir <rel_dir>]
#       [--relink-bin <symlink_path>:<dest_rel_target>] [--reown-path <dir>]
# ==============================================================================

# Re-exec under bash if invoked via zsh (requires a file path on disk)
if [[ -n "${ZSH_VERSION:-}" ]]; then
    case "${0:-}" in
        zsh|-zsh|*/zsh|*/-zsh|zsh[0-9]*|*/zsh[0-9]*) ;;
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
        rvdk_normalize_mount_path() {
            local p="${1:-}"
            while [[ "$p" != "/" && "$p" == */ ]]; do
                p="${p%/}"
            done
            printf '%s' "$p"
        }
        rvdk_kv_load() { :; }
        rvdk_kv_write() { :; }
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

if ! typeset -f rvdk_assert_safe_managed_dir >/dev/null 2>&1; then
    rvdk_assert_safe_managed_dir() {
        local raw_path="${1:-}"
        local var_name="${2:-PATH}"

        if [[ -z "$raw_path" || "$raw_path" != /* ]]; then
            log_fatal "Unsafe ${var_name}: '${raw_path}' must be a non-empty absolute path."
        fi
        if [[ "$raw_path" =~ [[:cntrl:]] ]]; then
            log_fatal "Unsafe ${var_name}: '${raw_path}' contains control characters."
        fi

        local norm="$raw_path"
        while [[ "$norm" == *//* ]]; do
            norm="${norm//\/\///}"
        done
        while [[ "$norm" != "/" && "$norm" == */ ]]; do
            norm="${norm%/}"
        done

        if [[ "$norm" == "/" ]]; then
            log_fatal "Unsafe ${var_name}: '${raw_path}' resolves to root '/'."
        fi

        local comp_count=0 seg rest="${norm#/}"
        while [[ -n "$rest" ]]; do
            if [[ "$rest" == */* ]]; then
                seg="${rest%%/*}"
                rest="${rest#*/}"
            else
                seg="$rest"
                rest=""
            fi
            [[ -z "$seg" ]] && continue
            if [[ "$seg" == "." || "$seg" == ".." ]]; then
                log_fatal "Unsafe ${var_name}: '${raw_path}' contains '.' or '..' traversal segment."
            fi
            comp_count=$(( comp_count + 1 ))
        done

        if [[ -L "$raw_path" || -L "$norm" ]]; then
            log_fatal "Unsafe ${var_name}: '${raw_path}' is a symbolic link."
        fi

        if (( comp_count < 2 )); then
            log_fatal "Unsafe ${var_name}: '${raw_path}' must have at least 2 path components."
        fi

        if [[ -n "${REAL_HOME:-}" ]]; then
            local norm_home="$REAL_HOME"
            while [[ "$norm_home" == *//* ]]; do
                norm_home="${norm_home//\/\///}"
            done
            while [[ "$norm_home" != "/" && "$norm_home" == */ ]]; do
                norm_home="${norm_home%/}"
            done
            if [[ "$norm" == "$norm_home" ]]; then
                log_fatal "Unsafe ${var_name}: '${raw_path}' resolves to user home '${norm_home}'."
            fi
        fi

        case "$norm" in
            /usr|/usr/local|/usr/local/share|/var|/var/cache|/var/lib|/etc|/home|/root|/opt|/tmp)
                log_fatal "Unsafe ${var_name}: '${raw_path}' is a protected system directory."
                ;;
        esac

        return 0
    }
fi

print_purge_help() {
    cat <<'EOF'
Usage: sudo rvdk utils/purge-user.sh <target_user> [options]

Options:
  --to-user <admin_user>              Destination admin user (defaults to invoking sudo user)
  --overwrite-env                     Overwrite existing *.env files (and /etc/rvdk/config.env when --promote-legacy-config is set)
  --promote-legacy-config             Import safe non-security keys from /home/<target>/.rvdk/config.env into /etc/rvdk/config.env
  --extra-dotdir <rel_dir>            User-space home dot-directory to migrate (repeatable)
  --relink-bin <bin_path>:<rel_path>  Re-point symlink if targeting purged user's home (repeatable)
  --reown-path <path>                 Additional directory tree to re-own from <target_user> (repeatable)

Locks <target_user>, migrates legacy /home/<target_user>/.rvdk caches (and safe
config.env keys when --promote-legacy-config is passed) into system space
(/etc/rvdk, /var/cache/rvdk), migrates caller-requested --extra-dotdir user-space
directories into the destination user's home, re-owns data files belonging to
<target_user>'s UID on local mounted volumes (/mnt/*, /srv/*), and deletes <target_user>.
EOF
}

# Validate that a normalized source home path strictly targets /home/<user>
# and rejects /home/, /home/., /home/.., nested paths, or non-/home paths.
rvdk_purge_validate_src_home() {
    local raw_home="${1:-}"
    local norm_home
    norm_home="$(rvdk_normalize_mount_path "$raw_home")"
    [[ -n "$norm_home" ]] || return 1
    [[ "$norm_home" =~ ^/home/[^/]+$ && "$norm_home" != "/home/." && "$norm_home" != "/home/.." ]]
}

# Verify that base_dir and every relative path component under it are free of symlinks
# and contain no '.' or '..' traversal segments.
rvdk_purge_path_is_symlink_free() {
    local base_dir="$1"
    local rel_path="${2:-}"
    [[ -n "$base_dir" && ! -L "$base_dir" ]] || return 1
    [[ -z "$rel_path" ]] && return 0

    local cur="$base_dir" seg
    local -a segs=()
    IFS='/' read -r -a segs <<< "$rel_path"
    for seg in ${segs[@]+"${segs[@]}"}; do
        [[ -z "$seg" ]] && continue
        [[ "$seg" == "." || "$seg" == ".." ]] && return 1
        cur="${cur}/${seg}"
        [[ ! -L "$cur" ]] || return 1
    done
    return 0
}

_rvdk_purge_validate_safe_kv() {
    local k="$1"
    local val="$2"
    [[ "$val" =~ [[:cntrl:]] ]] && return 1
    case "$k" in
        RVDK_TIMEZONE)
            [[ "$val" != *..* && "$val" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ ]]
            ;;
        RVDK_LOCALE)
            [[ "$val" =~ ^[A-Za-z0-9._-]+$ ]]
            ;;
        RVDK_BOARD|RVDK_SOC)
            [[ "$val" != *..* && "$val" != *. && "$val" =~ ^[a-z0-9][a-z0-9_-]*/[a-z0-9][a-z0-9._-]*$ ]]
            ;;
        RVDK_HOSTNAME)
            [[ ${#val} -ge 1 && ${#val} -le 253 && "$val" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
            ;;
        RVDK_TUNE)
            [[ "$val" == "data" || "$val" == "ai" ]]
            ;;
        MOUNT_POINT|SECONDARY_MOUNT_POINT|NFS_MOUNT_POINT)
            [[ "$val" != *..* && "$val" != */. && "$val" != */.. && "$val" =~ ^/(mnt|srv)/[A-Za-z0-9._-]+$ ]]
            ;;
        VG_NAME|LV_NAME|SECONDARY_LV_NAME|NFS_LV_NAME)
            [[ "$val" != "." && "$val" != ".." && "$val" != *..* && "$val" =~ ^[A-Za-z0-9._+-]+$ ]]
            ;;
        LV_PCT)
            [[ "$val" =~ ^[1-9][0-9]*%(VG|FREE|ORIGIN|PVS)$ || "$val" =~ ^[0-9]+$ ]]
            ;;
        PRIMARY_FSTYPE)
            [[ "$val" == "xfs" || "$val" == "ext4" || "$val" == "btrfs" ]]
            ;;
        FS_LABEL|SECONDARY_FS_LABEL|NFS_FS_LABEL)
            [[ "$val" =~ ^[A-Za-z0-9_.-]{1,16}$ ]]
            ;;
        DUAL_PRIMARY_PCT|DUAL_SECONDARY_PCT|DUAL_NFS_PCT|NFS_WORKERS|KERNEL_HUGEPAGES_2MB)
            [[ "$val" =~ ^[0-9]+$ ]]
            ;;
        USE_LVM|WITH_SECONDARY_LV|WITH_NFS_LV|NTFY_ENABLE_WEB)
            [[ "$val" == "true" || "$val" == "false" || "$val" == "0" || "$val" == "1" ]]
            ;;
        NFS_BACKEND)
            [[ "$val" == "kernel" || "$val" == "ganesha" ]]
            ;;
        MQTT_PORT|NTFY_PORT)
            [[ "$val" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$val <= 65535 ))
            ;;
        NTFY_CACHE_DURATION)
            [[ "$val" =~ ^[0-9]+[smhd]$ ]]
            ;;
        PG_SHARED_BUFFERS|PG_EFFECTIVE_CACHE_SIZE|PG_MAINT_WORK_MEM)
            [[ "$val" =~ ^[0-9]+(kB|MB|GB|TB)$ ]]
            ;;
        *)
            return 1
            ;;
    esac
}

_rvdk_purge_promote_legacy_config() {
    local legacy_cfg="$1"
    local src_home="$2"
    local -a safe_keys=(
        RVDK_TIMEZONE
        RVDK_LOCALE
        RVDK_BOARD
        RVDK_SOC
        RVDK_HOSTNAME
        RVDK_TUNE
        MOUNT_POINT
        SECONDARY_MOUNT_POINT
        NFS_MOUNT_POINT
        VG_NAME
        LV_NAME
        LV_PCT
        PRIMARY_FSTYPE
        FS_LABEL
        SECONDARY_LV_NAME
        NFS_LV_NAME
        SECONDARY_FS_LABEL
        NFS_FS_LABEL
        DUAL_PRIMARY_PCT
        DUAL_SECONDARY_PCT
        DUAL_NFS_PCT
        USE_LVM
        WITH_SECONDARY_LV
        WITH_NFS_LV
        NFS_WORKERS
        NFS_BACKEND
        MQTT_PORT
        NTFY_PORT
        NTFY_CACHE_DURATION
        NTFY_ENABLE_WEB
        KERNEL_HUGEPAGES_2MB
        PG_SHARED_BUFFERS
        PG_EFFECTIVE_CACHE_SIZE
        PG_MAINT_WORK_MEM
    )
    # shellcheck disable=SC2034
    local RVDK_TIMEZONE="" RVDK_LOCALE="" RVDK_BOARD="" RVDK_SOC="" RVDK_HOSTNAME="" RVDK_TUNE=""
    # shellcheck disable=SC2034
    local MOUNT_POINT="" SECONDARY_MOUNT_POINT="" NFS_MOUNT_POINT=""
    # shellcheck disable=SC2034
    local VG_NAME="" LV_NAME="" LV_PCT="" PRIMARY_FSTYPE="" FS_LABEL=""
    # shellcheck disable=SC2034
    local SECONDARY_LV_NAME="" NFS_LV_NAME="" SECONDARY_FS_LABEL="" NFS_FS_LABEL=""
    # shellcheck disable=SC2034
    local DUAL_PRIMARY_PCT="" DUAL_SECONDARY_PCT="" DUAL_NFS_PCT=""
    # shellcheck disable=SC2034
    local USE_LVM="" WITH_SECONDARY_LV="" WITH_NFS_LV=""
    # shellcheck disable=SC2034
    local NFS_WORKERS="" NFS_BACKEND=""
    # shellcheck disable=SC2034
    local MQTT_PORT=""
    # shellcheck disable=SC2034
    local NTFY_PORT="" NTFY_CACHE_DURATION="" NTFY_ENABLE_WEB=""
    # shellcheck disable=SC2034
    local KERNEL_HUGEPAGES_2MB="" PG_SHARED_BUFFERS="" PG_EFFECTIVE_CACHE_SIZE="" PG_MAINT_WORK_MEM=""

    rvdk_kv_load "$legacy_cfg" "${safe_keys[@]}"

    local -a kv_pairs=()
    local k val
    for k in "${safe_keys[@]}"; do
        val="${!k:-}"
        if [[ -n "$val" ]]; then
            if _rvdk_purge_validate_safe_kv "$k" "$val"; then
                kv_pairs+=("${k}=${val}")
            else
                log_warn "Skipped invalid legacy config key '${k}' in ${legacy_cfg}"
            fi
        fi
    done

    if [[ ${#kv_pairs[@]} -eq 0 ]]; then
        log_warn "No safe allowlisted keys found in ${legacy_cfg}; skipped writing /etc/rvdk/config.env"
        return 0
    fi

    install -d -m 0755 -o root -g root /etc/rvdk
    rvdk_kv_write /etc/rvdk/config.env 0640 "Promoted safe non-security keys from legacy ${src_home}/.rvdk/config.env" "${kv_pairs[@]}"
    chown 0:0 /etc/rvdk/config.env 2>/dev/null || true
    chmod 0640 /etc/rvdk/config.env 2>/dev/null || true
    log_ok "Promoted ${#kv_pairs[@]} safe key(s) from legacy config.env -> /etc/rvdk/config.env"
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
    local promote_legacy_config="false"
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
            --promote-legacy-config)
                promote_legacy_config="true"
                shift
                ;;
            --extra-dotdir|--migrate-dotdir)
                [[ -z "${2:-}" || "${2:-}" == --* ]] && log_fatal "Option '$1' requires a relative directory."
                extra_dotdirs+=("$(rvdk_normalize_mount_path "${2#/}")")
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
    src_home="$(rvdk_normalize_mount_path "$src_home")"

    if ! rvdk_purge_validate_src_home "$src_home"; then
        log_fatal "Safety Interlock: Refusing unsafe source home path '${src_home}' (must match /home/<user>)."
    fi
    if [[ -L "$src_home" ]]; then
        log_fatal "Safety Interlock: Refusing symlinked source home path '${src_home}'."
    fi

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
    dest_home="$(rvdk_normalize_mount_path "$dest_home")"

    local sys_engine="${RVDK_ENGINE_DIR:-/usr/local/share/rvdk/engine}"
    local sys_cache="${RVDK_CACHE_DIR:-/var/cache/rvdk}"
    rvdk_assert_safe_managed_dir "$sys_engine" "RVDK_ENGINE_DIR"
    rvdk_assert_safe_managed_dir "$sys_cache" "RVDK_CACHE_DIR"
    while [[ "$sys_engine" == *//* ]]; do sys_engine="${sys_engine//\/\///}"; done
    while [[ "$sys_cache" == *//* ]]; do sys_cache="${sys_cache//\/\///}"; done
    sys_engine="$(rvdk_normalize_mount_path "$sys_engine")"
    sys_cache="$(rvdk_normalize_mount_path "$sys_cache")"

    # Lock target account and terminate lingering sessions/processes BEFORE reading
    # any files under ${src_home} to prevent TOCTOU symlink-swap races.
    if [[ "$target_exists" == "true" && -n "$target_uid" && "$target_user" != "root" && "$target_user" != "$dest_user" ]]; then
        log_info "Locking '${target_user}' (UID ${target_uid}) and terminating active sessions..."
        usermod -L "$target_user" 2>/dev/null || passwd -l "$target_user" 2>/dev/null || true
        loginctl disable-linger "$target_user" 2>/dev/null || true
        loginctl terminate-user "$target_user" 2>/dev/null || true
        systemctl stop "user@${target_uid}.service" "user-runtime-dir@${target_uid}.service" 2>/dev/null || true
        pkill -KILL -u "$target_uid" 2>/dev/null || true
        sleep 1
    fi

    log_info "Migrating user-space state from ${src_home} -> ${dest_home} (owner: ${dest_user}:${dest_grp})..."

    # 1. Promote safe legacy ${src_home}/.rvdk artifacts into system space
    #    (/etc/rvdk, /var/cache/rvdk) — never promote untrusted user engines!
    if [[ -d "${src_home}/.rvdk" && ! -L "${src_home}/.rvdk" ]]; then
        if rvdk_purge_path_is_symlink_free "$src_home" ".rvdk/config.env" && \
           [[ -f "${src_home}/.rvdk/config.env" && ! -L "${src_home}/.rvdk/config.env" ]]; then
            if [[ "$promote_legacy_config" == "true" ]]; then
                if [[ ! -f /etc/rvdk/config.env || "$overwrite_env" == "true" ]]; then
                    _rvdk_purge_promote_legacy_config "${src_home}/.rvdk/config.env" "$src_home"
                else
                    log_skip "Preserved existing /etc/rvdk/config.env (pass --overwrite-env to replace)"
                fi
            else
                log_warn "Skipped legacy ${src_home}/.rvdk/config.env promotion (pass --promote-legacy-config to import safe non-security keys)."
            fi
        elif [[ -L "${src_home}/.rvdk/config.env" ]]; then
            log_warn "Skipped symlinked legacy config: ${src_home}/.rvdk/config.env"
        fi

        if rvdk_purge_path_is_symlink_free "$src_home" ".rvdk/cache" && \
           [[ -d "${src_home}/.rvdk/cache" && ! -L "${src_home}/.rvdk/cache" ]]; then
            install -d -m 0755 -o root -g root "$sys_cache"
            local cfile cbase
            for cfile in "${src_home}/.rvdk/cache/"*; do
                [[ -e "$cfile" && ! -L "$cfile" ]] || continue
                cbase="$(basename "$cfile")"
                if [[ ! -e "${sys_cache}/${cbase}" ]]; then
                    cp -a "$cfile" "${sys_cache}/${cbase}"
                    chown -R 0:0 "${sys_cache}/${cbase}"
                fi
            done
        fi

        if [[ -e "${src_home}/.rvdk/engine" || -L "${src_home}/.rvdk/engine" ]]; then
            log_warn "Skipped legacy user-owned engine at ${src_home}/.rvdk/engine: untrusted user engines are never promoted to root-owned system space. Reinstall via official install-cli.sh if needed."
        fi
    elif [[ -L "${src_home}/.rvdk" ]]; then
        log_warn "Skipped symlinked legacy state directory: ${src_home}/.rvdk"
    fi

    local sys_bootstrap="${sys_engine}/bootstrap.sh"
    local sys_bootstrap_trusted="false"
    if [[ -d "$sys_engine" && ! -L "$sys_engine" && -f "$sys_bootstrap" && ! -L "$sys_bootstrap" ]]; then
        local eng_uid boot_uid
        eng_uid="$(stat -c '%u' "$sys_engine" 2>/dev/null || stat -f '%u' "$sys_engine" 2>/dev/null || true)"
        boot_uid="$(stat -c '%u' "$sys_bootstrap" 2>/dev/null || stat -f '%u' "$sys_bootstrap" 2>/dev/null || true)"
        if [[ "$eng_uid" == "0" && "$boot_uid" == "0" ]]; then
            sys_bootstrap_trusted="true"
        fi
    fi

    local bin_link rvdk_target
    for bin_link in /usr/local/bin/rvdk /usr/bin/rvdk; do
        if [[ -L "$bin_link" ]]; then
            rvdk_target="$(readlink -f "$bin_link" 2>/dev/null || true)"
            if [[ "$rvdk_target" == "${src_home}/"* ]]; then
                if [[ "$sys_bootstrap_trusted" == "true" ]]; then
                    ln -sf "$sys_bootstrap" /usr/local/bin/rvdk
                    [[ -d /usr/bin ]] && ln -sf "$sys_bootstrap" /usr/bin/rvdk 2>/dev/null || true
                    log_ok "Re-linked /usr/bin/rvdk & /usr/local/bin/rvdk -> ${sys_bootstrap}"
                else
                    log_warn "Skipped re-linking ${bin_link} -> ${sys_bootstrap} (missing or not root-owned non-symlinked engine)."
                fi
                break
            fi
        fi
    done

    # 2. Migrate any caller-requested --extra-dotdir directories & --relink-bin symlinks
    local ddir
    for ddir in ${extra_dotdirs[@]+"${extra_dotdirs[@]}"}; do
        [[ -n "$ddir" ]] || continue
        if ! rvdk_purge_path_is_symlink_free "$src_home" "$ddir"; then
            log_warn "Skipped unsafe or symlinked extra dotdir: ${src_home}/${ddir}"
            continue
        fi
        local s_dir="${src_home}/${ddir}"
        local d_dir="${dest_home}/${ddir}"
        [[ -d "$s_dir" && ! -L "$s_dir" ]] || continue
        if ! rvdk_purge_path_is_symlink_free "$dest_home" "$ddir"; then
            log_warn "Skipped symlinked destination dotdir: ${d_dir}"
            continue
        fi

        install -d -m 0750 -o "$dest_user" -g "$dest_grp" "$d_dir"
        local entry ebase
        for entry in "${s_dir}/"*; do
            [[ -e "$entry" && ! -L "$entry" ]] || continue
            ebase="$(basename "$entry")"
            if [[ -f "$entry" && ! -L "$entry" && "$ebase" == *.env ]]; then
                if [[ -L "${d_dir}/${ebase}" ]]; then
                    log_warn "Skipped symlinked destination env file: ${d_dir}/${ebase}"
                elif [[ ! -f "${d_dir}/${ebase}" || "$overwrite_env" == "true" ]]; then
                    rvdk_atomic_write "${d_dir}/${ebase}" 0640 "${dest_user}:${dest_grp}" < "$entry"
                    log_ok "Migrated ${ddir}/${ebase} -> ${d_dir}/${ebase}"
                else
                    log_skip "Preserved existing ${d_dir}/${ebase}"
                fi
            elif [[ -d "$entry" && ! -L "$entry" && -d "${entry}/.git" && ! -L "${entry}/.git" ]]; then
                if [[ ! -d "${d_dir}/${ebase}/.git" ]]; then
                    cp -a "$entry" "${d_dir}/${ebase}"
                    chown -R "${dest_user}:${dest_grp}" "${d_dir}/${ebase}"
                    log_ok "Migrated git tree -> ${d_dir}/${ebase}"
                fi
            elif [[ -d "$entry" && ! -L "$entry" ]]; then
                [[ -L "${d_dir}/${ebase}" ]] && continue
                install -d -m 0750 -o "$dest_user" -g "$dest_grp" "${d_dir}/${ebase}"
                local subf sbase copied_cnt=0
                for subf in "${entry}/"*; do
                    [[ -e "$subf" && ! -L "$subf" ]] || continue
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
            elif [[ ! -L "$entry" && ! -e "${d_dir}/${ebase}" ]]; then
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
        if [[ -f "$env_cand" && ! -L "$env_cand" && -r "$env_cand" ]]; then
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
            vdir="$(rvdk_normalize_mount_path "$vdir")"
            [[ -n "$vdir" && -d "$vdir" && ! -L "$vdir" ]] || continue
            [[ "$vdir" == "/" || "$vdir" == "/home" || "$vdir" == "$src_home" ]] && continue
            [[ "$seen_paths" == *"|${vdir}|"* ]] && continue
            seen_paths="${seen_paths}|${vdir}|"

            if find "$vdir" -xdev -user "$target_uid" -print -quit 2>/dev/null | grep -q .; then
                find "$vdir" -xdev -user "$target_uid" -exec chown -h "${dest_user}:${dest_grp}" {} +
                log_ok "Transferred UID ${target_uid} files under ${vdir} -> ${dest_user}:${dest_grp}"
            fi
        done
    fi

    # 4. Remove sudoers rules and delete target_user (already locked/terminated before Step 1)
    if [[ -n "$target_uid" ]]; then
        pkill -KILL -u "$target_uid" 2>/dev/null || true
    fi

    rm -f "/etc/sudoers.d/010_${target_user}-nopasswd" \
          "/etc/sudoers.d/90-cloud-init-users-${target_user}" \
          "/etc/sudoers.d/${target_user}" 2>/dev/null || true

    if [[ "$target_exists" == "true" ]]; then
        userdel -r -f "$target_user" 2>/dev/null || \
        deluser --remove-home "$target_user" 2>/dev/null || \
        userdel -f "$target_user"
    fi

    if rvdk_purge_validate_src_home "$src_home" && [[ -d "$src_home" && ! -L "$src_home" ]]; then
        rm -rf "$src_home"
    fi

    log_ok "Purged user '${target_user}' and removed ${src_home}"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
