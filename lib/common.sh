#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Core Runtime, Validation & Safe Config Library
# Path: riscv-data-kit/lib/common.sh
#
# Provides:
#   • Standardized ANSI logging (rvdk_log_init, log_info, log_ok, log_skip, log_warn, log_err, log_fatal)
#   • Root privilege escalation helper (rvdk_require_root) & caller resolution (rvdk_resolve_caller)
#   • SSH-forwarded locale hygiene (rvdk_sanitize_locale)
#   • Safe, non-executing key-value .env reader/writer (rvdk_kv_load, rvdk_load_config_env, rvdk_kv_write)
#   • Atomic same-directory file writer with signal-safe temp cleanup (rvdk_atomic_write)
#   • Workload-neutral data mount resolver (rvdk_resolve_data_mount, rvdk_normalize_mount_path)
#   • Strict RFC-1123, POSIX username, IPv4 CIDR, PG identifier & path validators
#   • Dynamic primary NIC IPv4 subnet CIDR discovery (rvdk_detect_primary_cidr)
#   • Monotonic cold-RTC clock recovery with MITM rollback guard (rvdk_sync_cold_clock)
# ==============================================================================

[[ -n "${_RVDK_COMMON_SH_LOADED:-}" ]] && return 0
_RVDK_COMMON_SH_LOADED=1

_RVDK_LOG_TAG="${_RVDK_LOG_TAG:-RVDK}"
RVDK_MIN_VALID_EPOCH="${RVDK_MIN_VALID_EPOCH:-1767225600}"
RVDK_MAX_VALID_EPOCH="${RVDK_MAX_VALID_EPOCH:-2145916800}"

if [[ -z "${_RVDK_TMPFILES+x}" ]]; then
    _RVDK_TMPFILES=()
fi
if [[ -z "${_RVDK_CLEANUP_HOOKS+x}" ]]; then
    _RVDK_CLEANUP_HOOKS=()
fi
_RVDK_CLEANUP_RUNNING="${_RVDK_CLEANUP_RUNNING:-0}"
_RVDK_CLEANUP_TRAP_SET="${_RVDK_CLEANUP_TRAP_SET:-0}"
_RVDK_TRAP_SUBSHELL="${_RVDK_TRAP_SUBSHELL:-${BASH_SUBSHELL:-0}}"

rvdk_log_init() {
    _RVDK_LOG_TAG="${1:-RVDK}"
}

