#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Universal Bare-Metal Dispatcher & CLI (`rvdk`)
# Path: riscv-data-kit/bootstrap.sh
#
# Usage (One-Shot Curl Day-0 OS + BSP Bootstrapper + CLI Install):
#   curl -fsSL https://rvdk.drewv-labs.dev/bootstrap.sh | sudo bash -s -- --user drew --hostname rv-node --nopasswd [--deeptune] [--tune data|ml|ai] [--with-tailscale]
#
# Usage (Local CLI after install-cli.sh or bootstrap.sh):
#   sudo rvdk [day0|bsp|os|deeptune|postgresql|mods/*|utils/purge-user.sh|update] [--deeptune] [--tune data|ml|ai] [--no-apt-update] [--with-tailscale] [--noprogbar]
#   rvdk kit [status|--refresh|--env]
#   sudo rvdk quirk <name|list> [off|on|toggle|status]
#   rvdk flash <board> <medium> <disk_or_flags...>
# ==============================================================================

# Ensure compatibility when invoked via `zsh` or `bash`
if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L ksh
    setopt PIPE_FAIL ERR_RETURN NO_UNSET
else
    set -Eeuo pipefail
fi

SCRIPT_SELF="${BASH_SOURCE[0]:-}"

# Determine whether root privileges are required before escalating.
# Host flashers (`rvdk flash ...`), Kit inspection (`rvdk kit`), help, and
# read-only status/list subcommands run unprivileged first.
NEED_ROOT="true"
if [[ $# -gt 0 ]]; then
    for _arg in "$@"; do
        case "$_arg" in
            -h|--help|help) NEED_ROOT="false" ;;
        esac
    done
    if [[ "$NEED_ROOT" == "true" ]]; then
        case "$1" in
            flash)
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
            quirk|quirks)
                case "${2:-list}" in
                    list|--list) NEED_ROOT="false" ;;
                    *)
                        case "${3:-}" in
                            status|--status|stat|check) NEED_ROOT="false" ;;
                        esac
                        ;;
                esac
                ;;
            deeptune|deep-tune|bsp/deeptune|bsp/deep-tune)
                for _arg in "$@"; do
                    case "$_arg" in
                        status|--status) NEED_ROOT="false" ;;
                    esac
                done
                ;;
        esac
    fi
fi

if [[ "$NEED_ROOT" == "true" && $EUID -ne 0 ]]; then
    if [[ -n "$SCRIPT_SELF" && -f "$SCRIPT_SELF" ]]; then
        exec sudo -E bash "$SCRIPT_SELF" "$@"
    else
        echo "[RVDK:FATAL] Pipe into 'sudo bash' or 'sudo zsh': curl -fsSL https://rvdk.drewv-labs.dev/bootstrap.sh | sudo bash" >&2
        exit 1
    fi
fi

# Sanitize SSH-forwarded LC_* (e.g. ZedBook / macOS SendEnv) before en_US.UTF-8 exists on target
if { locale -a 2>/dev/null || true; } | grep -qiE '^en_US\.utf-?8$'; then
    export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
elif { locale -a 2>/dev/null || true; } | grep -qiE '^C\.utf-?8$'; then
    export LANG="C.UTF-8" LC_ALL="C.UTF-8"
else
    export LANG="C" LC_ALL="C"
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo root)}"
REAL_GRP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
if command -v getent >/dev/null 2>&1; then
    REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || true)"
elif command -v dscl >/dev/null 2>&1; then
    REAL_HOME="$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
else
    REAL_HOME=""
fi
[[ -z "$REAL_HOME" ]] && REAL_HOME="$(eval echo "~${REAL_USER}" 2>/dev/null || true)"
[[ -z "$REAL_HOME" || "$REAL_HOME" == "~"* ]] && REAL_HOME="/root"

ENGINE_DIR="${REAL_HOME}/.rvdk/engine"
RVDK_BASE_URL="${RVDK_BASE_URL:-https://rvdk.drewv-labs.dev}"

