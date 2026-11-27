#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Universal Bare-Metal Dispatcher & CLI (`rvdk`)
# Path: riscv-data-kit/bootstrap.sh
#
# Usage (One-Shot Curl Day-0 OS + BSP Bootstrapper + CLI Install):
#   curl -fsSL https://rvdk.drewv-labs.dev/bootstrap.sh | sudo bash -s -- --user rvadmin --hostname rv-node --nopasswd [--deeptune] [--tune data|ai|iot] [--with-tailscale]
#
# Usage (Local CLI after install-cli.sh or bootstrap.sh):
#   sudo rvdk [day0|bsp|os|deeptune|storage|postgresql|mods/*|utils/purge-user.sh|update|uninstall] [--deeptune] [--tune data|ai|iot] [--stage-dir <dir>] [--no-apt-update] [--with-tailscale] [--noprogbar]
#   rvdk kit [status|--refresh|--env]
#   sudo rvdk storage [status|grow|shrink|autotune] [--lv <name>] [--gb <N>|--mb <N>]
#   sudo rvdk quirk <name|list> [off|on|toggle|status]
#   rvdk flash <board> <medium> <disk_or_flags...>
#   sudo rvdk uninstall [--purge] [--dry-run] [-y]
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

if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_SELF="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" && "${0:-}" != "zsh" && "${0:-}" != "-zsh" && -f "${0:-}" ]]; then
    SCRIPT_SELF="$0"
else
    SCRIPT_SELF=""
fi

ORIG_ALL_ARGS=("$@")

# Determine whether root privileges are required before executing privileged stages.
# CLI flag validation, help, host flashers (`rvdk flash ...`), Kit inspection
# (`rvdk kit`), and read-only status/list/dry-run subcommands run unprivileged first.
NEED_ROOT="true"
WANT_SUB_HELP="false"
if [[ $# -gt 0 ]]; then
    for _arg in "$@"; do
        case "$_arg" in
            -h|--help|help)
                NEED_ROOT="false"
                WANT_SUB_HELP="true"
                ;;
        esac
    done
    if [[ "$NEED_ROOT" == "true" ]]; then
        case "$1" in
            flash|boards/*/flash-*.sh|boards/*/flash-*)
                NEED_ROOT="false"
                ;;
            kit)
                NEED_ROOT="false"
                if [[ "$(uname -s)" == "Linux" ]]; then
                    for _arg in "$@"; do
                        [[ "$_arg" == "--refresh" ]] && NEED_ROOT="true"
                    done
                fi
                ;;
            storage)
                for _arg in "$@"; do
                    case "$_arg" in
                        status|--status|--json|--dry-run) NEED_ROOT="false" ;;
                    esac
                done
                ;;
            quirk|quirks)
                case "${2:-list}" in
                    list|--list) NEED_ROOT="false" ;;
                    *)
                        for _arg in "$@"; do
                            case "$_arg" in
                                status|--status|stat|check|--stage-dir|--stage-dir=*|--stage-only|--dry-run)
                                    NEED_ROOT="false"
                                    ;;
                            esac
                        done
                        ;;
                esac
                ;;
            deeptune|deep-tune|bsp/deeptune|bsp/deep-tune)
                for _arg in "$@"; do
                    case "$_arg" in
                        status|--status|--stage-dir|--stage-dir=*|--stage-only|--dry-run)
                            NEED_ROOT="false"
                            ;;
                    esac
                done
                ;;
            uninstall|remove|purge|utils/uninstall|utils/uninstall.sh|util/uninstall|util/uninstall.sh)
                for _arg in "$@"; do
                    case "$_arg" in
                        -n|--dry-run) NEED_ROOT="false" ;;
                    esac
                done
                ;;
            day0|bsp)
                _has_stage_dir="false"
                _is_host_stage_target="false"
                for _arg in "$@"; do
                    case "$_arg" in
                        --stage-dir|--stage-dir=*) _has_stage_dir="true" ;;
                        p4|esp32p4|espressif/esp32p4|esp32-p4-wifi6|waveshare/esp32-p4-wifi6|esp-idf|nuttx|linux-nommu|--board=p4|--board=*esp32-p4*|--soc=*esp32p4*|--os=esp-idf|--os=nuttx|--os=linux-nommu)
                            _is_host_stage_target="true"
                            ;;
                    esac
                done
                if [[ "$_has_stage_dir" == "true" && "$_is_host_stage_target" == "true" ]]; then
                    NEED_ROOT="false"
                fi
                ;;
            bsp/espressif/esp32p4/*|boards/waveshare/esp32-p4-wifi6/*)
                for _arg in "$@"; do
                    case "$_arg" in
                        --stage-dir|--stage-dir=*|--stage-only|--dry-run|status|--status)
                            NEED_ROOT="false"
                            ;;
                    esac
                done
                ;;
            *)
                for _arg in "$@"; do
                    case "$_arg" in
                        status|--status)
                            case "$1" in
                                bsp/*|boards/*|utils/*|util/*)
                                    NEED_ROOT="false"
                                    ;;
                            esac
                            ;;
                    esac
                done
                if [[ "$NEED_ROOT" == "true" && "$1" == "install" ]]; then
                    case "${2:-}" in
                        flash|boards/*/flash-*.sh|boards/*/flash-*) NEED_ROOT="false" ;;
                        bsp/espressif/esp32p4/*|boards/waveshare/esp32-p4-wifi6/*)
                            for _arg in "$@"; do
                                case "$_arg" in
                                    --stage-dir|--stage-dir=*|--stage-only|--dry-run|status|--status)
                                        NEED_ROOT="false"
                                        ;;
                                esac
                            done
                            ;;
                    esac
                fi
                ;;
        esac
    fi
fi

_escalate_root_if_needed() {
    if [[ "$NEED_ROOT" == "true" && "${EUID:-$(id -u)}" -ne 0 ]]; then
        if [[ -n "$SCRIPT_SELF" && -f "$SCRIPT_SELF" ]] && command -v sudo >/dev/null 2>&1; then
            local _sudo_rc=0
            rvdk_sudo_preserve bash "$SCRIPT_SELF" ${ORIG_ALL_ARGS[@]+"${ORIG_ALL_ARGS[@]}"} || _sudo_rc=$?
            exit "$_sudo_rc"
        else
            echo "[RVDK:FATAL] Run as root or pipe into 'sudo bash': curl -fsSL https://rvdk.drewv-labs.dev/bootstrap.sh | sudo bash" >&2
            exit 1
        fi
    fi
}

resolve_script_path() {
    local src="$1" dir=""
    if readlink -f "$src" >/dev/null 2>&1; then
        readlink -f "$src"
        return 0
    elif command -v realpath >/dev/null 2>&1; then
        realpath "$src"
        return 0
    fi
    while [[ -L "$src" ]]; do
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="${dir}/${src}"
    done
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    printf '%s/%s\n' "$dir" "$(basename "$src")"
}

ENGINE_DIR="${RVDK_ENGINE_DIR:-/usr/local/share/rvdk/engine}"
RVDK_BASE_URL="${RVDK_BASE_URL:-https://rvdk.drewv-labs.dev}"

if [[ -n "$SCRIPT_SELF" && -e "$SCRIPT_SELF" ]]; then
    SCRIPT_REAL="$(resolve_script_path "$SCRIPT_SELF")"
    CANDIDATE_ROOT="$(cd "$(dirname "$SCRIPT_REAL")" && pwd)"
else
    CANDIDATE_ROOT=""
fi
_REPO_ROOT="${CANDIDATE_ROOT:-$ENGINE_DIR}"

# @RVDK_INLINE_LIBS: common
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_sanitize_locale() { export LANG="C" LC_ALL="C"; }
        rvdk_resolve_caller() { REAL_USER="${SUDO_USER:-root}"; REAL_GRP="root"; REAL_HOME="/root"; export REAL_USER REAL_GRP REAL_HOME; }
        rvdk_sync_cold_clock() { :; }
        rvdk_sudo_preserve() { sudo "$@"; }
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
    fi
fi

rvdk_log_init "RVDK"
rvdk_sanitize_locale
rvdk_resolve_caller

log_rvdk() { printf "\033[1;36m[RVDK]\033[0m %s\n" "$1"; }

link_rvdk_cli() {
    local target_script="$1"
    mkdir -p /usr/local/bin
    chmod 0755 /usr/local /usr/local/bin 2>/dev/null || true
    ln -sf "$target_script" /usr/local/bin/rvdk
    if [[ "$(uname -s)" == "Linux" && -d /usr/bin ]]; then
        ln -sf "$target_script" /usr/bin/rvdk 2>/dev/null || true
    fi
}

_rvdk_bootstrap_sha256() {
    local file_path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file_path" | awk '{print tolower($1)}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file_path" | awk '{print tolower($1)}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file_path" | awk '{print tolower($NF)}'
    else
        return 1
    fi
}

_rvdk_bootstrap_fetch_and_run() {
    local rel_script="$1"
    shift || true
    local base_url="${RVDK_BASE_URL%/}"
    local script_url="${base_url}/${rel_script}"
    local tmp_script="" tmp_sums=""
    tmp_script="$(mktemp "${TMPDIR:-/tmp}/.rvdk-remote.XXXXXX")"
    tmp_sums="$(mktemp "${TMPDIR:-/tmp}/.rvdk-sums.XXXXXX")"
    if typeset -f rvdk_register_tmpfile >/dev/null 2>&1; then
        rvdk_register_tmpfile "$tmp_script"
        rvdk_register_tmpfile "$tmp_sums"
    fi

    if ! curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp_script" "$script_url"; then
        rm -f "$tmp_script" "$tmp_sums" 2>/dev/null || true
        log_fatal "Failed to download '${script_url}' over TLS 1.2+."
    fi

    if curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp_sums" "${base_url}/SHA256SUMS" 2>/dev/null && [[ -s "$tmp_sums" ]]; then
        local expected_sha="" actual_sha=""
        expected_sha="$(awk -v target="$rel_script" '
            NF >= 2 {
                p = $2
                sub(/^\*/, "", p)
                sub(/^\.\//, "", p)
                if (p == target) {
                    print tolower($1)
                    exit
                }
            }
        ' "$tmp_sums" 2>/dev/null || true)"
        if [[ -n "$expected_sha" ]]; then
            if [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
                rm -f "$tmp_script" "$tmp_sums" 2>/dev/null || true
                log_fatal "Malformed SHA-256 entry for '${rel_script}' in ${base_url}/SHA256SUMS."
            fi
            actual_sha="$(_rvdk_bootstrap_sha256 "$tmp_script" 2>/dev/null || true)"
            if [[ -z "$actual_sha" || "$actual_sha" != "$expected_sha" ]]; then
                rm -f "$tmp_script" "$tmp_sums" 2>/dev/null || true
                log_fatal "SHA-256 verification failed for '${rel_script}' (expected ${expected_sha}, got ${actual_sha:-unavailable})."
            fi
        fi
    fi

    local rc=0
    bash "$tmp_script" "$@" || rc=$?
    rm -f "$tmp_script" "$tmp_sums" 2>/dev/null || true
    return "$rc"
}