log_info()  { printf "\033[1;36m[%s]\033[0m %s\n" "${_RVDK_LOG_TAG}" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
log_err()   { printf "\033[1;31m[ERR!]\033[0m %s\n" "$1" >&2; }
log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

_rvdk_cleanup_tmpfiles() {
    local _tf
    for _tf in ${_RVDK_TMPFILES[@]+"${_RVDK_TMPFILES[@]}"}; do
        [[ -n "$_tf" ]] && rm -f "$_tf" 2>/dev/null || true
    done
    _RVDK_TMPFILES=()
}

_rvdk_untrack_tmpfile() {
    local target="${1:-}"
    [[ -n "$target" ]] || return 0
    local -a kept=()
    local _tf
    for _tf in ${_RVDK_TMPFILES[@]+"${_RVDK_TMPFILES[@]}"}; do
        [[ -n "$_tf" && "$_tf" != "$target" ]] && kept+=("$_tf")
    done
    if [[ ${#kept[@]} -gt 0 ]]; then
        _RVDK_TMPFILES=("${kept[@]}")
    else
        _RVDK_TMPFILES=()
    fi
}

_rvdk_push_cleanup_hook() {
    local fn="${1:-}"
    [[ "$fn" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    local existing
    for existing in ${_RVDK_CLEANUP_HOOKS[@]+"${_RVDK_CLEANUP_HOOKS[@]}"}; do
        [[ "$existing" == "$fn" ]] && return 0
    done
    _RVDK_CLEANUP_HOOKS+=("$fn")
    return 0
}

_rvdk_run_cleanup_hooks() {
    local rc=$?
    if [[ "${_RVDK_CLEANUP_RUNNING:-0}" == "1" ]]; then
        return "$rc"
    fi
    _RVDK_CLEANUP_RUNNING=1

    if [[ -n "${_RVDK_CLEANUP_HOOKS+x}" ]]; then
        local -a _hooks=()
        local _h
        for _h in ${_RVDK_CLEANUP_HOOKS[@]+"${_RVDK_CLEANUP_HOOKS[@]}"}; do
            _hooks+=("$_h")
        done
        local i hook
        for (( i = ${#_hooks[@]} - 1; i >= 0; i-- )); do
            hook="${_hooks[$i]:-}"
            if [[ -n "$hook" ]] && typeset -f "$hook" >/dev/null 2>&1; then
                "$hook" || true
            fi
        done
    fi

    _rvdk_cleanup_tmpfiles || true
    return "$rc"
}

_rvdk_on_signal() {
    local sig="${1:-TERM}"
    local sig_rc=130
    if [[ "$sig" == "TERM" ]]; then
        sig_rc=143
    fi
    _rvdk_run_cleanup_hooks || true
    trap - "$sig"
    kill -s "$sig" "${BASHPID:-$$}" 2>/dev/null || kill "-${sig}" "$$" 2>/dev/null || exit "$sig_rc"
}

_rvdk_reset_subshell_trap_state() {
    local cur_subshell="${BASH_SUBSHELL:-0}"
    if (( cur_subshell > 0 )) && [[ "${_RVDK_TRAP_SUBSHELL:-0}" != "$cur_subshell" ]]; then
        _RVDK_CLEANUP_HOOKS=()
        _RVDK_TMPFILES=()
        _RVDK_CLEANUP_RUNNING=0
        _RVDK_CLEANUP_TRAP_SET=0
        _RVDK_TRAP_SUBSHELL="$cur_subshell"
    fi
}

_rvdk_install_cleanup_trap() {
    local force_install="${1:-false}"
    local cur_subshell="${BASH_SUBSHELL:-0}"
    _rvdk_reset_subshell_trap_state

    local trap_fn_re="^trap -- '([A-Za-z_][A-Za-z0-9_]*)' EXIT\$"
    if [[ "${_RVDK_CLEANUP_TRAP_SET:-0}" == "1" ]]; then
        if (( cur_subshell == 0 )) && [[ -n "${BASH_VERSION:-}" ]]; then
            local cur_exit_trap=""
            cur_exit_trap="$(trap -p EXIT 2>/dev/null || true)"
            if [[ "$cur_exit_trap" == *"_rvdk_run_cleanup_hooks"* ]]; then
                return 0
            fi
            if [[ "$cur_exit_trap" =~ $trap_fn_re ]]; then
                local ext_fn="${cur_exit_trap#trap -- \'}"
                ext_fn="${ext_fn%\' EXIT}"
                if [[ "$ext_fn" != "_rvdk_run_cleanup_hooks" && "$ext_fn" != "_rvdk_cleanup_tmpfiles" ]] && typeset -f "$ext_fn" >/dev/null 2>&1; then
                    _rvdk_push_cleanup_hook "$ext_fn" || true
                fi
            elif [[ -n "$cur_exit_trap" && "$force_install" != "true" ]]; then
                return 0
            fi
        else
            return 0
        fi
    elif (( cur_subshell == 0 )) && [[ -n "${BASH_VERSION:-}" ]]; then
        local pre_exit_trap=""
        pre_exit_trap="$(trap -p EXIT 2>/dev/null || true)"
        if [[ -n "$pre_exit_trap" ]]; then
            if [[ "$pre_exit_trap" =~ $trap_fn_re ]]; then
                local pre_fn="${pre_exit_trap#trap -- \'}"
                pre_fn="${pre_fn%\' EXIT}"
                if [[ "$pre_fn" != "_rvdk_run_cleanup_hooks" && "$pre_fn" != "_rvdk_cleanup_tmpfiles" ]] && typeset -f "$pre_fn" >/dev/null 2>&1; then
                    _rvdk_push_cleanup_hook "$pre_fn" || true
                fi
            elif [[ "$force_install" != "true" ]]; then
                return 0
            fi
        fi
    fi

    _RVDK_CLEANUP_TRAP_SET=1
    _RVDK_TRAP_SUBSHELL="$cur_subshell"
    trap '_rvdk_run_cleanup_hooks' EXIT
    trap '_rvdk_on_signal INT' INT
    trap '_rvdk_on_signal TERM' TERM
    return 0
}

# Register an idempotent cleanup hook to run in LIFO order on EXIT/INT/TERM.
# Usage: rvdk_register_cleanup <fn_name>
rvdk_register_cleanup() {
    local fn="${1:-}"
    [[ -n "$fn" ]] || return 1
    _rvdk_reset_subshell_trap_state
    _rvdk_push_cleanup_hook "$fn" || return 1
    _rvdk_install_cleanup_trap "true"
}

# Atomically write stdin to <target_path> via same-directory temp file + mv -f.
# Usage: rvdk_atomic_write <target_path> <octal_mode> [<owner:group>]
rvdk_atomic_write() {
    local target_path="$1"
    local file_mode="${2:-0644}"
    local owner_group="${3:-}"

    if [[ -d "$target_path" ]]; then
        log_err "rvdk_atomic_write: target '${target_path}' is a directory"
        return 1
    fi

    local dir base tmp_file
    dir="$(dirname "$target_path")"
    base="$(basename "$target_path")"
    mkdir -p "$dir"

    _rvdk_install_cleanup_trap "false"

    tmp_file="$(mktemp "${dir}/.${base}.rvdk.XXXXXX")"
    _RVDK_TMPFILES+=("$tmp_file")

    if ! cat > "$tmp_file" \
        || ! chmod "$file_mode" "$tmp_file" \
        || { [[ -n "$owner_group" ]] && ! chown "$owner_group" "$tmp_file"; } \
        || ! mv -f "$tmp_file" "$target_path"; then
        rm -f "$tmp_file" 2>/dev/null || true
        _rvdk_untrack_tmpfile "$tmp_file"
        return 1
    fi
    _rvdk_untrack_tmpfile "$tmp_file"
    return 0
}

# Escalate to root via sudo if EUID != 0 (while allowing unprivileged -h/--help inspection)
rvdk_require_root() {
    local script_path="$1"
    shift || true
    local _arg
    for _arg in "$@"; do
        case "$_arg" in
            -h|--help)
                if [[ -n "$script_path" && -f "$script_path" ]]; then
                    if awk '/^# --- BEGIN INLINED/{skip=1; next} /^# --- END INLINED/{skip=0; next} !skip && /^[[:space:]]*(-h\|)?--help\)/{found=1} END{exit !found}' "$script_path" 2>/dev/null; then
                        return 0
                    fi
                    awk '/^# ===/{c++; if (c==2) exit; next} c==1 {sub(/^# ?/, ""); print}' "$script_path"
                    exit 0
                fi
                return 0
                ;;
        esac
    done
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        if [[ -n "$script_path" && -f "$script_path" ]] && command -v sudo >/dev/null 2>&1; then
            local _sudo_rc=0
            rvdk_sudo_preserve bash "$script_path" "$@" || _sudo_rc=$?
            exit "$_sudo_rc"
        else
            log_fatal "Root privileges required. Run with sudo or pipe into 'sudo bash'."
        fi
    fi
}

# Join items with an arbitrary multi-character separator without format-string injection.
# Usage: rvdk_join_by <sep> [items...]
rvdk_join_by() {
    local sep="${1-}"
    shift || return 0
    [[ $# -eq 0 ]] && return 0
    printf '%s' "$1"
    shift
    local item
    for item in "$@"; do
        printf '%s%s' "$sep" "$item"
    done
}

_RVDK_SUDO_PRESERVE_ALLOWLIST=(
    RVDK_ALLOW_CIDR
    RVDK_APT_DISTRO_DEFAULT
    RVDK_ARCH
    RVDK_BACKUP_ROOT
    RVDK_BASE_URL
    RVDK_BOARD
    RVDK_BOARDS_DIR
    RVDK_BOARD_QUIRKS
    RVDK_BOARD_TAG
    RVDK_BOOT_BACKUP_DIR
    RVDK_BRANCH
    RVDK_CACHE_DIR
    RVDK_DEEPTUNE_CHAIN
    RVDK_DEEPTUNE_ENV
    RVDK_DEEPTUNE_LAYERS
    RVDK_DT_MODEL
    RVDK_ENGINE_DIR
    RVDK_ENV_FILE
    RVDK_FLASH_FORCE_RAW
    RVDK_HOSTNAME
    RVDK_KEEP_VENDOR_MIRRORS
    RVDK_KIT_CACHE_FILE
    RVDK_LOCALE
    RVDK_MAX_VALID_EPOCH
    RVDK_MIN_VALID_EPOCH
    RVDK_MIRROR_URL
    RVDK_MMU
    RVDK_NO_APT_UPDATE
    RVDK_NO_PROGBAR
    RVDK_OS_ID
    RVDK_OS_VERSION_ID
    RVDK_P550_HDMI_STATE_FILE
    RVDK_P550_PLAT_DRV_BASE
    RVDK_PARENT_BADGE_SGR
    RVDK_PARENT_BAR_SGR
    RVDK_PARENT_LABEL
    RVDK_PARENT_PROGBAR
    RVDK_PARENT_STATE
    RVDK_PRIMARY_NIC
    RVDK_PROGBAR_SESSION
    RVDK_PROG_BASE
    RVDK_PROG_SPAN
    RVDK_RELEASE_BASE
    RVDK_REPO_URL
    RVDK_SECONDARY_NIC
    RVDK_SKIP_NET_GUARD
    RVDK_SOC
    RVDK_SOC_SLUG
    RVDK_STATE_DIR
    RVDK_SUB_STATE
    RVDK_SYSTEMD_UNIT_DIR
    RVDK_TIMEZONE
    RVDK_TUNE
    RVDK_TUNE_MODE
)

# Escalate via sudo while preserving ONLY allowlisted operational RVDK_* env vars
# (explicitly excluding XDG_CACHE_HOME, LD_*, PATH, BASH_ENV, etc.).
# Falls back gracefully to plain `sudo` when sudoers restricts SETENV without
# ever executing the target command twice on a real target failure.
# Usage: rvdk_sudo_preserve <command> [args...]
rvdk_sudo_preserve() {
    [[ $# -gt 0 ]] || return 1
    local -a present_vars=()
    local var_name
    for var_name in "${_RVDK_SUDO_PRESERVE_ALLOWLIST[@]}"; do
        if [[ -n "${!var_name+x}" ]]; then
            present_vars+=("$var_name")
        fi
    done

    local rc=0
    if [[ ${#present_vars[@]} -eq 0 ]]; then
        sudo "$@" || rc=$?
        return "$rc"
    fi

    local preserve_csv
    preserve_csv="$(rvdk_join_by "," "${present_vars[@]}")"

    local probe_err="" probe_rc=0
    probe_err="$(sudo --preserve-env="$preserve_csv" -n true 2>&1)" || probe_rc=$?
    if [[ "$probe_rc" -eq 0 ]]; then
        sudo --preserve-env="$preserve_csv" "$@" || rc=$?
        return "$rc"
    fi

    if [[ "$probe_err" =~ (not[[:space:]]+allowed|SETENV|preserve-env|unrecognized[[:space:]]+option|unknown[[:space:]]+option|illegal[[:space:]]+option|invalid[[:space:]]+option|unexpected[[:space:]]+argument) ]] \
        || sudo -n true >/dev/null 2>&1; then
        sudo "$@" || rc=$?
        return "$rc"
    fi

    if sudo -v; then
        if sudo --preserve-env="$preserve_csv" -n true >/dev/null 2>&1; then
            sudo --preserve-env="$preserve_csv" "$@" || rc=$?
            return "$rc"
        fi
        sudo "$@" || rc=$?
        return "$rc"
    fi
    return 1
}

# Create a pristine first-touch backup of <src_path> under $RVDK_BACKUP_ROOT/<category>/
# with an accompanying .path sidecar recording the exact original destination path.
# Usage: rvdk_backup_file <src_path> [category]
rvdk_backup_file() {
    local src_path="${1:-}"
    local category="${2:-deeptune}"

    [[ "$category" =~ ^[a-z0-9_-]+$ ]] || return 1
    [[ "$src_path" == /* && -f "$src_path" && ! -L "$src_path" ]] || return 1
    [[ "$src_path" != *$'\n'* && "$src_path" != *$'\r'* && ! "$src_path" =~ [[:cntrl:]] ]] || return 1
    [[ "$src_path" != *".."* && "$src_path" != *"//"* && "$src_path" != *"/./"* && "$src_path" != *"/." && "$src_path" != */ ]] || return 1

    local backup_root="${RVDK_BACKUP_ROOT:-${RVDK_STATE_DIR:-/var/lib/rvdk}/backups}"
    while [[ "$backup_root" != "/" && "$backup_root" == */ ]]; do
        backup_root="${backup_root%/}"
    done
    [[ -n "$backup_root" && "$backup_root" == /* ]] || return 1

    local encoded="${src_path#/}"
    encoded="${encoded//\//__}"
    [[ -n "$encoded" ]] || return 1

    local cat_dir="${backup_root}/${category}"
    local orig_path="${cat_dir}/${encoded}.orig"
    local sidecar_path="${cat_dir}/${encoded}.path"

    if [[ -L "$backup_root" || -L "$cat_dir" ]]; then
        log_err "rvdk_backup_file: refusing symlink backup directory '${cat_dir}'"
        return 1
    fi
    if [[ -L "$orig_path" || -L "$sidecar_path" ]]; then
        log_err "rvdk_backup_file: refusing symlink backup artifact under '${cat_dir}'"
        return 1
    fi

    mkdir -p "$cat_dir" && chmod 0755 "$cat_dir" || return 1

    if [[ ! -e "$orig_path" ]]; then
        _rvdk_install_cleanup_trap "false"
        local tmp_orig
        tmp_orig="$(mktemp "${cat_dir}/.${encoded}.orig.XXXXXX")" || return 1
        _RVDK_TMPFILES+=("$tmp_orig")
        if ! cp -a "$src_path" "$tmp_orig" || ! mv -f "$tmp_orig" "$orig_path"; then
            rm -f "$tmp_orig" 2>/dev/null || true
            _rvdk_untrack_tmpfile "$tmp_orig"
            return 1
        fi
        _rvdk_untrack_tmpfile "$tmp_orig"
    elif [[ ! -f "$orig_path" ]]; then
        log_err "rvdk_backup_file: existing backup '${orig_path}' is not a regular file"
        return 1
    fi

    if [[ ! -e "$sidecar_path" ]]; then
        printf '%s\n' "$src_path" | rvdk_atomic_write "$sidecar_path" 0644 || return 1
    elif [[ ! -f "$sidecar_path" ]]; then
        log_err "rvdk_backup_file: existing sidecar '${sidecar_path}' is not a regular file"
        return 1
    fi

    return 0
}

# Sanitize SSH-forwarded LC_* environment variables before target locales are generated
rvdk_sanitize_locale() {
    local avail
    avail="$(locale -a 2>/dev/null || true)"
    if grep -qiE '^en_US\.utf-?8$' <<< "$avail"; then
        export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
    elif grep -qiE '^C\.utf-?8$' <<< "$avail"; then
        export LANG="C.UTF-8" LC_ALL="C.UTF-8"
    else
        export LANG="C" LC_ALL="C"
    fi
}

# Safely resolve invoking non-root caller without `eval`
# Exports: REAL_USER, REAL_GRP, REAL_HOME
rvdk_resolve_caller() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        REAL_USER="$(id -un 2>/dev/null || echo "${USER:-root}")"
    else
        REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo root)}"
    fi
    if [[ ! "$REAL_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        REAL_USER="root"
    fi
    REAL_GRP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
    REAL_HOME=""
    if command -v getent >/dev/null 2>&1; then
        REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || true)"
    elif command -v dscl >/dev/null 2>&1; then
        REAL_HOME="$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
    fi
    if [[ -z "$REAL_HOME" ]]; then
        if [[ "$REAL_USER" == "root" ]]; then
            REAL_HOME="/root"
        elif [[ -d "/Users/${REAL_USER}" ]]; then
            REAL_HOME="/Users/${REAL_USER}"
        elif [[ -d "/home/${REAL_USER}" ]]; then
            REAL_HOME="/home/${REAL_USER}"
        else
            REAL_HOME="/root"
        fi
    fi
    export REAL_USER REAL_GRP REAL_HOME
}

# Normalize trailing slashes on mountpoint paths while preserving root "/"
rvdk_normalize_mount_path() {
    local p="${1:-}"
    while [[ "$p" != "/" && "$p" == */ ]]; do
        p="${p%/}"
    done
    printf '%s\n' "$p"
}

# Resolve target data mountpoint without legacy appliance bleed:
#   1. Explicit argument (or $MOUNT_POINT) normalized if non-empty
#   2. /mnt/nvme_data ONLY when actively mounted (`mountpoint -q /mnt/nvme_data`)
#   3. Empty string "" otherwise (caller falls back to OS service path)
rvdk_resolve_data_mount() {
    local explicit="${1:-${MOUNT_POINT:-}}"
    if [[ -n "$explicit" ]]; then
        rvdk_normalize_mount_path "$explicit"
        return 0
    fi
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q /mnt/nvme_data 2>/dev/null; then
        printf '/mnt/nvme_data\n'
        return 0
    fi
    printf '\n'
}

# Strip commit=<10+s> mount options ONLY from active root ext4 entries ($2 == "/" && $3 == "ext4").
# Falls back to "defaults" if commit=... was the sole mount option.
_rvdk_strip_fstab_commit() {
    awk '{
        if ($1 !~ /^#/ && NF >= 4 && $2 == "/" && $3 == "ext4") {
            n = split($4, opts, ",")
            out_opts = ""
            changed = 0
            for (i = 1; i <= n; i++) {
                if (opts[i] ~ /^commit=[0-9][0-9]+$/) {
                    changed = 1
                    continue
                }
                if (opts[i] == "") continue
                out_opts = (out_opts == "" ? opts[i] : out_opts "," opts[i])
            }
            if (changed) {
                if (out_opts == "") out_opts = "defaults"
                $4 = out_opts
            }
        }
        print
    }'
}

# Rewrite token-bounded LABEL=<old_lbl> -> LABEL=<new_lbl> safely without regex/backref hazards.
_rvdk_rewrite_label_token() {
    local old_lbl="$1"
    local new_lbl="$2"
    RVDK_OLD_LBL="$old_lbl" RVDK_NEW_LBL="$new_lbl" awk '
    BEGIN {
        old_val = ENVIRON["RVDK_OLD_LBL"]
        needle = "LABEL=" old_val
        repl = "LABEL=" ENVIRON["RVDK_NEW_LBL"]
        nlen = length(needle)
    }
    {
        if (length(old_val) == 0) {
            print $0
            next
        }
        s = $0
        out = ""
        while ((pos = index(s, needle)) > 0) {
            out = out substr(s, 1, pos - 1)
            prev = (length(out) > 0) ? substr(out, length(out), 1) : ""
            after = substr(s, pos + nlen, 1)
            prev_ok = (prev == "" || prev ~ /[[:space:]]/ || index(",=\"\047", prev) > 0)
            after_ok = (after == "" || after ~ /[[:space:]]/ || index(",\"\047", after) > 0)
            if (prev_ok && after_ok) {
                out = out repl
            } else {
                out = out needle
            }
            s = substr(s, pos + nlen)
        }
        print out s
    }'
}

# Rewrite literal substring <old_str> -> <new_str> safely without regex/backref hazards.
_rvdk_rewrite_literal() {
    local old_str="$1"
    local new_str="$2"
    RVDK_OLD_STR="$old_str" RVDK_NEW_STR="$new_str" awk '
    BEGIN {
        needle = ENVIRON["RVDK_OLD_STR"]
        repl = ENVIRON["RVDK_NEW_STR"]
        nlen = length(needle)
    }
    {
        s = $0
        out = ""
        while (nlen > 0 && (pos = index(s, needle)) > 0) {
            out = out substr(s, 1, pos - 1) repl
            s = substr(s, pos + nlen)
        }
        print out s
    }'
}

# Safe non-executing key-value loader. Never invokes `source` or command expansion.
# Usage: rvdk_kv_load <env_file> [--preserve-existing] <ALLOWED_KEY_1> [ALLOWED_KEY_2 ...]
rvdk_kv_load() {
    local env_file="$1"
    shift || return 0
    [[ -r "$env_file" ]] || return 0

    local preserve="false"
    if [[ "${1:-}" == "--preserve-existing" ]]; then
        preserve="true"
        shift
    fi
    [[ $# -eq 0 ]] && return 0

    local allowed_list=" $* "
    local _bs=$'\x01'
    local raw_line line key val first_ch last_ch
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line="${raw_line%$'\r'}"
        # Trim leading whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == export[[:space:]]* ]]; then
            line="${line#export}"
            line="${line#"${line%%[![:space:]]*}"}"
        fi
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        val="${line#*=}"
        # Trim trailing whitespace on key
        key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        [[ "$allowed_list" == *" ${key} "* ]] || continue

        if [[ "$preserve" == "true" ]]; then
            local _cur_set="${!key:-}"
            if [[ -n "$_cur_set" ]]; then
                continue
            fi
        fi

        # Strip unquoted inline comments and surrounding whitespace
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        if [[ ${#val} -ge 2 ]]; then
            first_ch="${val:0:1}"
            last_ch="${val:$(( ${#val} - 1 )):1}"
            if [[ "$first_ch" == '"' && "$last_ch" == '"' ]]; then
                val="${val:1:$(( ${#val} - 2 ))}"
                val="${val//\\\\/${_bs}}"
                val="${val//\\\"/\"}"
                val="${val//\\\$/\$}"
                val="${val//\\\`/\`}"
                val="${val//${_bs}/\\}"
            elif [[ "$first_ch" == "'" && "$last_ch" == "'" ]]; then
                val="${val:1:$(( ${#val} - 2 ))}"
            else
                val="${val%%[[:space:]]#*}"
                val="${val%"${val##*[![:space:]]}"}"
            fi
        fi

        if [[ "$val" == *$'\n'* || "$val" == *$'\r'* ]]; then
            log_warn "Ignored multiline value for '${key}' in ${env_file}"
            continue
        fi

        printf -v "$key" '%s' "$val"
    done < "$env_file"
    return 0
}

# Load optional system-wide RVDK configuration keys safely (/etc/rvdk/config.env or $RVDK_ENV_FILE)
# Existing non-empty caller environment variables take precedence.
rvdk_load_config_env() {
    if [[ -n "${RVDK_ENV_FILE:-}" ]]; then
        if [[ -r "$RVDK_ENV_FILE" ]]; then
            rvdk_kv_load "$RVDK_ENV_FILE" --preserve-existing "$@"
        fi
    elif [[ -r /etc/rvdk/config.env ]]; then
        rvdk_kv_load /etc/rvdk/config.env --preserve-existing "$@"
    fi
    return 0
}

# Atomically write a safe double-quoted KEY="VALUE" file without shell expansion hazards
# Usage: rvdk_kv_write <target_file> <octal_mode> <header_comment> "KEY1=val1" "KEY2=val2" ...
rvdk_kv_write() {
    local target_file="$1"
    local file_mode="$2"
    local header="$3"
    shift 3

    local parent_dir
    parent_dir="$(dirname "$target_file")"
    mkdir -p "$parent_dir"
    chmod 0755 "$parent_dir" 2>/dev/null || true

    local nl=$'\n' cr=$'\r'
    {
        printf "# %s\n" "$header"
        local pair k v esc
        for pair in "$@"; do
            k="${pair%%=*}"
            v="${pair#*=}"
            v="${v//"$nl"/ }"
            v="${v//"$cr"/}"
            esc="${v//\\/\\\\}"
            esc="${esc//\"/\\\"}"
            esc="${esc//\$/\\\$}"
            esc="${esc//\`/\\\`}"
            printf '%s="%s"\n' "$k" "$esc"
        done
    } | rvdk_atomic_write "$target_file" "$file_mode"
}

# Strict Validators
rvdk_validate_username() {
    local u="${1:-}"
    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

rvdk_validate_hostname() {
    local h="${1:-}"
    [[ ${#h} -ge 1 && ${#h} -le 253 ]] || return 1
    [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

rvdk_validate_cidr() {
    local cidr="${1:-}"
    local oct_re='(0|[1-9][0-9]{0,2})'
    local pfx_re='(0|[1-9][0-9]?)'
    local cidr_re="^${oct_re}\\.${oct_re}\\.${oct_re}\\.${oct_re}/${pfx_re}\$"
    if [[ ! "$cidr" =~ $cidr_re ]]; then
        return 1
    fi
    local o1 o2 o3 o4 pfx
    IFS='./' read -r o1 o2 o3 o4 pfx <<< "$cidr"
    (( 10#$o1 <= 255 && 10#$o2 <= 255 && 10#$o3 <= 255 && 10#$o4 <= 255 && 10#$pfx <= 32 ))
}

# Normalize IPv4 addr/prefix (e.g. 192.168.1.42/24 -> 192.168.1.0/24) so pg_hba.conf & exports accept it
rvdk_normalize_ipv4_cidr() {
    local cidr="$1"
    rvdk_validate_cidr "$cidr" || return 1
    awk -F'[./]' '{
        o1=$1+0; o2=$2+0; o3=$3+0; o4=$4+0; p=$5+0;
        ip = ((o1 * 256 + o2) * 256 + o3) * 256 + o4;
        if (p == 0) {
            net = 0;
        } else {
            host_div = 2 ^ (32 - p);
            net = int(ip / host_div) * host_div;
        }
        n1 = int(net / 16777216) % 256;
        n2 = int(net / 65536) % 256;
        n3 = int(net / 256) % 256;
        n4 = net % 256;
        printf "%d.%d.%d.%d/%d\n", n1, n2, n3, n4, p;
    }' <<< "$cidr"
}

# Discover canonical IPv4 subnet CIDR of the active primary network interface
rvdk_detect_primary_cidr() {
    command -v ip >/dev/null 2>&1 || return 1
    local nic="${1:-${RVDK_PRIMARY_NIC:-}}"
    if [[ -z "$nic" ]]; then
        nic="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
    fi
    [[ -n "$nic" ]] || return 1
    local raw_cidr
    raw_cidr="$(ip -o -4 addr show dev "$nic" scope global 2>/dev/null | awk '{print $4; exit}' || true)"
    [[ -n "$raw_cidr" ]] || return 1
    rvdk_normalize_ipv4_cidr "$raw_cidr"
}

rvdk_validate_pg_ident() {
    local ident="${1:-}"
    [[ "$ident" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]
}

rvdk_validate_rel_subdir() {
    local sub="${1:-}"
    [[ -n "$sub" && "$sub" != /* && "$sub" != *".."* ]] || return 1
    [[ "$sub" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]]
}

# Pure assertion guarding managed directories against empty, relative, root,
# traversal, symlink, shallow (<2 components), $REAL_HOME, or system-root paths.
# Emits NO stdout, returns 0 when safe, and calls log_fatal on any violation.
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

rvdk_sha256_file() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print tolower($1)}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" | awk '{print tolower($1)}'
    else
        log_fatal "Neither sha256sum nor shasum is installed for cryptographic verification."
    fi
}

# Parse RFC-7231 / RFC-2822 UTC HTTP Date header ("Wed, 18 Nov 2026 23:24:37 GMT") into Unix epoch
_rvdk_parse_http_date_epoch() {
    local hdr="${1:-}"
    [[ -n "$hdr" && "$hdr" != -* && ! "$hdr" =~ [[:cntrl:]] ]] || return 1
    local parsed=""
    parsed="$(date -u -d "$hdr" +%s 2>/dev/null || true)"
    if [[ "$parsed" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$parsed"
        return 0
    fi
    awk '
    BEGIN {
        split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
        for (i = 1; i <= 12; i++) mon[m[i]] = i
    }
    {
        # Match: [Day,] DD Mon YYYY HH:MM:SS GMT
        for (i = 1; i <= NF; i++) {
            if ($i in mon && i >= 2 && (i + 2) <= NF) {
                d = $(i - 1) + 0
                mo = mon[$i]
                y = $(i + 1) + 0
                split($(i + 2), t, ":")
                hh = t[1] + 0; mm = t[2] + 0; ss = t[3] + 0
                if (y < 1970 || d < 1 || d > 31) exit 1
                y_adj = y - (mo <= 2 ? 1 : 0)
                era = int((y_adj >= 0 ? y_adj : y_adj - 399) / 400)
                yoe = y_adj - era * 400
                mp = mo + (mo > 2 ? -3 : 9)
                doy = int((153 * mp + 2) / 5) + d - 1
                doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
                days = era * 146097 + doe - 719468
                printf "%d\n", days * 86400 + hh * 3600 + mm * 60 + ss
                exit 0
            }
        }
        exit 1
    }' <<< "$hdr"
}

# Step cold-reset system clocks on batteryless RISC-V SBCs ONLY when local time
# predates RVDK_MIN_VALID_EPOCH (2026-01-01T00:00:00Z) and no NTP daemon is synced.
# Strictly monotonic and quorum-gated: requires >= 2 independent HTTP Date
# responses within [RVDK_MIN_VALID_EPOCH, RVDK_MAX_VALID_EPOCH] agreeing within 300s.
rvdk_sync_cold_clock() {
    local min_epoch="${RVDK_MIN_VALID_EPOCH:-1767225600}"
    local max_epoch="${RVDK_MAX_VALID_EPOCH:-2145916800}"
    [[ "$min_epoch" =~ ^[0-9]+$ ]] || min_epoch=1767225600
    [[ "$max_epoch" =~ ^[0-9]+$ ]] || max_epoch=2145916800

    local local_epoch=""
    local_epoch="$(date -u +%s 2>/dev/null || echo 0)"
    [[ "$local_epoch" =~ ^[0-9]+$ ]] || local_epoch=0

    # Fast-return without any plain HTTP request if clock is valid or NTP-synchronized
    if (( local_epoch >= min_epoch )); then
        return 0
    fi
    if command -v timedatectl >/dev/null 2>&1; then
        if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == "yes" ]]; then
            return 0
        fi
    fi
    if [[ -e /run/systemd/timesync/synchronized ]]; then
        return 0
    fi
    if command -v chronyc >/dev/null 2>&1; then
        if chronyc tracking 2>/dev/null | grep -qE '^Leap status[[:space:]]*:[[:space:]]*Normal'; then
            return 0
        fi
    fi

    [[ "$(uname -s)" == "Linux" && "${EUID:-$(id -u)}" -eq 0 ]] || return 0
    [[ "${_RVDK_CLOCK_CHECKED:-0}" == "1" ]] && return 0
    _RVDK_CLOCK_CHECKED="1"

    if (( max_epoch < min_epoch )); then
        log_warn "Cold-RTC sync: invalid epoch bounds [${min_epoch}, ${max_epoch}]; leaving clock unchanged."
        return 0
    fi

    local probe_url raw_hdr hdr_date remote_epoch
    local -a valid_epochs=()
    local agreed_epoch="" saw_rejected="false"

    for probe_url in \
        "http://rvdk.drewv-labs.dev/" \
        "http://deb.debian.org/" \
        "http://connectivitycheck.gstatic.com/generate_204"; do
        raw_hdr=""
        hdr_date=""
        remote_epoch=""
        if command -v curl >/dev/null 2>&1; then
            raw_hdr="$(curl -fsSI --connect-timeout 3 --max-time 5 "$probe_url" 2>/dev/null || true)"
        elif command -v wget >/dev/null 2>&1; then
            raw_hdr="$(wget -qSO- --max-redirect=0 --timeout=4 "$probe_url" 2>&1 || true)"
        else
            return 0
        fi
        [[ -n "$raw_hdr" ]] || continue

        hdr_date="$(awk 'tolower($1) == "date:" { sub(/^[[:space:]]*[Dd][Aa][Tt][Ee]:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' <<< "$raw_hdr")"
        [[ -n "$hdr_date" ]] || continue

        remote_epoch="$(_rvdk_parse_http_date_epoch "$hdr_date" 2>/dev/null || true)"
        if [[ ! "$remote_epoch" =~ ^[0-9]+$ ]]; then
            log_warn "Cold-RTC sync: unparseable HTTP Date header from ${probe_url}; ignoring."
            saw_rejected="true"
            continue
        fi
        if (( remote_epoch < min_epoch || remote_epoch > max_epoch )); then
            log_warn "Cold-RTC sync: HTTP Date epoch ${remote_epoch} from ${probe_url} outside [${min_epoch}, ${max_epoch}]; ignoring."
            saw_rejected="true"
            continue
        fi
        if (( remote_epoch <= local_epoch )); then
            log_warn "Cold-RTC sync: HTTP Date epoch ${remote_epoch} from ${probe_url} is not ahead of local clock (${local_epoch}); ignoring."
            saw_rejected="true"
            continue
        fi

        local prev_epoch diff
        for prev_epoch in ${valid_epochs[@]+"${valid_epochs[@]}"}; do
            if (( remote_epoch >= prev_epoch )); then
                diff=$(( remote_epoch - prev_epoch ))
            else
                diff=$(( prev_epoch - remote_epoch ))
            fi
            if (( diff <= 300 )); then
                agreed_epoch=$(( (prev_epoch + remote_epoch) / 2 ))
                break
            fi
        done
        valid_epochs+=("$remote_epoch")
        [[ -n "$agreed_epoch" ]] && break
    done

    if [[ -z "$agreed_epoch" ]]; then
        if (( ${#valid_epochs[@]} == 1 )); then
            log_warn "Cold-RTC sync: only 1 valid HTTP Date response received (${valid_epochs[0]}); quorum of 2 agreeing hosts required. Leaving clock unchanged."
        elif (( ${#valid_epochs[@]} >= 2 )); then
            log_warn "Cold-RTC sync: HTTP Date responses from ${#valid_epochs[@]} hosts disagreed by >300s; leaving clock unchanged."
        elif [[ "$saw_rejected" == "true" ]]; then
            log_warn "Cold-RTC sync: no valid in-range HTTP Date responses received; leaving clock unchanged."
        fi
        return 0
    fi

    # Strictly monotonic forward step within [min_epoch, max_epoch] with 2-host quorum
    if (( agreed_epoch >= min_epoch && agreed_epoch <= max_epoch && agreed_epoch > local_epoch )); then
        local skew=$(( agreed_epoch - local_epoch ))
        local agreed_utc=""
        agreed_utc="$(awk -v ts="$agreed_epoch" 'BEGIN {
            z = int(ts / 86400) + 719468;
            era = int((z >= 0 ? z : z - 146096) / 146097);
            doe = z - era * 146097;
            yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365);
            y = yoe + era * 400;
            doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100));
            mp = int((5 * doy + 2) / 153);
            d = doy - int((153 * mp + 2) / 5) + 1;
            m = mp + (mp < 10 ? 3 : -9);
            y += (m <= 2);
            rem = ts % 86400;
            hh = int(rem / 3600);
            mm = int((rem % 3600) / 60);
            ss = rem % 60;
            printf "%04d-%02d-%02d %02d:%02d:%02d", y, m, d, hh, mm, ss;
        }')"
        if date -u -s "@${agreed_epoch}" >/dev/null 2>&1 || date -u -s "$agreed_utc" >/dev/null 2>&1; then
            if [[ -d /usr/lib && ! -L /usr/lib ]]; then
                touch /usr/lib/clock-epoch 2>/dev/null || true
                chmod 0644 /usr/lib/clock-epoch 2>/dev/null || true
            fi
            if [[ -f /etc/fake-hwclock.data ]] || command -v fake-hwclock >/dev/null 2>&1; then
                date -u '+%Y-%m-%d %H:%M:%S' > /etc/fake-hwclock.data 2>/dev/null || true
            fi
            if [[ -d /var/lib/systemd/timesync ]]; then
                touch /var/lib/systemd/timesync/clock 2>/dev/null || true
            fi
            hwclock --systohc --utc >/dev/null 2>&1 || true
            log_ok "Stepped cold-RTC system clock via 2-host HTTP Date quorum (+${skew}s -> $(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
        fi
    fi
    return 0
}