log_rvdk()  { printf "\033[1;36m[RVDK]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

print_cli_help() {
    cat <<'EOF'
Usage:
  sudo rvdk [day0|bsp|os|deeptune|postgresql|mods/*|utils/purge-user.sh|update] [flags]
  rvdk kit [status|--refresh|--env]
  sudo rvdk quirk <name|list> [toggle|off|on|status] [--ephemeral|--persist]
  rvdk flash <board> <medium> <disk_or_flags...>
  rvdk flash list

Core Commands:
  day0                     Run full Day-0 (OS normalization + Silicon BSP) forge (default)
  bsp                      Run Silicon BSP hardening (`bsp/<vendor>/<soc>/`)
  os                       Run OS normalization & OpenSSH CVE guard (`os/`)
  deeptune [--tune <t>]    Run multi-layer headless DeepTune (`os` -> `bsp` -> `boards`)
                           Tunes: `data` (default) | `ml` | `ai`, or `rvdk deeptune status`
  kit [status|--refresh]   Inspect or refresh cached hardware/OS Kit (`/etc/rvdk/kit.env`)
  quirk <name|list> [...]  Toggle board-specific hardware quirks (`boards/<board>/quirks/`)
  flash <board> <medium>   Flash removable media on macOS/Linux (e.g. `rvdk flash p550 usb 4`)
  postgresql               Install or build PostgreSQL 18.6 (`--force-build` to compile)
  mods/<mod>               Converge storage/network mod (`nvme-4kn`, `btrfs-raid`, `mosquitto`, `nfs-vault`, `tailscale`)
  utils/purge-user.sh      Migrate state & purge factory default user account
  update                   Pull latest RVDK engine from GitHub

Global Add-On Flags:
  --deeptune               Append multi-layer DeepTune to any Day-0 / BSP / Mod run
  -t, --tune <data|ml|ai>  Target workload tune (also implies --deeptune on non-deeptune commands)
  --with-tailscale         Append Tailscale Mesh VPN module
  --no-apt-update          Skip apt-get update calls
  --noprogbar              Disable persistent bottom progress bar
EOF
}

if [[ $# -gt 0 ]] && [[ "$1" == "help" || "$1" == "-h" || "$1" == "--help" ]]; then
    print_cli_help
    exit 0
fi

# 1. Resolve RVDK Engine Root (`LOCAL_ROOT`)
if [[ -n "$SCRIPT_SELF" ]]; then
    SCRIPT_REAL="$(readlink -f "$SCRIPT_SELF" 2>/dev/null || realpath "$SCRIPT_SELF" 2>/dev/null || echo "$SCRIPT_SELF")"
    CANDIDATE_ROOT="$(cd "$(dirname "$SCRIPT_REAL")" && pwd)"
else
    CANDIDATE_ROOT=""
fi

if [[ "${1:-}" == "update" || "${1:-}" == "self-update" ]]; then
    shift
    if [[ -n "$CANDIDATE_ROOT" && -f "${CANDIDATE_ROOT}/install-cli.sh" ]]; then
        exec bash "${CANDIDATE_ROOT}/install-cli.sh" "$@"
    else
        curl -fsSL "${RVDK_BASE_URL}/install-cli.sh" | bash -s -- "$@"
        exit 0
    fi
fi

if [[ $EUID -ne 0 && -n "$CANDIDATE_ROOT" && -d "${CANDIDATE_ROOT}/bsp" ]]; then
    LOCAL_ROOT="$CANDIDATE_ROOT"
elif [[ -n "$CANDIDATE_ROOT" && -d "${CANDIDATE_ROOT}/bsp" ]] && ! [[ "$CANDIDATE_ROOT" == */.rvdk/engine && "$CANDIDATE_ROOT" != "$ENGINE_DIR" ]]; then
    LOCAL_ROOT="$CANDIDATE_ROOT"
    if [[ $EUID -eq 0 && ! -L /usr/local/bin/rvdk ]]; then
        install -d -m 0755 /usr/local/bin
        ln -sf "${LOCAL_ROOT}/bootstrap.sh" /usr/local/bin/rvdk
    fi
else
    if [[ "$CANDIDATE_ROOT" == */.rvdk/engine && "$CANDIDATE_ROOT" != "$ENGINE_DIR" && -d "${CANDIDATE_ROOT}/.git" && ! -d "${ENGINE_DIR}/.git" ]]; then
        install -d -m 0755 -o "$REAL_USER" -g "$REAL_GRP" "${REAL_HOME}/.rvdk" "${REAL_HOME}/.rvdk/cache"
        cp -a "$CANDIDATE_ROOT" "$ENGINE_DIR"
        chown -R "${REAL_USER}:${REAL_GRP}" "$ENGINE_DIR"
        install -d -m 0755 /usr/local/bin
        ln -sf "${ENGINE_DIR}/bootstrap.sh" /usr/local/bin/rvdk
    else
        curl -fsSL "${RVDK_BASE_URL}/install-cli.sh" | bash -s -- --quiet
    fi
    LOCAL_ROOT="$ENGINE_DIR"
fi

# Load Kit Inference & Cache Library
if [[ -f "${LOCAL_ROOT}/lib/kit.sh" ]]; then
    # shellcheck disable=SC1091
    source "${LOCAL_ROOT}/lib/kit.sh"
else
    log_fatal "Missing RVDK Kit library: ${LOCAL_ROOT}/lib/kit.sh"
fi

# ==============================================================================
# 2. Early Subcommands (`flash`, `kit`, `quirk`, `utils/*`)
# ==============================================================================

# 2.1 `rvdk flash <board> <medium> [disk_or_flags...]` (Host macOS/Linux Media Flashers)
if [[ "${1:-}" == "flash" ]]; then
    shift
    print_flash_targets() {
        printf "\033[1;36m[RVDK:FLASH]\033[0m Available Board Media Flashers:\n"
        local f rel b_path b_short m_name
        for f in "${LOCAL_ROOT}"/boards/*/*/flash-*.sh; do
            [[ -f "$f" ]] || continue
            rel="${f#${LOCAL_ROOT}/boards/}"
            b_path="${rel%/flash-*.sh}"
            b_short="${b_path##*/}"
            m_name="$(basename "$f" .sh)"
            m_name="${m_name#flash-}"
            printf "  • rvdk flash %-10s %-6s <disk>   (%s)\n" "$b_short" "$m_name" "boards/${rel}"
        done
    }

    if [[ $# -eq 0 || "${1:-}" == "list" || "${1:-}" == "--list" ]]; then
        print_flash_targets
        exit 0
    fi
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        cat <<'EOF'
Usage:
  rvdk flash <board> <medium> <disk_number_or_path> [--image /path/to/img] [--yes] [--force]
  rvdk flash list

Examples:
  rvdk flash p550 usb 4
  rvdk flash vf2 sd 4
  rvdk flash p550 usb --device /dev/sdX --image ~/custom.img.zst
EOF
        print_flash_targets
        exit 0
    fi

    FLASH_BOARD_QUERY="$1"
    shift
    FLASH_BOARD_DIR="$(rvdk_resolve_board_dir "$LOCAL_ROOT" "$FLASH_BOARD_QUERY" || true)"
    if [[ -z "$FLASH_BOARD_DIR" ]]; then
        print_flash_targets >&2
        log_fatal "Unknown board '${FLASH_BOARD_QUERY}'. Run 'rvdk flash list' to see supported boards."
    fi

    avail_media=()
    for mf in "${FLASH_BOARD_DIR}"/flash-*.sh; do
        [[ -f "$mf" ]] || continue
        mn="$(basename "$mf" .sh)"
        avail_media+=("${mn#flash-}")
    done

    if [[ $# -eq 0 || "${1:-}" == "list" || "${1:-}" == "--list" ]]; then
        log_rvdk "Board ${FLASH_BOARD_DIR#${LOCAL_ROOT}/boards/} media targets: ${avail_media[*]:-none}"
        log_fatal "Missing medium type. Usage: rvdk flash ${FLASH_BOARD_QUERY} <medium> <disk>"
    fi

    FLASH_MEDIUM="$(tr '[:upper:]' '[:lower:]' <<< "$1")"
    FLASH_MEDIUM="${FLASH_MEDIUM#flash-}"
    FLASH_MEDIUM="${FLASH_MEDIUM%.sh}"
    shift

    FLASH_SCRIPT="${FLASH_BOARD_DIR}/flash-${FLASH_MEDIUM}.sh"
    if [[ ! -f "$FLASH_SCRIPT" ]]; then
        log_fatal "Unsupported medium '${FLASH_MEDIUM}' for '${FLASH_BOARD_QUERY}' (available: ${avail_media[*]:-none}). Usage: rvdk flash ${FLASH_BOARD_QUERY} <medium> <disk>"
    fi

    exec bash "$FLASH_SCRIPT" "$@"
fi

# 2.2 `rvdk kit [status|--refresh|--env]`
if [[ "${1:-}" == "kit" ]]; then
    shift
    KIT_MODE="summary"
    KIT_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            status|--status|show) KIT_MODE="summary"; shift ;;
            --env|env)            KIT_MODE="env"; shift ;;
            --refresh|refresh)    KIT_ARGS+=("--refresh"); shift ;;
            --soc|--board|--os)   KIT_ARGS+=("$1" "${2:-}"); shift 2 ;;
            -h|--help)
                cat <<'EOF'