print_cli_help() {
    cat <<'EOF'
Usage:
  sudo rvdk [day0|bsp|os|deeptune|storage|postgresql|mods/*|utils/purge-user.sh|update|uninstall] [flags]
  rvdk kit [status|--refresh|--env]
  sudo rvdk storage [status|grow|shrink|autotune] [--lv <name>] [--gb <N>|--mb <N>]
  sudo rvdk quirk <name|list> [toggle|off|on|status] [--ephemeral|--persist]
  rvdk flash <board> <medium> <disk_or_flags...>
  rvdk flash list
  sudo rvdk uninstall [--purge] [--dry-run] [-y]

Core Commands:
  day0                     Run full Day-0 (OS normalization + Silicon BSP) forge (default)
  bsp                      Run Silicon BSP hardening (`bsp/<vendor>/<soc>/`)
  os                       Run OS normalization & IPv4 IP-Options Prerouting Drop Guard (`ip hdrlength > 20B`) & MPTCP Lockdown (`os/`)
  deeptune [--tune <t>]    Run multi-layer headless DeepTune (`os` -> `bsp` -> `boards`)
                           Tunes: `data` (default) | `ai` | `iot`, or `rvdk deeptune status`
  kit [status|--refresh]   Inspect or refresh cached hardware/OS Kit (`/etc/rvdk/kit.env`)
  storage <subcmd> [...]   Live LVM capacity manager (`status`, `grow`, `shrink`, `autotune`)
  quirk <name|list> [...]  Toggle board-specific hardware quirks (`boards/<board>/quirks/`)
  flash <board> <medium>   Flash removable media on macOS/Linux (e.g. `rvdk flash p550 usb 4`, `rvdk flash p4 sd 4`)
  postgresql               Install or build PostgreSQL 18.6 (`--force-build` to compile)
  mods/<mod>               Converge storage/network mod (`nvme-4kn`, `btrfs-raid`, `mosquitto`, `ntfy`, `nfs-vault`, `tailscale`)
  utils/purge-user.sh      Migrate state & purge factory default user account
  update                   Pull latest RVDK engine from GitHub
  uninstall [--purge]      Remove RVDK CLI, engine & caches (`--purge` wipes /etc/rvdk & tuning drop-ins)

Day-0 / OS / BSP Stage Flags:
  -u, --user <username>    POSIX operator username (OS stage)
  -H, --hostname <name>    RFC-1123 system hostname (OS stage)
  -n, --nopasswd           Passwordless sudo for --user (OS stage)
      --prompt-password    Prompt for password on user creation (OS stage)
      --debloat-only       Execute headless target, snapd & GUI purge only (OS stage)
      --keep-gui           Preserve graphical target & desktop packages (OS stage)
      --keep-mirrors       Preserve existing APT/NTP/registry mirror configs (OS/BSP stage)
      --skip-locale        Skip en_US.UTF-8 locale generation (OS stage)
      --skip-net-guard     Skip rvdk-net-guard IPv4 IP-options & MPTCP lockdown (OS stage)
      --distro <flavor>    Override APT OS flavor (debian|ubuntu|bianbu|auto) (OS stage)
      --expose-kallsyms    Set kernel.kptr_restrict to 0 (exposes kernel symbols for perf; weakens KASLR)
      --skip-upgrade       Skip initial full-upgrade on JH7110 Debian (BSP stage)
      --full-upgrade       Force apt-get full-upgrade re-run on JH7110 Debian (BSP stage)
      --debian-suite <s>   Target Debian suite on JH7110 (trixie|unstable) (BSP stage)
      --stage-dir <dir>    Host-side staging directory for non-Linux/nommu targets (`esp32p4`)

Global Add-On Flags:
  --deeptune                 Append multi-layer DeepTune to any Day-0 / BSP / Mod run
  -t, --tune <data|ai|iot>   Target workload tune (also implies --deeptune on non-deeptune commands)
  --with-tailscale           Append Tailscale Mesh VPN module
  --no-apt-update            Skip apt-get update calls
  --noprogbar                Disable persistent bottom progress bar
EOF
}

if [[ $# -gt 0 ]] && [[ "$1" == "help" || "$1" == "-h" || "$1" == "--help" ]]; then
    print_cli_help
    exit 0
fi

if [[ "${1:-}" == "update" || "${1:-}" == "self-update" ]]; then
    _escalate_root_if_needed
    shift
    rvdk_sync_cold_clock
    if [[ -n "$CANDIDATE_ROOT" && -f "${CANDIDATE_ROOT}/install-cli.sh" ]]; then
        exec bash "${CANDIDATE_ROOT}/install-cli.sh" "$@"
    else
        _rvdk_bootstrap_fetch_and_run "install-cli.sh" "$@"
        exit $?
    fi
fi

case "${1:-}" in
    uninstall|remove|purge|utils/uninstall|utils/uninstall.sh|util/uninstall|util/uninstall.sh)
        _escalate_root_if_needed
        _UNINSTALL_SUB="$1"
        shift
        _UNINSTALL_ARGS=()
        [[ "$_UNINSTALL_SUB" == "purge" ]] && _UNINSTALL_ARGS+=("--purge")
        if [[ -n "$CANDIDATE_ROOT" && -f "${CANDIDATE_ROOT}/utils/uninstall.sh" ]]; then
            exec bash "${CANDIDATE_ROOT}/utils/uninstall.sh" ${_UNINSTALL_ARGS[@]+"${_UNINSTALL_ARGS[@]}"} "$@"
        elif [[ -f "${ENGINE_DIR}/utils/uninstall.sh" ]]; then
            exec bash "${ENGINE_DIR}/utils/uninstall.sh" ${_UNINSTALL_ARGS[@]+"${_UNINSTALL_ARGS[@]}"} "$@"
        else
            rvdk_sync_cold_clock
            _rvdk_bootstrap_fetch_and_run "utils/uninstall.sh" ${_UNINSTALL_ARGS[@]+"${_UNINSTALL_ARGS[@]}"} "$@"
            exit $?
        fi
        ;;
esac

if [[ "${EUID:-$(id -u)}" -ne 0 && -n "$CANDIDATE_ROOT" && -d "${CANDIDATE_ROOT}/bsp" ]]; then
    LOCAL_ROOT="$CANDIDATE_ROOT"
elif [[ -n "$CANDIDATE_ROOT" && -d "${CANDIDATE_ROOT}/bsp" ]] && ! [[ "$CANDIDATE_ROOT" == */.rvdk/engine && "$CANDIDATE_ROOT" != "$ENGINE_DIR" ]]; then
    LOCAL_ROOT="$CANDIDATE_ROOT"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        if [[ ! -L /usr/local/bin/rvdk ]]; then
            link_rvdk_cli "${LOCAL_ROOT}/bootstrap.sh"
        elif [[ "$LOCAL_ROOT" == "$ENGINE_DIR" && "$(uname -s)" == "Linux" && -d /usr/bin && ! -L /usr/bin/rvdk ]]; then
            link_rvdk_cli "${LOCAL_ROOT}/bootstrap.sh"
        fi
    fi
