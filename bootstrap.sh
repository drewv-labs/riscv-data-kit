#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Universal Bare-Metal Dispatcher & CLI (`rvdk`)
# Path: riscv-data-kit/bootstrap.sh
#
# Usage (One-Shot Curl Day-0 OS + BSP Bootstrapper + CLI Install):
#   curl -fsSL https://rvdk.drewv-labs.dev/bootstrap.sh | sudo bash -s -- --user drew --hostname brakerbench-vf2 --nopasswd
#
# Usage (Local CLI after install-cli.sh or bootstrap.sh):
#   sudo rvdk [day0|bsp|os|postgresql|mods/nvme-4kn|mods/btrfs-raid|mods/mosquitto|mods/nfs-vault|utils/*|update] [--noprogbar]
# ==============================================================================

# Ensure compatibility when invoked via `zsh` or `bash`
if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L ksh
    setopt PIPE_FAIL ERR_RETURN NO_UNSET
else
    set -Eeuo pipefail
fi

SCRIPT_SELF="${BASH_SOURCE[0]:-}"
if [[ $EUID -ne 0 ]]; then
    if [[ -n "$SCRIPT_SELF" && -f "$SCRIPT_SELF" ]]; then
        exec sudo -E bash "$SCRIPT_SELF" "$@"
    else
        echo "[RVDK:FATAL] Pipe into 'sudo bash' or 'sudo zsh': curl -fsSL https://rvdk.drewv-labs.dev/bootstrap.sh | sudo bash" >&2
        exit 1
    fi
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

# 1. Parse subcommand (defaults to "day0" = OS + BSP)
MODULE="day0"
if [[ $# -gt 0 ]]; then
    case "$1" in
        day0|bsp|os|postgresql|postgresql/*|utils/*|mods/*|update|self-update)
            MODULE="$1"
            shift
            ;;
        install)
            MODULE="${2:-day0}"
            shift $(( $# >= 2 ? 2 : 1 ))
            ;;
    esac
fi

SOC_PATH="${RVDK_SOC:-}"
OS_ID="${RVDK_OS:-}"
FORWARD_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --soc)                    SOC_PATH="${2:-}"; shift 2 ;;
        --os)                     OS_ID="${2:-}"; shift 2 ;;
        --noprogbar|--no-progbar) export RVDK_NO_PROGBAR="1"; shift ;;
        *)                        FORWARD_ARGS+=("$1"); shift ;;
    esac
done

# 2. Ensure ~/.rvdk/engine and /usr/local/bin/rvdk are installed
if [[ -n "$SCRIPT_SELF" ]]; then
    SCRIPT_REAL="$(readlink -f "$SCRIPT_SELF" 2>/dev/null || realpath "$SCRIPT_SELF" 2>/dev/null || echo "$SCRIPT_SELF")"
    CANDIDATE_ROOT="$(cd "$(dirname "$SCRIPT_REAL")" && pwd)"
else
    CANDIDATE_ROOT=""
fi

if [[ "$MODULE" == "update" || "$MODULE" == "self-update" ]]; then
    if [[ -n "$CANDIDATE_ROOT" && -f "${CANDIDATE_ROOT}/install-cli.sh" ]]; then
        exec bash "${CANDIDATE_ROOT}/install-cli.sh" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
    else
        curl -fsSL "${RVDK_BASE_URL}/install-cli.sh" | bash -s -- ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        exit 0
    fi
fi

# If symlinked into a different user's ~/.rvdk/engine (e.g. factory 'user' after switching to admin user),
# migrate into the active user's ~/.rvdk/engine so purging the factory user never breaks /usr/local/bin/rvdk.
if [[ -n "$CANDIDATE_ROOT" && -d "${CANDIDATE_ROOT}/bsp" ]] && ! [[ "$CANDIDATE_ROOT" == */.rvdk/engine && "$CANDIDATE_ROOT" != "$ENGINE_DIR" ]]; then
    LOCAL_ROOT="$CANDIDATE_ROOT"
    if [[ ! -L /usr/local/bin/rvdk ]]; then
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