Usage:
  rvdk kit [status]          Show resolved Board, SoC, OS, NIC, DeepTune chain & Quirks
  sudo rvdk kit --refresh    Re-probe hardware/OS and update /etc/rvdk/kit.env
  rvdk kit --env             Print shell-sourceable RVDK_KIT_* variables
EOF
                exit 0
                ;;
            *) log_fatal "Unknown 'rvdk kit' option: $1" ;;
        esac
    done
    rvdk_kit_resolve ${KIT_ARGS[@]+"${KIT_ARGS[@]}"}
    if [[ "$KIT_MODE" == "env" ]]; then
        rvdk_kit_print_env
    else
        rvdk_kit_print_summary "$LOCAL_ROOT"
    fi
    exit 0
fi

# 2.3 `rvdk quirk <name|list> [args...]`
if [[ "${1:-}" == "quirk" || "${1:-}" == "quirks" ]]; then
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
                print_quirks_for_board "${bd#${LOCAL_ROOT}/boards/}"
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
    QUIRK_ARGS=("${QUIRK_REST[@]:1}")
    QUIRK_SCRIPT="${LOCAL_ROOT}/boards/${RVDK_BOARD}/quirks/${QUIRK_NAME}.sh"
    if [[ ! -f "$QUIRK_SCRIPT" ]]; then
        print_quirks_for_board "$RVDK_BOARD" >&2
        log_fatal "Quirk '${QUIRK_NAME}' not found for board '${RVDK_BOARD}'."
    fi

    exec bash "$QUIRK_SCRIPT" ${QUIRK_ARGS[@]+"${QUIRK_ARGS[@]}"}
