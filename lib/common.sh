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
RVDK_MIN_VALID_EPOCH=1767225600

if [[ -z "${_RVDK_TMPFILES+x}" ]]; then
    _RVDK_TMPFILES=()
fi

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

# Atomically write stdin to <target_path> via same-directory temp file + mv -f.
# Usage: rvdk_atomic_write <target_path> <octal_mode> [<owner:group>]
rvdk_atomic_write() {
    local target_path="$1"
    local file_mode="${2:-0644}"
    local owner_group="${3:-}"

    local dir base tmp_file
    dir="$(dirname "$target_path")"
    base="$(basename "$target_path")"
    mkdir -p "$dir"

    if [[ "${_RVDK_TMP_TRAP_SET:-0}" != "1" ]]; then
        _RVDK_TMP_TRAP_SET="1"
        if [[ -z "$(trap -p EXIT 2>/dev/null || true)" ]]; then
            trap '_rvdk_cleanup_tmpfiles' EXIT
            trap '_rvdk_cleanup_tmpfiles; trap - INT; kill -INT $$' INT
            trap '_rvdk_cleanup_tmpfiles; trap - TERM; kill -TERM $$' TERM
        fi
    fi

    tmp_file="$(mktemp "${dir}/.${base}.rvdk.XXXXXX")"
    _RVDK_TMPFILES+=("$tmp_file")

    cat > "$tmp_file"
    chmod "$file_mode" "$tmp_file"
    if [[ -n "$owner_group" ]]; then
        chown "$owner_group" "$tmp_file"
    fi
    mv -f "$tmp_file" "$target_path"
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

# Normalize trailing slashes on mountpoint paths while preserving root "/"
rvdk_normalize_mount_path() {
    local p="${1:-}"
    while [[ "$p" != "/" && "$p" == */ ]]; do
        p="${p%/}"
    done
    printf '%s' "$p"
}

# Resolve target data mountpoint without legacy appliance bleed:
#   1. Explicit argument (or $MOUNT_POINT) normalized if non-empty
#   2. /mnt/nvme_data ONLY when actively mounted (`mountpoint -q /mnt/nvme_data`)
#   3. Empty string "" otherwise (caller falls back to OS service path)
rvdk_resolve_data_mount() {
    local explicit="${1:-${MOUNT_POINT:-}}"
    if [[ -n "$explicit" ]]; then
        rvdk_normalize_mount_path "$explicit"
        printf '\n'
        return 0
    fi
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q /mnt/nvme_data 2>/dev/null; then
        printf '/mnt/nvme_data\n'
        return 0
    fi
    printf '\n'
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
            local _cur_set=""
            eval "_cur_set=\"\${${key}:-}\""
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

# Parse RFC-7231 / RFC-2822 UTC HTTP Date header ("Wed, 18 Nov 2026 23:24:37 GMT") into Unix epoch
_rvdk_parse_http_date_epoch() {
    local hdr="$1"
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
# Strictly monotonic: never touches plain HTTP once valid/synced and never steps backward.
rvdk_sync_cold_clock() {
    local local_epoch=""
    local_epoch="$(date -u +%s 2>/dev/null || echo 0)"
    [[ "$local_epoch" =~ ^[0-9]+$ ]] || local_epoch=0

    # Fast-return without any plain HTTP request if clock is valid or NTP-synchronized
    if (( local_epoch >= RVDK_MIN_VALID_EPOCH )); then
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

    local hdr_date="" probe_url raw_hdr
    for probe_url in \
        "http://rvdk.drewv-labs.dev/" \
        "http://deb.debian.org/" \
        "http://connectivitycheck.gstatic.com/generate_204"; do
        raw_hdr=""
        if command -v curl >/dev/null 2>&1; then
            raw_hdr="$(curl -fsSI --connect-timeout 3 --max-time 5 "$probe_url" 2>/dev/null || true)"
        elif command -v wget >/dev/null 2>&1; then
            raw_hdr="$(wget -qSO- --max-redirect=0 --timeout=4 "$probe_url" 2>&1 || true)"
        else
            return 0
        fi
        if [[ -n "$raw_hdr" ]]; then
            hdr_date="$(awk 'tolower($1) == "date:" { sub(/^[[:space:]]*[Dd][Aa][Tt][Ee]:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' <<< "$raw_hdr")"
            [[ -n "$hdr_date" ]] && break
        fi
    done
    [[ -n "$hdr_date" ]] || return 0

    local remote_epoch=""
    remote_epoch="$(_rvdk_parse_http_date_epoch "$hdr_date" 2>/dev/null || true)"
    [[ "$remote_epoch" =~ ^[0-9]+$ ]] || return 0

    # Strictly monotonic forward step past RVDK_MIN_VALID_EPOCH only
    if (( remote_epoch >= RVDK_MIN_VALID_EPOCH && remote_epoch > local_epoch )); then
        local skew=$(( remote_epoch - local_epoch ))
        if date -u -s "@${remote_epoch}" >/dev/null 2>&1 || date -u -s "$hdr_date" >/dev/null 2>&1; then
            if [[ -f /etc/fake-hwclock.data ]] || command -v fake-hwclock >/dev/null 2>&1; then
                date -u '+%Y-%m-%d %H:%M:%S' > /etc/fake-hwclock.data 2>/dev/null || true
            fi
            if [[ -d /var/lib/systemd/timesync ]]; then
                : > /var/lib/systemd/timesync/clock 2>/dev/null || true
            fi
            hwclock --systohc --utc >/dev/null 2>&1 || true
            log_ok "Stepped cold-RTC system clock via HTTP Date (+${skew}s -> $(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
        fi
    fi
    return 0
}