# 3. Dispatch Host Utilities Early (Allows macOS/x86_64 workstations to run rvdk utils/* without a RISC-V DTB)
if [[ "$MODULE" == utils/* ]]; then
    TARGET_UTIL="${LOCAL_ROOT}/${MODULE%.sh}.sh"
    [[ ! -f "$TARGET_UTIL" ]] && log_fatal "Utility script not found: ${TARGET_UTIL}"
    exec bash "$TARGET_UTIL" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
fi

# 4. Auto-detect Silicon SoC from /proc/device-tree/model
DT_MODEL="Unknown"
if [[ -r /proc/device-tree/model ]]; then
    DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
fi
if [[ -z "$SOC_PATH" ]]; then
    case "$DT_MODEL" in
        *"Premier P550"*|*"EIC7700"*|*"Megrez"*|*"StarPro64"*)
            SOC_PATH="eswin/eic7700x" ;;
        *"VisionFive 2"*|*"JH7110"*|*"Mars"*|*"Star64"*|*"OrangePi RV"*)
            SOC_PATH="starfive/jh7110" ;;
        *"Jupiter 2"*|*"SpacemiT K3"*|*"K3"*)
            SOC_PATH="spacemit/k3" ;;
        *"Jupiter"*|*"SpacemiT"*|*"K1"*|*"M1"*|*"Ky X1"*|*"OrangePi RV2"*|*"OrangePi R2S"*|*"BPI-F3"*)
            SOC_PATH="spacemit/k1" ;;
        *"Titan"*|*"DP1000"*)
            SOC_PATH="ultrarisc/dp1000" ;;
        *)
            log_fatal "Unrecognized RISC-V Device Tree: '${DT_MODEL}'. Pass --soc <vendor/soc>." ;;
    esac
fi

# 5. Auto-detect OS Distribution from /etc/os-release
if [[ -z "$OS_ID" ]]; then
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-unknown}"
    else
        log_fatal "Cannot detect OS: /etc/os-release missing. Pass --os <debian|ubuntu|bianbu>."
    fi
fi
OS_ID="$(tr '[:upper:]' '[:lower:]' <<< "$OS_ID")"

export RVDK_PROGBAR_LIB="${LOCAL_ROOT}/lib/progbar.sh"
if [[ -f "$RVDK_PROGBAR_LIB" ]]; then
    # shellcheck disable=SC1090
    source "$RVDK_PROGBAR_LIB"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_prog_init "${MODULE} (${SOC_PATH})"
log_rvdk "Target: ${SOC_PATH} (${DT_MODEL}) | OS: ${OS_ID} | Module: ${MODULE}"

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

# 6. Dispatch Module (Use `bash`, not `exec bash`, so standalone progress bar EXIT trap tears down cleanly)
case "$MODULE" in
    day0)
        # StarFive JH7110 Debian: run BSP repo fix prior to generic OS apt calls
        if [[ "$SOC_PATH" == "starfive/jh7110" && "$OS_ID" == "debian" ]]; then
            BSP_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/bsp/${SOC_PATH}")" || log_fatal "Missing BSP script for ${SOC_PATH} (${OS_ID})"
            OS_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/os")" || log_fatal "Missing OS script for ${OS_ID}"
            log_rvdk "Stage 1/2: Silicon BSP & APT Repo Migration (${BSP_SCRIPT})..."
            RVDK_PROG_BASE=0 RVDK_PROG_SPAN=55 bash "$BSP_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
            log_rvdk "Stage 2/2: OS Normalization & CVE-2026-98432 Guard (${OS_SCRIPT})..."
            RVDK_PROG_BASE=55 RVDK_PROG_SPAN=45 bash "$OS_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        else
            OS_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/os")" || log_fatal "Missing OS script for ${OS_ID}"
            BSP_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/bsp/${SOC_PATH}")" || log_fatal "Missing BSP script for ${SOC_PATH} (${OS_ID})"
            log_rvdk "Stage 1/2: OS Normalization & CVE-2026-98432 Guard (${OS_SCRIPT})..."
            RVDK_PROG_BASE=0 RVDK_PROG_SPAN=55 bash "$OS_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
            log_rvdk "Stage 2/2: Silicon BSP Hardening (${BSP_SCRIPT})..."
            RVDK_PROG_BASE=55 RVDK_PROG_SPAN=45 bash "$BSP_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        fi
        rvdk_prog 100 "Day-0 OS + Silicon BSP converged"
        ;;
    os)
        OS_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/os")" || log_fatal "Missing OS script for ${OS_ID}"
        bash "$OS_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        rvdk_prog 100 "OS normalization converged"
        ;;
    bsp)
        BSP_SCRIPT="$(resolve_os_script "${LOCAL_ROOT}/bsp/${SOC_PATH}")" || log_fatal "Missing BSP script for ${SOC_PATH} (${OS_ID})"
        bash "$BSP_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        rvdk_prog 100 "Silicon BSP converged"
        ;;
    postgresql)
        bash "${LOCAL_ROOT}/postgresql/latest/forge.sh" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        rvdk_prog 100 "PostgreSQL 18.6 converged"
        ;;
    *)
        TARGET_MOD="${LOCAL_ROOT}/${MODULE}/forge.sh"
        [[ ! -f "$TARGET_MOD" ]] && log_fatal "Module script not found: ${TARGET_MOD}"
        bash "$TARGET_MOD" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
        rvdk_prog 100 "${MODULE} converged"
        ;;
esac