fi

# ==============================================================================
# 3. Parse Standard Provisioning Subcommand & Flags
# ==============================================================================
MODULE="day0"
if [[ $# -gt 0 ]]; then
    case "$1" in
        deeptune|deep-tune|bsp/deeptune|bsp/deep-tune)
            MODULE="deeptune"
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
                tailscale)                                     MODULE="mods/tailscale" ;;
                util/*)                                        MODULE="utils/${MODULE#util/}" ;;
            esac
            shift $(( $# >= 2 ? 2 : 1 ))
            ;;
    esac
fi

CLI_SOC=""
CLI_BOARD=""
CLI_OS=""
WITH_DEEPTUNE="false"
DEEPTUNE_TUNE=""
DEEPTUNE_STATUS_ONLY="false"
WITH_TAILSCALE="false"
TS_AUTHKEY_CLI=""
TS_EXTRA_ARGS=()
FORWARD_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --soc)
            CLI_SOC="${2:-}"; shift 2 ;;
        --board)
            CLI_BOARD="${2:-}"; shift 2 ;;
        --os)
            CLI_OS="${2:-}"; shift 2 ;;
        --no-apt-update|--skip-apt-update)
            export RVDK_NO_APT_UPDATE="1"
            FORWARD_ARGS+=("--no-apt-update")
            shift ;;
        --deeptune|--deep-tune|--with-deeptune)
            WITH_DEEPTUNE="true"; shift ;;
        -t|--tune)
            DEEPTUNE_TUNE="${2:-}"
            [[ "$MODULE" != "deeptune" ]] && WITH_DEEPTUNE="true"
            shift 2 ;;
        --tune=*)
            DEEPTUNE_TUNE="${1#*=}"
            [[ "$MODULE" != "deeptune" ]] && WITH_DEEPTUNE="true"
            shift ;;
        data|ml|ai)
            if [[ "$MODULE" == "deeptune" ]]; then
                DEEPTUNE_TUNE="$1"
            else
                FORWARD_ARGS+=("$1")
            fi
            shift ;;
        status|--status)
            if [[ "$MODULE" == "deeptune" ]]; then
                DEEPTUNE_STATUS_ONLY="true"
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
            WITH_TAILSCALE="true"; TS_AUTHKEY_CLI="${2:-}"; shift 2 ;;
        --tailscale-routes)
            WITH_TAILSCALE="true"; TS_EXTRA_ARGS+=("--advertise-routes" "${2:-}"); shift 2 ;;
        --noprogbar|--no-progbar)
            export RVDK_NO_PROGBAR="1"; shift ;;
        *)
            FORWARD_ARGS+=("$1"); shift ;;
    esac
done

# Dispatch `utils/*` early (e.g. `sudo rvdk utils/purge-user.sh <user>`)
if [[ "$MODULE" == utils/* ]]; then
    TARGET_UTIL="${LOCAL_ROOT}/${MODULE%.sh}.sh"
    [[ ! -f "$TARGET_UTIL" ]] && log_fatal "Utility script not found: ${TARGET_UTIL}"
    exec bash "$TARGET_UTIL" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
fi

# 4. Resolve Hardware & OS Kit (loads /etc/rvdk/kit.env fast-path or probes & caches)
KIT_RESOLVE_ARGS=()
[[ -n "$CLI_SOC" ]]   && KIT_RESOLVE_ARGS+=("--soc" "$CLI_SOC")
[[ -n "$CLI_BOARD" ]] && KIT_RESOLVE_ARGS+=("--board" "$CLI_BOARD")
[[ -n "$CLI_OS" ]]    && KIT_RESOLVE_ARGS+=("--os" "$CLI_OS")
rvdk_kit_resolve ${KIT_RESOLVE_ARGS[@]+"${KIT_RESOLVE_ARGS[@]}"}

SOC_PATH="${RVDK_SOC:-}"
BOARD_PATH="${RVDK_BOARD:-}"
OS_ID="${RVDK_OS_ID:-unknown}"
DT_MODEL="${RVDK_DT_MODEL:-Unknown}"

[[ -z "$SOC_PATH" ]] && log_fatal "Unrecognized RISC-V Device Tree: '${DT_MODEL}'. Pass --soc <vendor/soc> or --board <board>."
[[ -z "$OS_ID" || "$OS_ID" == "unknown" ]] && log_fatal "Cannot detect OS distribution. Pass --os <debian|ubuntu|bianbu>."

DEEPTUNE_STATE_FILE="/etc/rvdk/deeptune.env"
LEGACY_DEEPTUNE_STATE="/var/lib/rvdk/deeptune.conf"

read_saved_tune() {
    local sf=""
    if [[ -r "$DEEPTUNE_STATE_FILE" ]]; then
        sf="$DEEPTUNE_STATE_FILE"
    elif [[ -r "$LEGACY_DEEPTUNE_STATE" ]]; then
        sf="$LEGACY_DEEPTUNE_STATE"
    fi
    if [[ -n "$sf" ]]; then
        awk -F= '/^RVDK_TUNE=/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$sf" 2>/dev/null || true
    fi
}

# Handle `rvdk deeptune status` (read-only across all Kit layers)
if [[ "$MODULE" == "deeptune" && "$DEEPTUNE_STATUS_ONLY" == "true" ]]; then
    SAVED_TUNE="$(read_saved_tune)"
    THP_EN="$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "unknown")"
    THP_DEF="$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || echo "unknown")"

    DT_LAYERS=()
    while IFS= read -r s; do
        [[ -n "$s" ]] && DT_LAYERS+=("${s#${LOCAL_ROOT}/}")
    done < <(rvdk_collect_deeptune_scripts "$LOCAL_ROOT")
    LAYERS_STR="$(IFS=' -> '; echo "${DT_LAYERS[*]:-none}")"

    printf "\033[1;36m[RVDK:DEEPTUNE]\033[0m Multi-Layer Kit DeepTune Status\n"
    printf "  • Kit Identity      : board=%s | soc=%s | os=%s | nic=%s\n" "${BOARD_PATH:--}" "$SOC_PATH" "$OS_ID" "${RVDK_PRIMARY_NIC:-none}"
    printf "  • Active Workload   : %s\n" "${SAVED_TUNE:-unconfigured}"
    printf "  • DeepTune Chain    : %s\n" "$LAYERS_STR"
    printf "  • Layer 1 (OS THP)  : enabled=%s | defrag=%s\n" "$THP_EN" "$THP_DEF"

    [[ -f "${LOCAL_ROOT}/bsp/${SOC_PATH}/deeptune.sh" ]] && bash "${LOCAL_ROOT}/bsp/${SOC_PATH}/deeptune.sh" status
    [[ -n "$BOARD_PATH" && -f "${LOCAL_ROOT}/boards/${BOARD_PATH}/deeptune.sh" ]] && bash "${LOCAL_ROOT}/boards/${BOARD_PATH}/deeptune.sh" status
    exit 0
fi

export RVDK_APT_LIB="${LOCAL_ROOT}/lib/apt.sh"
_RVDK_OWN_APT_STAMP=""
if [[ -z "${RVDK_APT_STAMP_FILE:-}" ]]; then
    _RVDK_OWN_APT_STAMP="/run/rvdk-apt-$$.stamp"
    rm -f "$_RVDK_OWN_APT_STAMP" 2>/dev/null || true
    export RVDK_APT_STAMP_FILE="$_RVDK_OWN_APT_STAMP"
fi

sync_apt_stamp() {
    if [[ -n "${RVDK_APT_STAMP_FILE:-}" && -f "$RVDK_APT_STAMP_FILE" ]]; then
        export RVDK_NO_APT_UPDATE="1"
    fi
}

export RVDK_PROGBAR_LIB="${LOCAL_ROOT}/lib/progbar.sh"
if [[ -f "$RVDK_PROGBAR_LIB" ]]; then
    # shellcheck disable=SC1090
    source "$RVDK_PROGBAR_LIB"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_prog_init "${MODULE} (${BOARD_PATH:-$SOC_PATH})"
log_rvdk "Kit: board=${BOARD_PATH:-generic} | soc=${SOC_PATH} | os=${OS_ID} (${RVDK_KIT_SOURCE:-probed}) | Module: ${MODULE}"

# Strictly match OS-specific scripts (excludes bootstrap.sh symlink to prevent recursion)
resolve_os_script() {
    local base_dir="$1"
    for candidate in \
        "${base_dir}/bootstrap-${OS_ID}.sh" \
        "${base_dir}/forge-${OS_ID}.sh" \
        "${base_dir}/forge_${OS_ID}.sh"; do
        if [[ -f "$candidate" && ! -L "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Execute collected DeepTune layers (`os/deeptune.sh` -> `bsp/<soc>/deeptune.sh` -> `boards/<board>/deeptune.sh`)
run_kit_deeptune() {
    local base_pct="${1:-0}"
    local span_pct="${2:-100}"

    local prev_tune
    prev_tune="$(read_saved_tune)"
    local raw_tune="${DEEPTUNE_TUNE:-${prev_tune:-data}}"
    raw_tune="$(tr '[:upper:]' '[:lower:]' <<< "$raw_tune")"

    local tune_mode tune_label
    case "$raw_tune" in
        data)               tune_mode="data"; tune_label="data" ;;
        ml)                 tune_mode="ml";   tune_label="ml" ;;
        ai|edge-ai|edge-ml) tune_mode="ml";   tune_label="ai" ;;
        *) log_fatal "Invalid --tune '${raw_tune}' (expected: data | ml | ai)" ;;
    esac

    local dt_scripts=()
    local s
    while IFS= read -r s; do
        [[ -n "$s" ]] && dt_scripts+=("$s")
    done < <(rvdk_collect_deeptune_scripts "$LOCAL_ROOT")

    if [[ ${#dt_scripts[@]} -eq 0 ]]; then
        log_rvdk "[SKIP] No deeptune.sh layers found for ${SOC_PATH}"
        return 0
    fi

    if [[ -n "$prev_tune" && "$prev_tune" != "$tune_label" ]]; then
        log_rvdk "Flipping Kit DeepTune: '${prev_tune}' -> '${tune_label}' (${#dt_scripts[@]} layers)..."
    else
        log_rvdk "Applying Kit DeepTune (--tune ${tune_label} | ${#dt_scripts[@]} layers)..."
    fi

    local count="${#dt_scripts[@]}"
    local idx=0
    local rel_layers=()
    for s in "${dt_scripts[@]}"; do
        sync_apt_stamp
        local l_base=$(( base_pct + (span_pct * idx) / count ))
        local l_next=$(( base_pct + (span_pct * (idx + 1)) / count ))
        local l_span=$(( l_next - l_base ))
        (( l_span < 1 )) && l_span=1
        local rel="${s#${LOCAL_ROOT}/}"
        rel_layers+=("$rel")

        local layer_args=("--tune" "$tune_label")
        [[ "${RVDK_NO_APT_UPDATE:-0}" == "1" ]] && layer_args+=("--no-apt-update")

        log_rvdk "DeepTune Layer $((idx + 1))/${count}: ${rel} (--tune ${tune_label})..."
        RVDK_TUNE="$tune_label" RVDK_PROG_BASE="$l_base" RVDK_PROG_SPAN="$l_span" \
            bash "$s" "${layer_args[@]}" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        idx=$((idx + 1))
    done

    install -d -m 0755 /etc/rvdk
    local layers_joined
    layers_joined="$(IFS=','; echo "${rel_layers[*]}")"
    cat <<EOF > "$DEEPTUNE_STATE_FILE"
# Managed by RVDK (rvdk deeptune)
RVDK_TUNE="${tune_label}"
RVDK_TUNE_MODE="${tune_mode}"
RVDK_SOC="${SOC_PATH}"
RVDK_BOARD="${BOARD_PATH}"
RVDK_OS_ID="${OS_ID}"
RVDK_DEEPTUNE_LAYERS="${layers_joined}"
EOF
    chmod 0644 "$DEEPTUNE_STATE_FILE"
    rm -f "$LEGACY_DEEPTUNE_STATE" 2>/dev/null || true
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
        # StarFive JH7110 Debian: run BSP repo fix prior to generic OS apt calls
        if [[ "$SOC_PATH" == "starfive/jh7110" && "$OS_ID" == "debian" ]]; then
            BSP_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/bsp/${SOC_PATH}")" || log_fatal "Missing BSP script for ${SOC_PATH} (${OS_ID})"
            OS_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/os")" || log_fatal "Missing OS script for ${OS_ID}"
            log_rvdk "Stage 1/2: Silicon BSP & APT Repo Migration (${BSP_SCRIPT})..."
            RVDK_PROG_BASE=0 RVDK_PROG_SPAN="$S1_SPAN" bash "$BSP_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
            sync_apt_stamp
            log_rvdk "Stage 2/2: OS Normalization & CVE-2026-98432 Guard (${OS_SCRIPT})..."
            RVDK_PROG_BASE="$S2_BASE" RVDK_PROG_SPAN="$S2_SPAN" bash "$OS_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        else
            OS_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/os")" || log_fatal "Missing OS script for ${OS_ID}"
            BSP_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/bsp/${SOC_PATH}")" || log_fatal "Missing BSP script for ${SOC_PATH} (${OS_ID})"
            log_rvdk "Stage 1/2: OS Normalization & CVE-2026-98432 Guard (${OS_SCRIPT})..."
            RVDK_PROG_BASE=0 RVDK_PROG_SPAN="$S1_SPAN" bash "$OS_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
            sync_apt_stamp
            log_rvdk "Stage 2/2: Silicon BSP Hardening (${BSP_SCRIPT})..."
            RVDK_PROG_BASE="$S2_BASE" RVDK_PROG_SPAN="$S2_SPAN" bash "$BSP_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        fi
        # Refresh /etc/rvdk/kit.env after Day-0 networkd/interface changes
        rvdk_kit_resolve --refresh
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
        OS_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/os")" || log_fatal "Missing OS script for ${OS_ID}"
        bash "$OS_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        run_addon_tail
        rvdk_prog 100 "OS normalization converged"
        ;;
    bsp)
        BSP_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/bsp/${SOC_PATH}")" || log_fatal "Missing BSP script for ${SOC_PATH} (${OS_ID})"
        bash "$BSP_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        run_addon_tail
        rvdk_prog 100 "Silicon BSP converged"
        ;;
    postgresql)
        bash "${LOCAL_ROOT}/postgresql/latest/forge.sh" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        run_addon_tail
        rvdk_prog 100 "PostgreSQL 18.6 converged"
        ;;
    *)
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
