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
#   • Strict RFC-1123, POSIX username, IPv4 CIDR, PG identifier & path validators
#   • Dynamic primary NIC IPv4 subnet CIDR discovery (rvdk_detect_primary_cidr)
# ==============================================================================

if [[ "${_RVDK_COMMON_SOURCED:-0}" == "1" ]]; then
    return 0 2>/dev/null || true
fi
_RVDK_COMMON_SOURCED="1"

_RVDK_LOG_TAG="${_RVDK_LOG_TAG:-RVDK}"

rvdk_log_init() {
    _RVDK_LOG_TAG="${1:-RVDK}"
}

log_info()  { printf "\033[1;36m[%s]\033[0m %s\n" "${_RVDK_LOG_TAG}" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
log_err()   { printf "\033[1;31m[ERR!]\033[0m %s\n" "$1" >&2; }
log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

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
            exec sudo -E bash "$script_path" "$@"
        else
            log_fatal "Root privileges required. Run with sudo or pipe into 'sudo bash'."
        fi
    fi
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

        if [[ "$preserve" == "true" && -n "${!key+x}" && -n "${!key}" ]]; then
            continue
        fi

        # Strip unquoted inline comments and surrounding whitespace
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        if [[ ${#val} -ge 2 ]]; then
            first_ch="${val:0:1}"
            last_ch="${val:$(( ${#val} - 1 )):1}"
            if [[ "$first_ch" == '"' && "$last_ch" == '"' ]]; then
                val="${val:1:$(( ${#val} - 2 ))}"
                val="${val//\\\"/\"}"
                val="${val//\\\\/\\}"
            elif [[ "$first_ch" == "'" && "$last_ch" == "'" ]]; then
                val="${val:1:$(( ${#val} - 2 ))}"
            else
                val="${val%%[[:space:]]#*}"
                val="${val%"${val##*[![:space:]]}"}"
            fi
        fi

        # Reject shell command-substitution tokens or control characters in untrusted env files
        if [[ "$val" == *'$('* || "$val" == *'`'* || "$val" == *$'\n'* ]]; then
            log_warn "Ignored unsafe value for '${key}' in ${env_file}"
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
    local tmp_file="${target_file}.tmp.$$"
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
    } > "$tmp_file"
    chmod "$file_mode" "$tmp_file"
    mv -f "$tmp_file" "$target_file"
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
    if [[ ! "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
        return 1
    fi
    local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}" pfx="${BASH_REMATCH[5]}"
    (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 && pfx <= 32 ))
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