else
    _escalate_root_if_needed
    rvdk_sync_cold_clock
    if [[ "$CANDIDATE_ROOT" == */.rvdk/engine && "$CANDIDATE_ROOT" != "$ENGINE_DIR" && -d "${CANDIDATE_ROOT}/.git" ]]; then
        umask 022
        ENGINE_PARENT="$(dirname "$ENGINE_DIR")"
        mkdir -p "$ENGINE_PARENT"
        chmod 0755 /usr/local /usr/local/share "$ENGINE_PARENT" 2>/dev/null || true
        if [[ ! -d "${ENGINE_DIR}/.git" ]]; then
            rm -rf "$ENGINE_DIR"
            cp -a "$CANDIDATE_ROOT" "$ENGINE_DIR"
        fi
        chown -R 0:0 "$ENGINE_DIR" 2>/dev/null || true
        chmod -R a+rX "$ENGINE_DIR" 2>/dev/null || true
        chmod 0755 "$ENGINE_DIR"
        link_rvdk_cli "${ENGINE_DIR}/bootstrap.sh"
        rm -rf "$CANDIDATE_ROOT" 2>/dev/null || true
    else
        _rvdk_bootstrap_fetch_and_run "install-cli.sh" --quiet
    fi
    LOCAL_ROOT="$ENGINE_DIR"
fi

# Load Core Runtime & Kit Inference Libraries
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -f "${LOCAL_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${LOCAL_ROOT}/lib/common.sh"
    fi
fi
if [[ -z "${_RVDK_KIT_SH_LOADED:-}" ]]; then
    if [[ -f "${LOCAL_ROOT}/lib/kit.sh" ]]; then
        # shellcheck source=lib/kit.sh
        source "${LOCAL_ROOT}/lib/kit.sh"
    else
        log_fatal "Missing RVDK Kit library: ${LOCAL_ROOT}/lib/kit.sh"
    fi
fi

# ==============================================================================
# 2. Early Subcommands (`flash`, `kit`, `storage`, `quirk`, `bsp/*`, `boards/*`)
# ==============================================================================

# Reject absolute paths or path traversal in subcommand position before dispatch
case "${1:-}" in
    /*|*".."*)
        log_fatal "Unsafe subcommand path rejected: $1"
        ;;
esac

# 2.1 `rvdk flash [list | <board> <medium> <disk_or_flags...>]` (Host macOS/Linux Media Flashers)
if [[ "${1:-}" == "flash" ]]; then
    shift
    FLASH_LIB="${LOCAL_ROOT}/lib/flash.sh"
    [[ ! -f "$FLASH_LIB" ]] && log_fatal "Flash library not found: ${FLASH_LIB}"
    if [[ $# -eq 0 ]]; then
        exec bash "$FLASH_LIB" list
    fi
    exec bash "$FLASH_LIB" "$@"
fi

# 2.2 `rvdk kit [status|--refresh|--env|--json]`
if [[ "${1:-}" == "kit" ]]; then
    _escalate_root_if_needed
    shift
    KIT_MODE="summary"
    KIT_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            status|--status|show) KIT_MODE="summary"; shift ;;
            --motd|--body)        KIT_MODE="motd"; shift ;;
            --env|env)            KIT_MODE="env"; shift ;;
            --json|json)          KIT_MODE="json"; shift ;;
            --refresh|refresh)    KIT_ARGS+=("--refresh"); shift ;;
            --no-cache)           KIT_ARGS+=("--no-cache"); shift ;;
            --soc|--board|--os)   KIT_ARGS+=("$1" "${2:-}"); shift 2 ;;
            -h|--help)
                cat <<'EOF'
Usage:
  rvdk kit [status]          Show resolved Board, SoC, OS, NIC, DeepTune chain & Quirks
  rvdk kit --json            Emit schema_version=1 JSON summary of resolved Kit state
  sudo rvdk kit --refresh    Re-probe hardware/OS and update /etc/rvdk/kit.env
  rvdk kit --env             Print shell-escaped RVDK_KIT_* variables
EOF
                exit 0
                ;;
            *) log_fatal "Unknown 'rvdk kit' option: $1" ;;
        esac
    done
    rvdk_kit_resolve ${KIT_ARGS[@]+"${KIT_ARGS[@]}"}
    if [[ "$KIT_MODE" == "env" ]]; then
        rvdk_kit_print_env
    elif [[ "$KIT_MODE" == "json" ]]; then
        rvdk_kit_print_json "$LOCAL_ROOT"
    elif [[ "$KIT_MODE" == "motd" ]]; then
        rvdk_kit_print_summary "$LOCAL_ROOT" --motd
    else
        rvdk_kit_print_summary "$LOCAL_ROOT"
    fi
    exit 0
fi

# 2.3 `rvdk storage [status|grow|shrink|autotune]`
if [[ "${1:-}" == "storage" ]]; then
    shift
    STORAGE_SCRIPT="${LOCAL_ROOT}/utils/storage.sh"
    [[ ! -f "$STORAGE_SCRIPT" ]] && log_fatal "Storage utility script not found: ${STORAGE_SCRIPT}"
    exec bash "$STORAGE_SCRIPT" "$@"
fi

# 2.4 `rvdk quirk <name|list> [args...]`
if [[ "${1:-}" == "quirk" || "${1:-}" == "quirks" ]]; then
    _escalate_root_if_needed
    shift
    QUIRK_BOARD_OVERRIDE=""
    QUIRK_REST=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --board) QUIRK_BOARD_OVERRIDE="${2:-}"; shift 2 ;;
            *)       QUIRK_REST+=("$1"); shift ;;
        esac
    done

    if [[ -n "$QUIRK_BOARD_OVERRIDE" ]]; then
        rvdk_kit_resolve --board "$QUIRK_BOARD_OVERRIDE"
    else
        rvdk_kit_resolve
    fi

    print_quirks_for_board() {
        local b_id="$1"
        local q_dir="${LOCAL_ROOT}/boards/${b_id}/quirks"
        printf "\033[1;36m[RVDK:QUIRK]\033[0m Quirks for board '%s':\n" "$b_id"
        local found="false"
        local qf qn qsum
        if [[ -d "$q_dir" ]]; then
            for qf in "${q_dir}"/*.sh; do
                [[ -f "$qf" ]] || continue
                found="true"
                qn="$(basename "$qf" .sh)"
                qsum="$(awk -F': *' '/^# Summary:/ {print $2; exit}' "$qf" 2>/dev/null || true)"
                printf "  • sudo rvdk quirk %-8s [toggle|off|on|status]   %s\n" "$qn" "${qsum:-}"
            done
        fi
        [[ "$found" == "false" ]] && printf "  (no quirks registered for %s)\n" "$b_id"
    }

    if [[ ${#QUIRK_REST[@]} -eq 0 || "${QUIRK_REST[0]}" == "list" || "${QUIRK_REST[0]}" == "--list" ]]; then
        if [[ -n "${RVDK_BOARD:-}" ]]; then
            print_quirks_for_board "$RVDK_BOARD"
        else
            for bd in "${LOCAL_ROOT}"/boards/*/*; do
                [[ -d "${bd}/quirks" ]] || continue
                print_quirks_for_board "${bd#"${LOCAL_ROOT}"/boards/}"
            done
        fi
        exit 0
    fi

    if [[ "${QUIRK_REST[0]}" == "-h" || "${QUIRK_REST[0]}" == "--help" ]]; then
        cat <<'EOF'
Usage:
  rvdk quirk list
  sudo rvdk quirk <name> [toggle|off|on|status] [--ephemeral|--persist] [--board <board>]

Examples (SiFive Premier P550):
  sudo rvdk quirk hdmi off
  sudo rvdk quirk hdmi on
  rvdk quirk hdmi status
  sudo rvdk quirk fusb off
EOF
        exit 0
    fi

    [[ -z "${RVDK_BOARD:-}" ]] && log_fatal "Could not auto-detect board from Kit cache or Device Tree. Pass --board <board> (e.g., --board p550)."

    QUIRK_NAME="${QUIRK_REST[0]%.sh}"
    if [[ ! "$QUIRK_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_fatal "Invalid quirk identifier: '${QUIRK_NAME}'."
    fi
    QUIRK_ARGS=("${QUIRK_REST[@]:1}")
    QUIRK_SCRIPT="${LOCAL_ROOT}/boards/${RVDK_BOARD}/quirks/${QUIRK_NAME}.sh"
    if [[ ! -f "$QUIRK_SCRIPT" ]]; then
        print_quirks_for_board "$RVDK_BOARD" >&2
        log_fatal "Quirk '${QUIRK_NAME}' not found for board '${RVDK_BOARD}'."
    fi

    exec bash "$QUIRK_SCRIPT" ${QUIRK_ARGS[@]+"${QUIRK_ARGS[@]}"}
fi

# 2.5 Direct BSP / Board / Quirk Script Dispatch:
#     bsp/<vendor>/<soc>/<script>.sh
#     boards/<vendor>/<board>/<script>.sh
#     boards/<vendor>/<board>/quirks/<quirk>.sh
_rvdk_dispatch_direct_script() {
    local subcmd="$1"
    shift || true

    if [[ "$subcmd" == /* || "$subcmd" == *\\* || "$subcmd" =~ [[:cntrl:]] || "$subcmd" == *".."* || "$subcmd" == *"//"* || "$subcmd" == *"./"* || "$subcmd" == *"/." ]]; then
        log_fatal "Unsafe subcommand path rejected: ${subcmd}"
    fi

    local re_bsp='^bsp/[a-zA-Z0-9][a-zA-Z0-9._-]*/[a-zA-Z0-9][a-zA-Z0-9._-]*/[a-zA-Z0-9][a-zA-Z0-9._-]*\.sh$'
    local re_board='^boards/[a-zA-Z0-9][a-zA-Z0-9._-]*/[a-zA-Z0-9][a-zA-Z0-9._-]*/[a-zA-Z0-9][a-zA-Z0-9._-]*\.sh$'
    local re_quirk='^boards/[a-zA-Z0-9][a-zA-Z0-9._-]*/[a-zA-Z0-9][a-zA-Z0-9._-]*/quirks/[a-zA-Z0-9][a-zA-Z0-9._-]*\.sh$'
    if [[ ! "$subcmd" =~ $re_bsp && ! "$subcmd" =~ $re_board && ! "$subcmd" =~ $re_quirk ]]; then
        log_fatal "Invalid BSP/board script subcommand: '${subcmd}' (expected bsp/<vendor>/<soc>/<script>.sh, boards/<vendor>/<board>/<script>.sh, or boards/<vendor>/<board>/quirks/<quirk>.sh)"
    fi

    local target="${LOCAL_ROOT}/${subcmd}"
    [[ -f "$target" ]] || log_fatal "Script not found under ${LOCAL_ROOT}: ${subcmd}"

    local root_real target_real
    root_real="$(resolve_script_path "$LOCAL_ROOT")"
    target_real="$(resolve_script_path "$target")"
    if [[ "$target_real" != "${root_real}/bsp/"* && "$target_real" != "${root_real}/boards/"* ]]; then
        log_fatal "Symlink escape outside ${root_real} rejected: ${subcmd}"
    fi

    _escalate_root_if_needed
    exec bash "$target" "$@"
}

case "${1:-}" in
    bsp/deeptune|bsp/deep-tune)
        ;;
    bsp/*|boards/*)
        _direct_sub="$1"
        shift
        _rvdk_dispatch_direct_script "$_direct_sub" "$@"
        ;;
    install)
        case "${2:-}" in
            bsp/deeptune|bsp/deep-tune)
                ;;
            bsp/*|boards/*)
                _direct_sub="$2"
                shift 2
                _rvdk_dispatch_direct_script "$_direct_sub" "$@"
                ;;
        esac
        ;;
esac

# ==============================================================================
# 3. Parse Standard Provisioning Subcommand & Stage-Classified Flags
# ==============================================================================
MODULE="day0"
if [[ $# -gt 0 ]]; then
    case "$1" in
        deeptune|deep-tune|bsp/deeptune|bsp/deep-tune)
            MODULE="deeptune"
            shift
            ;;
        ntfy)
            MODULE="mods/ntfy"
            shift
            ;;
        tailscale)
            MODULE="mods/tailscale"
            shift
            ;;
        util/*)
            MODULE="utils/${1#util/}"
            shift
            ;;
        day0|bsp|os|postgresql|postgresql/*|utils/*|mods/*)
            MODULE="$1"
            shift
            ;;
        install)
            MODULE="${2:-day0}"
            case "$MODULE" in
                deeptune|deep-tune|bsp/deeptune|bsp/deep-tune) MODULE="deeptune" ;;
                ntfy)                                          MODULE="mods/ntfy" ;;
                tailscale)                                     MODULE="mods/tailscale" ;;
                util/*)                                        MODULE="utils/${MODULE#util/}" ;;
            esac
            shift $(( $# >= 2 ? 2 : 1 ))
            ;;
    esac
fi

IS_CORE_STAGE="false"
case "$MODULE" in
    day0|os|bsp|deeptune) IS_CORE_STAGE="true" ;;
esac

CLI_SOC=""
CLI_BOARD=""
CLI_OS=""
STAGE_DIR=""
WITH_DEEPTUNE="false"
DEEPTUNE_TUNE=""
DEEPTUNE_STATUS_ONLY="false"
WITH_TAILSCALE="false"
TS_AUTHKEY_CLI=""
TS_EXTRA_ARGS=()

COMMON_STAGE_ARGS=()
OS_STAGE_ARGS=()
BSP_STAGE_ARGS=()
DEEPTUNE_STAGE_ARGS=()
FORWARD_ARGS=()

_require_opt_arg() {
    local opt="$1"
    local val="${2:-}"
    if [[ -z "$val" || "$val" == --* ]]; then
        log_fatal "Option '${opt}' requires an argument (try --help)"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --soc)
            _require_opt_arg "$1" "${2:-}"
            CLI_SOC="$2"; shift 2 ;;
        --board)
            _require_opt_arg "$1" "${2:-}"
            CLI_BOARD="$2"; shift 2 ;;
        --os)
            _require_opt_arg "$1" "${2:-}"
            CLI_OS="$2"; shift 2 ;;
        --stage-dir)
            _require_opt_arg "$1" "${2:-}"
            STAGE_DIR="$2"; shift 2 ;;
        --stage-dir=*)
            STAGE_DIR="${1#*=}"
            [[ -z "$STAGE_DIR" ]] && log_fatal "Option '--stage-dir=' requires a directory argument (try --help)"
            shift ;;
        --no-apt-update|--skip-apt-update)
            export RVDK_NO_APT_UPDATE="1"
            COMMON_STAGE_ARGS+=("--no-apt-update")
            FORWARD_ARGS+=("--no-apt-update")
            shift ;;
        --noprogbar|--no-progbar)
            export RVDK_NO_PROGBAR="1"
            COMMON_STAGE_ARGS+=("--noprogbar")
            FORWARD_ARGS+=("--noprogbar")
            shift ;;
        -h|--help)
            WANT_SUB_HELP="true"
            NEED_ROOT="false"
            COMMON_STAGE_ARGS+=("--help")
            FORWARD_ARGS+=("--help")
            shift ;;
        --deeptune|--deep-tune|--with-deeptune)
            WITH_DEEPTUNE="true"; shift ;;
        -t|--tune)
            _require_opt_arg "$1" "${2:-}"
            DEEPTUNE_TUNE="$2"
            [[ "$MODULE" != "deeptune" ]] && WITH_DEEPTUNE="true"
            shift 2 ;;
        --tune=*)
            DEEPTUNE_TUNE="${1#*=}"
            [[ -z "$DEEPTUNE_TUNE" ]] && log_fatal "Option '--tune=' requires an argument (expected: data | ai | iot)"
            [[ "$MODULE" != "deeptune" ]] && WITH_DEEPTUNE="true"
            shift ;;
        data|ai|ml|edge-ai|edge-ml|iot|edge-iot|sensor|mcu)
            if [[ "$MODULE" == "deeptune" ]]; then
                DEEPTUNE_TUNE="$1"
            elif [[ "$IS_CORE_STAGE" == "true" ]]; then
                log_fatal "Unknown argument: $1 (did you mean --tune $1?)"
            else
                FORWARD_ARGS+=("$1")
            fi
            shift ;;
        status|--status)
            if [[ "$MODULE" == "deeptune" ]]; then
                DEEPTUNE_STATUS_ONLY="true"
                NEED_ROOT="false"
            elif [[ "$IS_CORE_STAGE" == "true" ]]; then
                log_fatal "Unknown argument: $1 (try --help)"
            else
                FORWARD_ARGS+=("$1")
            fi
            shift ;;
        --with-tailscale|--tailscale)
            WITH_TAILSCALE="true"; shift ;;
        --tailscale-up|--ts-up)
            WITH_TAILSCALE="true"; TS_EXTRA_ARGS+=("--up"); shift ;;
        --tailscale-ssh|--ts-ssh)
            WITH_TAILSCALE="true"; TS_EXTRA_ARGS+=("--ssh"); shift ;;
        --tailscale-authkey|--ts-authkey)
            _require_opt_arg "$1" "${2:-}"
            WITH_TAILSCALE="true"; TS_AUTHKEY_CLI="$2"; shift 2 ;;
        --tailscale-routes)
            _require_opt_arg "$1" "${2:-}"
            WITH_TAILSCALE="true"; TS_EXTRA_ARGS+=("--advertise-routes" "$2"); shift 2 ;;

        # --- OS Stage Flags ---
        -u|--user)
            if [[ "$IS_CORE_STAGE" == "true" ]]; then
                _require_opt_arg "$1" "${2:-}"
                OS_STAGE_ARGS+=("--user" "$2")
            else
                _require_opt_arg "$1" "${2:-}"
                FORWARD_ARGS+=("$1" "$2")
            fi
            shift 2 ;;
        -H|--hostname)
            if [[ "$IS_CORE_STAGE" == "true" ]]; then
                _require_opt_arg "$1" "${2:-}"
                OS_STAGE_ARGS+=("--hostname" "$2")
            else
                _require_opt_arg "$1" "${2:-}"
                FORWARD_ARGS+=("$1" "$2")
            fi
            shift 2 ;;
        -n|--nopasswd|--passwordless-sudo)
            if [[ "$IS_CORE_STAGE" == "true" ]]; then
                OS_STAGE_ARGS+=("--nopasswd")
            else
                FORWARD_ARGS+=("$1")
            fi
            shift ;;
        --prompt-password|--debloat-only|--keep-gui|--skip-locale)
            if [[ "$IS_CORE_STAGE" == "true" ]]; then
                OS_STAGE_ARGS+=("$1")
            else
                FORWARD_ARGS+=("$1")
            fi
            shift ;;
        --keep-mirrors)
            export RVDK_KEEP_VENDOR_MIRRORS="1"
            if [[ "$IS_CORE_STAGE" == "true" ]]; then
                OS_STAGE_ARGS+=("--keep-mirrors")
            else
                FORWARD_ARGS+=("--keep-mirrors")
            fi
            shift ;;
        --skip-net-guard)
            export RVDK_SKIP_NET_GUARD="1"
            if [[ "$IS_CORE_STAGE" == "true" ]]; then
                OS_STAGE_ARGS+=("--skip-net-guard")
            else
                FORWARD_ARGS+=("--skip-net-guard")
            fi
            shift ;;
        --distro)
            _require_opt_arg "$1" "${2:-}"
            if [[ "$IS_CORE_STAGE" == "true" ]]; then
                OS_STAGE_ARGS+=("--distro" "$2")
            else
                FORWARD_ARGS+=("--distro" "$2")
            fi
            shift 2 ;;

        # --- BSP Stage Flags ---
        --expose-kallsyms|--skip-upgrade|--full-upgrade|--with-vendor-repo)
            if [[ "$IS_CORE_STAGE" == "true" ]]; then
                BSP_STAGE_ARGS+=("$1")
            else
                FORWARD_ARGS+=("$1")
            fi
            shift ;;
        --debian-suite)
            _require_opt_arg "$1" "${2:-}"
            if [[ "$IS_CORE_STAGE" == "true" ]]; then
                BSP_STAGE_ARGS+=("--debian-suite" "$2")
            else
                FORWARD_ARGS+=("--debian-suite" "$2")
            fi
            shift 2 ;;

        # --- DeepTune Flags ---
        --force)
            if [[ "$MODULE" == "deeptune" || "$WITH_DEEPTUNE" == "true" ]]; then
                DEEPTUNE_STAGE_ARGS+=("--force")
            elif [[ "$IS_CORE_STAGE" == "true" ]]; then
                log_fatal "Unknown argument: $1 (try --help)"
            else
                FORWARD_ARGS+=("--force")
            fi
            shift ;;

        *)
            if [[ "$IS_CORE_STAGE" == "true" ]]; then
                log_fatal "Unknown argument: $1 (try --help)"
            fi
            FORWARD_ARGS+=("$1")
            shift ;;
    esac
done

if [[ -n "$STAGE_DIR" ]]; then
    if [[ "$STAGE_DIR" == "/" || "$STAGE_DIR" =~ [[:cntrl:]] ]]; then
        log_fatal "Unsafe --stage-dir: '${STAGE_DIR}'."
    fi
    if [[ "$MODULE" == "os" ]]; then
        log_fatal "Flag '--stage-dir' is not valid for 'rvdk os' (use 'rvdk deeptune', 'rvdk bsp', or 'rvdk day0')"
    fi
    if [[ "$MODULE" == "deeptune" || "$WITH_DEEPTUNE" == "true" ]]; then
        DEEPTUNE_STAGE_ARGS+=("--stage-dir" "$STAGE_DIR")
    fi
    if [[ "$MODULE" == "day0" || "$MODULE" == "bsp" ]]; then
        BSP_STAGE_ARGS+=("--stage-dir" "$STAGE_DIR")
    fi
    if [[ "$IS_CORE_STAGE" != "true" ]]; then
        FORWARD_ARGS+=("--stage-dir" "$STAGE_DIR")
    fi
fi

if [[ "$WANT_SUB_HELP" != "true" && -n "$DEEPTUNE_TUNE" ]]; then
    case "$(tr '[:upper:]' '[:lower:]' <<< "$DEEPTUNE_TUNE")" in
        data|ai|ml|edge-ai|edge-ml|iot|edge-iot|sensor|mcu) ;;
        *) log_fatal "Invalid --tune '${DEEPTUNE_TUNE}' (expected: data | ai | iot)" ;;
    esac
fi

# Reject stage-mismatched flags on single-stage invocations (`rvdk os` vs `rvdk bsp` vs `rvdk deeptune`)
if [[ "$WANT_SUB_HELP" != "true" ]]; then
    if [[ "$MODULE" == "os" && ${#BSP_STAGE_ARGS[@]} -gt 0 ]]; then
        log_fatal "BSP flag '${BSP_STAGE_ARGS[0]}' is not valid for 'rvdk os' (use 'rvdk bsp' or 'rvdk day0')"
    fi
    if [[ "$MODULE" == "bsp" && ${#OS_STAGE_ARGS[@]} -gt 0 ]]; then
        log_fatal "OS flag '${OS_STAGE_ARGS[0]}' is not valid for 'rvdk bsp' (use 'rvdk os' or 'rvdk day0')"
    fi
    if [[ "$MODULE" == "deeptune" && ( ${#OS_STAGE_ARGS[@]} -gt 0 || ${#BSP_STAGE_ARGS[@]} -gt 0 ) ]]; then
        _bad_dt_flag="${OS_STAGE_ARGS[0]:-${BSP_STAGE_ARGS[0]}}"
        log_fatal "Flag '${_bad_dt_flag}' is not valid for 'rvdk deeptune' (try --help)"
    fi
fi

# Dispatch `utils/*` early (e.g. `sudo rvdk utils/purge-user.sh <user>`)
if [[ "$MODULE" == utils/* ]]; then
    if [[ "$MODULE" == *".."* ]]; then
        log_fatal "Invalid utility path: ${MODULE}"
    fi
    TARGET_UTIL="${LOCAL_ROOT}/${MODULE%.sh}.sh"
    [[ ! -f "$TARGET_UTIL" ]] && log_fatal "Utility script not found: ${TARGET_UTIL}"
    exec bash "$TARGET_UTIL" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
fi

if [[ "$WANT_SUB_HELP" == "true" ]]; then
    case "$MODULE" in
        day0)
            print_cli_help
            exit 0
            ;;
        os)
            exec bash "${LOCAL_ROOT}/os/bootstrap-apt.sh" --help
            ;;
        deeptune)
            _dt_help_args=()
            [[ -n "$CLI_SOC" ]]   && _dt_help_args+=("--soc" "$CLI_SOC")
            [[ -n "$CLI_BOARD" ]] && _dt_help_args+=("--board" "$CLI_BOARD")
            [[ -n "$CLI_OS" ]]    && _dt_help_args+=("--os" "$CLI_OS")
            if [[ ! -r "${RVDK_KIT_CACHE_FILE:-/etc/rvdk/kit.env}" || ${#_dt_help_args[@]} -gt 0 ]]; then
                _dt_help_args=("--no-cache" ${_dt_help_args[@]+"${_dt_help_args[@]}"})
            fi
            rvdk_kit_resolve ${_dt_help_args[@]+"${_dt_help_args[@]}"} || true

            _dt_help_printed="false"
            while IFS= read -r _dt_help_script; do
                [[ -n "$_dt_help_script" ]] || continue
                bash "$_dt_help_script" --help
                _dt_help_printed="true"
            done < <(rvdk_collect_deeptune_scripts "$LOCAL_ROOT")
            [[ "$_dt_help_printed" == "true" ]] || print_cli_help
            exit 0
            ;;
        postgresql)
            exec bash "${LOCAL_ROOT}/postgresql/latest/forge.sh" --help
            ;;
        mods/*|postgresql/*)
            if [[ "$MODULE" == *".."* ]]; then
                log_fatal "Invalid module path: ${MODULE}"
            fi
            exec bash "${LOCAL_ROOT}/${MODULE}/forge.sh" --help
            ;;
    esac
fi

_rvdk_guard_nommu_modules() {
    local arch="${RVDK_ARCH:-}"
    local mmu="${RVDK_MMU:-}"
    local soc_label="${BOARD_PATH:-${SOC_PATH:-unknown}}"
    if [[ "$arch" == "riscv32" || "$mmu" == "none" ]]; then
        if [[ "$WITH_TAILSCALE" == "true" ]]; then
            log_fatal "Option '--with-tailscale' is unsupported on riscv32 / nommu (${soc_label}; arch=${arch:-unknown}, mmu=${mmu:-unknown}): Tailscale requires a Go linux/riscv64 runtime and MMU-backed Linux networking."
        fi
        case "$MODULE" in
            postgresql|postgresql/*)
                log_fatal "Module '${MODULE}' is unsupported on riscv32 / nommu (${soc_label}; arch=${arch:-unknown}, mmu=${mmu:-unknown}): PostgreSQL 18.6 io_uring requires riscv64 with hardware MMU (Sv39/Sv48/Sv57) and NVMe/LVM storage."
                ;;
            mods/nvme-4kn|mods/nvme-4kn/*|mods/btrfs-raid|mods/btrfs-raid/*|mods/nfs-vault|mods/nfs-vault/*)
                log_fatal "Module '${MODULE}' is unsupported on riscv32 / nommu (${soc_label}; arch=${arch:-unknown}, mmu=${mmu:-unknown}): requires riscv64 with hardware MMU and PCIe/NVMe block storage."
                ;;
            mods/tailscale|mods/tailscale/*)
                log_fatal "Module 'mods/tailscale' is unsupported on riscv32 / nommu (${soc_label}; arch=${arch:-unknown}, mmu=${mmu:-unknown}): Tailscale requires a Go linux/riscv64 runtime and MMU-backed Linux networking."
                ;;
            mods/ntfy|mods/ntfy/*)
                log_fatal "Module '${MODULE}' is unsupported on riscv32 / nommu (${soc_label}; arch=${arch:-unknown}, mmu=${mmu:-unknown}): ntfy requires a Go linux/riscv64 runtime (GORISCV64) and MMU-backed Linux systemd service hosting."
                ;;
        esac
    fi
}

# 4. Resolve Hardware & OS Kit (loads /etc/rvdk/kit.env fast-path or probes & caches)
KIT_RESOLVE_ARGS=()
[[ -n "$CLI_SOC" ]]   && KIT_RESOLVE_ARGS+=("--soc" "$CLI_SOC")
[[ -n "$CLI_BOARD" ]] && KIT_RESOLVE_ARGS+=("--board" "$CLI_BOARD")
[[ -n "$CLI_OS" ]]    && KIT_RESOLVE_ARGS+=("--os" "$CLI_OS")

if [[ "$WANT_SUB_HELP" != "true" ]] && ! [[ "$MODULE" == "deeptune" && "$DEEPTUNE_STATUS_ONLY" == "true" ]]; then
    if [[ "$NEED_ROOT" == "true" && "${EUID:-$(id -u)}" -ne 0 ]]; then
        (
            rvdk_kit_resolve ${KIT_RESOLVE_ARGS[@]+"${KIT_RESOLVE_ARGS[@]}"} || true
            SOC_PATH="${RVDK_SOC:-}"
            BOARD_PATH="${RVDK_BOARD:-}"
            _rvdk_guard_nommu_modules
        ) || exit 1
    fi
    _escalate_root_if_needed
fi

rvdk_kit_resolve ${KIT_RESOLVE_ARGS[@]+"${KIT_RESOLVE_ARGS[@]}"}

SOC_PATH="${RVDK_SOC:-}"
BOARD_PATH="${RVDK_BOARD:-}"
OS_ID="${RVDK_OS_ID:-unknown}"
DT_MODEL="${RVDK_DT_MODEL:-Unknown}"

_rvdk_guard_nommu_modules

[[ -z "$SOC_PATH" ]] && log_fatal "Unrecognized RISC-V Device Tree: '${DT_MODEL}'. Pass --soc <vendor/soc> or --board <board>."
[[ -z "$OS_ID" || "$OS_ID" == "unknown" ]] && log_fatal "Cannot detect OS distribution. Pass --os <debian|ubuntu|bianbu|openwrt|esp-idf|nuttx|buildroot|linux-nommu>."

DEEPTUNE_STATE_FILE="${RVDK_DEEPTUNE_ENV:-/etc/rvdk/deeptune.env}"
LEGACY_DEEPTUNE_STATE="/var/lib/rvdk/deeptune.conf"

read_saved_tune() {
    local sf=""
    if [[ -n "$STAGE_DIR" && -r "${STAGE_DIR}/config/deeptune.env" ]]; then
        sf="${STAGE_DIR}/config/deeptune.env"
    elif [[ -r "$DEEPTUNE_STATE_FILE" ]]; then
        sf="$DEEPTUNE_STATE_FILE"
    elif [[ -r "$LEGACY_DEEPTUNE_STATE" ]]; then
        sf="$LEGACY_DEEPTUNE_STATE"
    fi
    if [[ -n "$sf" ]]; then
        local RVDK_TUNE=""
        if typeset -f rvdk_kv_load >/dev/null 2>&1; then
            rvdk_kv_load "$sf" RVDK_TUNE
            printf '%s\n' "$RVDK_TUNE"
        else
            awk -F= '/^RVDK_TUNE=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$sf" 2>/dev/null || true
        fi
    fi
}

# Handle `rvdk deeptune status` (read-only across all Kit layers)
if [[ "$MODULE" == "deeptune" && "$DEEPTUNE_STATUS_ONLY" == "true" ]]; then
    SAVED_TUNE="$(read_saved_tune)"
    if [[ -d /sys/kernel/mm/transparent_hugepage ]]; then
        THP_EN="$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "unknown")"
        THP_DEF="$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || echo "unknown")"
    elif [[ "${RVDK_MMU:-}" == "none" ]]; then
        THP_EN="unavailable (nommu)"
        THP_DEF="unavailable (nommu)"
    else
        THP_EN="unknown"
        THP_DEF="unknown"
    fi

    DT_LAYERS=()
    while IFS= read -r s; do
        [[ -n "$s" ]] && DT_LAYERS+=("${s#"${LOCAL_ROOT}"/}")
    done < <(rvdk_collect_deeptune_scripts "$LOCAL_ROOT")
    if (( ${#DT_LAYERS[@]} > 0 )); then
        LAYERS_STR="$(rvdk_join_by " -> " "${DT_LAYERS[@]}")"
    else
        LAYERS_STR="none"
    fi

    printf "\033[1;36m[RVDK:DEEPTUNE]\033[0m Multi-Layer Kit DeepTune Status\n"
    printf "  • Kit Identity      : board=%s | soc=%s | arch=%s | mmu=%s | os=%s | nic=%s\n" \
        "${BOARD_PATH:--}" "$SOC_PATH" "${RVDK_ARCH:-unknown}" "${RVDK_MMU:-unknown}" "$OS_ID" "${RVDK_PRIMARY_NIC:-none}"
    printf "  • Active Workload   : %s\n" "${SAVED_TUNE:-unconfigured}"
    printf "  • DeepTune Chain    : %s\n" "$LAYERS_STR"
    printf "  • Layer 1 (OS THP)  : enabled=%s | defrag=%s\n" "$THP_EN" "$THP_DEF"

    _dt_status_args=("status")
    [[ -n "$STAGE_DIR" ]] && _dt_status_args+=("--stage-dir" "$STAGE_DIR")
    [[ -f "${LOCAL_ROOT}/bsp/${SOC_PATH}/deeptune.sh" ]] && bash "${LOCAL_ROOT}/bsp/${SOC_PATH}/deeptune.sh" "${_dt_status_args[@]}"
    [[ -n "$BOARD_PATH" && -f "${LOCAL_ROOT}/boards/${BOARD_PATH}/deeptune.sh" ]] && bash "${LOCAL_ROOT}/boards/${BOARD_PATH}/deeptune.sh" "${_dt_status_args[@]}"
    exit 0
fi

# Match OS-specific scripts first, falling back to a unified non-symlink forge.sh
# (excludes bootstrap.sh symlinks to prevent recursion)
resolve_os_script() {
    local base_dir="$1"
    local candidate
    for candidate in \
        "${base_dir}/bootstrap-${OS_ID}.sh" \
        "${base_dir}/forge-${OS_ID}.sh" \
        "${base_dir}/forge_${OS_ID}.sh" \
        "${base_dir}/forge.sh"; do
        if [[ -f "$candidate" && ! -L "$candidate" && -s "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

if [[ "$WANT_SUB_HELP" == "true" && "$MODULE" == "bsp" ]]; then
    BSP_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/bsp/${SOC_PATH}")" || log_fatal "Missing BSP script for ${SOC_PATH} (${OS_ID})"
    exec bash "$BSP_SCRIPT" --help
fi

rvdk_sync_cold_clock

export RVDK_APT_LIB="${LOCAL_ROOT}/lib/apt.sh"
_RVDK_OWN_APT_STAMP=""
if [[ -z "${RVDK_APT_STAMP_FILE:-}" ]]; then
    _RVDK_OWN_APT_STAMP="/run/rvdk-apt-$$.stamp"
    rm -f "$_RVDK_OWN_APT_STAMP" 2>/dev/null || true
    export RVDK_APT_STAMP_FILE="$_RVDK_OWN_APT_STAMP"
fi

_rvdk_cleanup_own_apt_stamp() {
    if [[ -n "${_RVDK_OWN_APT_STAMP:-}" ]]; then
        rm -f "$_RVDK_OWN_APT_STAMP" 2>/dev/null || true
    fi
}

sync_apt_stamp() {
    if [[ -n "${RVDK_APT_STAMP_FILE:-}" && -f "$RVDK_APT_STAMP_FILE" ]]; then
        export RVDK_NO_APT_UPDATE="1"
    fi
}

export RVDK_PROGBAR_LIB="${LOCAL_ROOT}/lib/progbar.sh"
if [[ -z "${_RVDK_PROGBAR_SH_LOADED:-}" ]]; then
    if [[ -f "$RVDK_PROGBAR_LIB" ]]; then
        # shellcheck disable=SC1090
        source "$RVDK_PROGBAR_LIB"
    else
        rvdk_prog_init() { :; }
        rvdk_prog()      { :; }
    fi
fi

if [[ -n "$_RVDK_OWN_APT_STAMP" ]]; then
    if typeset -f rvdk_register_cleanup >/dev/null 2>&1; then
        rvdk_register_cleanup _rvdk_cleanup_own_apt_stamp
    fi
fi

rvdk_prog_init "${MODULE} (${BOARD_PATH:-$SOC_PATH})"

if [[ -n "$_RVDK_OWN_APT_STAMP" ]] && ! typeset -f rvdk_register_cleanup >/dev/null 2>&1; then
    case "$(trap -p EXIT 2>/dev/null || true)" in
        *rvdk_prog_cleanup*) ;;
        '')
            trap '_rvdk_cleanup_own_apt_stamp' EXIT
            [[ -z "$(trap -p INT 2>/dev/null || true)" ]] && trap '_rvdk_cleanup_own_apt_stamp; trap - INT; kill -INT $$' INT
            [[ -z "$(trap -p TERM 2>/dev/null || true)" ]] && trap '_rvdk_cleanup_own_apt_stamp; trap - TERM; kill -TERM $$' TERM
            ;;
    esac
fi
log_rvdk "Kit: board=${BOARD_PATH:-generic} | soc=${SOC_PATH} | os=${OS_ID} (${RVDK_KIT_SOURCE:-probed}) | Module: ${MODULE}"

# Execute collected DeepTune layers (`os/deeptune.sh` -> `bsp/<soc>/deeptune.sh` -> `boards/<board>/deeptune.sh`)
run_kit_deeptune() {
    local base_pct="${1:-0}"
    local span_pct="${2:-100}"

    local prev_tune
    prev_tune="$(read_saved_tune)"
    local raw_tune="${DEEPTUNE_TUNE:-${prev_tune:-data}}"
    raw_tune="$(printf '%s' "$raw_tune" | tr '[:upper:]' '[:lower:]')"

    local tune_mode tune_label
    case "$raw_tune" in
        data)                    tune_mode="data"; tune_label="data" ;;
        ai|ml|edge-ai|edge-ml)   tune_mode="ai";   tune_label="ai" ;;
        iot|edge-iot|sensor|mcu) tune_mode="iot";  tune_label="iot" ;;
        *) log_fatal "Invalid --tune '${raw_tune}' (expected: data | ai | iot)" ;;
    esac

    local dt_scripts=()
    local s
    while IFS= read -r s; do
        [[ -n "$s" ]] && dt_scripts+=("$s")
    done < <(rvdk_collect_deeptune_scripts "$LOCAL_ROOT")

    local exec_scripts=()
    local rel
    for s in ${dt_scripts[@]+"${dt_scripts[@]}"}; do
        rel="${s#"${LOCAL_ROOT}"/}"
        if [[ "$rel" == os/deeptune*.sh ]] && [[ -n "$STAGE_DIR" || ! -d /proc/sys || "$OS_ID" == "esp-idf" || "$OS_ID" == "nuttx" ]]; then
            log_skip "Skipping ${rel} (stage-dir mode or Linux /proc/sys unavailable)"
            continue
        fi
        exec_scripts+=("$s")
    done

    if [[ ${#exec_scripts[@]} -eq 0 ]]; then
        log_rvdk "[SKIP] No deeptune.sh layers found for ${SOC_PATH}"
        return 0
    fi

    local effective_tune="$tune_label"
    local effective_mode="$tune_mode"
    if [[ ( "${RVDK_MMU:-}" == "none" || "${RVDK_ARCH:-}" == "riscv32" ) && "$tune_label" == "data" ]]; then
        effective_tune="iot"
        effective_mode="iot"
    fi

    if [[ -n "$prev_tune" && "$prev_tune" != "$effective_tune" ]]; then
        log_rvdk "Flipping Kit DeepTune: '${prev_tune}' -> '${effective_tune}' (${#exec_scripts[@]} layers)..."
    else
        log_rvdk "Applying Kit DeepTune (--tune ${effective_tune} | ${#exec_scripts[@]} layers)..."
    fi

    local count="${#exec_scripts[@]}"
    local idx=0
    local rel_layers=()
    for s in "${exec_scripts[@]}"; do
        sync_apt_stamp
        local l_base=$(( base_pct + (span_pct * idx) / count ))
        local l_next=$(( base_pct + (span_pct * (idx + 1)) / count ))
        local l_span=$(( l_next - l_base ))
        (( l_span < 1 )) && l_span=1
        rel="${s#"${LOCAL_ROOT}"/}"
        rel_layers+=("$rel")

        local layer_args=("--tune" "$tune_label")
        [[ "${RVDK_NO_APT_UPDATE:-0}" == "1" ]] && layer_args+=("--no-apt-update")
        [[ "${RVDK_NO_PROGBAR:-0}" == "1" ]] && layer_args+=("--noprogbar")

        log_rvdk "DeepTune Layer $((idx + 1))/${count}: ${rel} (--tune ${tune_label})..."
        RVDK_TUNE="$tune_label" RVDK_PROG_BASE="$l_base" RVDK_PROG_SPAN="$l_span" \
            bash "$s" "${layer_args[@]}" ${DEEPTUNE_STAGE_ARGS[@]+"${DEEPTUNE_STAGE_ARGS[@]}"}
        idx=$((idx + 1))
    done

    local state_target="$DEEPTUNE_STATE_FILE"
    if [[ -n "$STAGE_DIR" ]]; then
        state_target="${STAGE_DIR}/config/deeptune.env"
    fi
    local skip_state_write="false"
    if [[ ( "${RVDK_MMU:-}" == "none" || "${RVDK_ARCH:-}" == "riscv32" ) && -r "$state_target" ]]; then
        local RVDK_TUNE="" RVDK_SDKCONFIG_FRAGMENT=""
        if typeset -f rvdk_kv_load >/dev/null 2>&1; then
            rvdk_kv_load "$state_target" RVDK_TUNE RVDK_SDKCONFIG_FRAGMENT || true
        else
            RVDK_TUNE="$(awk -F= '/^RVDK_TUNE=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$state_target" 2>/dev/null || true)"
            RVDK_SDKCONFIG_FRAGMENT="$(awk -F= '/^RVDK_SDKCONFIG_FRAGMENT=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$state_target" 2>/dev/null || true)"
        fi
        if [[ -n "$RVDK_SDKCONFIG_FRAGMENT" || "$RVDK_TUNE" == "$effective_tune" ]]; then
            skip_state_write="true"
        fi
    fi

    if [[ "$skip_state_write" != "true" ]]; then
        local layers_joined
        layers_joined="$(IFS=','; echo "${rel_layers[*]}")"
        rvdk_kv_write "$state_target" 0644 "Managed by RVDK (rvdk deeptune)" \
            "RVDK_TUNE=${effective_tune}" \
            "RVDK_TUNE_MODE=${effective_mode}" \
            "RVDK_SOC=${SOC_PATH}" \
            "RVDK_BOARD=${BOARD_PATH}" \
            "RVDK_OS_ID=${OS_ID}" \
            "RVDK_DEEPTUNE_LAYERS=${layers_joined}"
    fi
    if [[ -z "$STAGE_DIR" ]]; then
        rm -f "$LEGACY_DEEPTUNE_STATE" 2>/dev/null || true
    fi
}

run_optional_deeptune() {
    local base_pct="${1:-75}"
    local span_pct="${2:-25}"
    run_kit_deeptune "$base_pct" "$span_pct"
}

run_optional_tailscale() {
    local base_pct="${1:-80}"
    local span_pct="${2:-20}"
    local ts_script="${LOCAL_ROOT}/mods/tailscale/forge.sh"
    [[ ! -f "$ts_script" ]] && log_fatal "Tailscale module not found: ${ts_script}"
    sync_apt_stamp
    log_rvdk "Optional Add-On: Tailscale Mesh VPN (${ts_script})..."
    local ts_args=()
    [[ "${RVDK_NO_APT_UPDATE:-0}" == "1" ]] && ts_args+=("--no-apt-update")
    [[ "${RVDK_NO_PROGBAR:-0}" == "1" ]] && ts_args+=("--noprogbar")
    if [[ -n "$TS_AUTHKEY_CLI" ]]; then
        TS_AUTHKEY="$TS_AUTHKEY_CLI" RVDK_PROG_BASE="$base_pct" RVDK_PROG_SPAN="$span_pct" \
            bash "$ts_script" ${ts_args[@]+"${ts_args[@]}"} ${TS_EXTRA_ARGS[@]+"${TS_EXTRA_ARGS[@]}"}
    else
        RVDK_PROG_BASE="$base_pct" RVDK_PROG_SPAN="$span_pct" \
            bash "$ts_script" ${ts_args[@]+"${ts_args[@]}"} ${TS_EXTRA_ARGS[@]+"${TS_EXTRA_ARGS[@]}"}
    fi
}

run_addon_tail() {
    if [[ "$WITH_DEEPTUNE" == "true" && "$WITH_TAILSCALE" == "true" ]]; then
        run_optional_deeptune 70 15
        run_optional_tailscale 85 15
    elif [[ "$WITH_DEEPTUNE" == "true" ]]; then
        run_optional_deeptune 75 25
    elif [[ "$WITH_TAILSCALE" == "true" ]]; then
        run_optional_tailscale 80 20
    fi
}

bsp_requests_pre_os_order() {
    local script_path="$1"
    [[ -r "$script_path" ]] || return 1
    awk '/^#[[:space:]]*@RVDK_DAY0_ORDER:[[:space:]]*pre-os([[:space:]]|$)/ { found=1; exit } END { exit !found }' "$script_path" 2>/dev/null
}

# 5. Dispatch Module (Use `bash`, not `exec bash`, so standalone progress bar EXIT trap tears down cleanly)
case "$MODULE" in
    day0)
        if [[ "$WITH_DEEPTUNE" == "true" && "$WITH_TAILSCALE" == "true" ]]; then
            S1_SPAN=40; S2_BASE=40; S2_SPAN=30
        elif [[ "$WITH_DEEPTUNE" == "true" || "$WITH_TAILSCALE" == "true" ]]; then
            S1_SPAN=45; S2_BASE=45; S2_SPAN=30
        else
            S1_SPAN=55; S2_BASE=55; S2_SPAN=45
        fi
        BSP_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/bsp/${SOC_PATH}")" || log_fatal "Missing BSP script for ${SOC_PATH} (${OS_ID})"
        if [[ "${RVDK_MMU:-}" == "none" || "${RVDK_ARCH:-}" == "riscv32" || "$OS_ID" == "esp-idf" || "$OS_ID" == "nuttx" || "$OS_ID" == "buildroot" || "$OS_ID" == "linux-nommu" ]]; then
            log_skip "Skipping os/bootstrap-apt.sh for ${SOC_PATH} (os=${OS_ID}, arch=${RVDK_ARCH:-unknown}, mmu=${RVDK_MMU:-unknown})"
            local_bsp_span=100
            [[ "$WITH_DEEPTUNE" == "true" || "$WITH_TAILSCALE" == "true" ]] && local_bsp_span=75
            log_rvdk "Stage 1/1: Silicon BSP Hardening (${BSP_SCRIPT})..."
            RVDK_PROG_BASE=0 RVDK_PROG_SPAN="$local_bsp_span" bash "$BSP_SCRIPT" \
                ${COMMON_STAGE_ARGS[@]+"${COMMON_STAGE_ARGS[@]}"} \
                ${BSP_STAGE_ARGS[@]+"${BSP_STAGE_ARGS[@]}"}
        else
            OS_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/os")" || log_fatal "Missing OS script for ${OS_ID}"
            if bsp_requests_pre_os_order "$BSP_SCRIPT"; then
                log_rvdk "Stage 1/2: Silicon BSP Pre-OS Hardening (${BSP_SCRIPT})..."
                RVDK_PROG_BASE=0 RVDK_PROG_SPAN="$S1_SPAN" bash "$BSP_SCRIPT" \
                    ${COMMON_STAGE_ARGS[@]+"${COMMON_STAGE_ARGS[@]}"} \
                    ${BSP_STAGE_ARGS[@]+"${BSP_STAGE_ARGS[@]}"}
                sync_apt_stamp
                log_rvdk "Stage 2/2: OS Normalization & IPv4 IP-Options / MPTCP Guard (${OS_SCRIPT})..."
                RVDK_PROG_BASE="$S2_BASE" RVDK_PROG_SPAN="$S2_SPAN" bash "$OS_SCRIPT" \
                    ${COMMON_STAGE_ARGS[@]+"${COMMON_STAGE_ARGS[@]}"} \
                    ${OS_STAGE_ARGS[@]+"${OS_STAGE_ARGS[@]}"}
            else
                log_rvdk "Stage 1/2: OS Normalization & IPv4 IP-Options / MPTCP Guard (${OS_SCRIPT})..."
                RVDK_PROG_BASE=0 RVDK_PROG_SPAN="$S1_SPAN" bash "$OS_SCRIPT" \
                    ${COMMON_STAGE_ARGS[@]+"${COMMON_STAGE_ARGS[@]}"} \
                    ${OS_STAGE_ARGS[@]+"${OS_STAGE_ARGS[@]}"}
                sync_apt_stamp
                log_rvdk "Stage 2/2: Silicon BSP Hardening (${BSP_SCRIPT})..."
                RVDK_PROG_BASE="$S2_BASE" RVDK_PROG_SPAN="$S2_SPAN" bash "$BSP_SCRIPT" \
                    ${COMMON_STAGE_ARGS[@]+"${COMMON_STAGE_ARGS[@]}"} \
                    ${BSP_STAGE_ARGS[@]+"${BSP_STAGE_ARGS[@]}"}
            fi
        fi
        # Refresh /etc/rvdk/kit.env after Day-0 networkd/interface changes (skip on host-staged runs)
        if [[ -z "$STAGE_DIR" ]]; then
            rvdk_kit_resolve --refresh ${KIT_RESOLVE_ARGS[@]+"${KIT_RESOLVE_ARGS[@]}"}
        fi
        run_addon_tail
        rvdk_prog 100 "Day-0 OS + Silicon BSP converged"
        ;;
    deeptune)
        if [[ "$WITH_TAILSCALE" == "true" ]]; then
            run_kit_deeptune 0 85
            run_optional_tailscale 85 15
        else
            run_kit_deeptune 0 100
        fi
        rvdk_prog 100 "Kit DeepTune (${BOARD_PATH:-$SOC_PATH}) converged"
        ;;
    os)
        if [[ "${RVDK_MMU:-}" == "none" || "${RVDK_ARCH:-}" == "riscv32" || "$OS_ID" == "esp-idf" || "$OS_ID" == "nuttx" || "$OS_ID" == "buildroot" || "$OS_ID" == "linux-nommu" ]]; then
            log_skip "Skipping os/bootstrap-apt.sh for ${SOC_PATH} (os=${OS_ID}, arch=${RVDK_ARCH:-unknown}, mmu=${RVDK_MMU:-unknown})"
            run_addon_tail
            rvdk_prog 100 "OS stage skipped (non-APT target)"
        else
            OS_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/os")" || log_fatal "Missing OS script for ${OS_ID}"
            bash "$OS_SCRIPT" \
                ${COMMON_STAGE_ARGS[@]+"${COMMON_STAGE_ARGS[@]}"} \
                ${OS_STAGE_ARGS[@]+"${OS_STAGE_ARGS[@]}"}
            run_addon_tail
            rvdk_prog 100 "OS normalization converged"
        fi
        ;;
    bsp)
        BSP_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/bsp/${SOC_PATH}")" || log_fatal "Missing BSP script for ${SOC_PATH} (${OS_ID})"
        bash "$BSP_SCRIPT" \
            ${COMMON_STAGE_ARGS[@]+"${COMMON_STAGE_ARGS[@]}"} \
            ${BSP_STAGE_ARGS[@]+"${BSP_STAGE_ARGS[@]}"}
        run_addon_tail
        rvdk_prog 100 "Silicon BSP converged"
        ;;
    postgresql)
        bash "${LOCAL_ROOT}/postgresql/latest/forge.sh" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        run_addon_tail
        rvdk_prog 100 "PostgreSQL 18.6 converged"
        ;;
    *)
        if [[ "$MODULE" == *".."* ]]; then
            log_fatal "Invalid module path: ${MODULE}"
        fi
        TARGET_MOD="${LOCAL_ROOT}/${MODULE}/forge.sh"
        [[ ! -f "$TARGET_MOD" ]] && log_fatal "Module script not found: ${TARGET_MOD}"
        if [[ "$MODULE" == "mods/tailscale" && -n "$TS_AUTHKEY_CLI" ]]; then
            TS_AUTHKEY="$TS_AUTHKEY_CLI" bash "$TARGET_MOD" ${TS_EXTRA_ARGS[@]+"${TS_EXTRA_ARGS[@]}"} ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
            [[ "$WITH_DEEPTUNE" == "true" ]] && run_optional_deeptune 80 20
        elif [[ "$MODULE" == "mods/tailscale" ]]; then
            bash "$TARGET_MOD" ${TS_EXTRA_ARGS[@]+"${TS_EXTRA_ARGS[@]}"} ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
            [[ "$WITH_DEEPTUNE" == "true" ]] && run_optional_deeptune 80 20
        else
            bash "$TARGET_MOD" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
            run_addon_tail
        fi
        rvdk_prog 100 "${MODULE} converged"
        ;;
esac

if [[ -n "$_RVDK_OWN_APT_STAMP" ]]; then
    rm -f "$_RVDK_OWN_APT_STAMP" 2>/dev/null || true
fi
