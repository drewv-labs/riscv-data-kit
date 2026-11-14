#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Kit Inference & Cache Library (`lib/kit.sh`)
# Path: riscv-data-kit/lib/kit.sh
#
# Description:
#   Resolves the hardware & OS "Kit" identity (Board, SoC, OS, Primary NIC,
#   CPU Hart Count, Factory Default User) once and caches it system-wide at
#   `/etc/rvdk/kit.env` (0644) so all subsequent RVDK and downstream operations
#   read directly from cache in <1ms without re-probing sysfs/device-tree.
# ==============================================================================

RVDK_KIT_CACHE_FILE="${RVDK_KIT_CACHE_FILE:-/etc/rvdk/kit.env}"
RVDK_KIT_SCHEMA_VERSION="1"

# Map a Device Tree model string -> "SOC|BOARD|BOARD_TAG|FACTORY_USER"
_rvdk_infer_from_dt_model() {
    local dt_model="$1"
    case "$dt_model" in
        *"Premier P550"*)
            echo "eswin/eic7700x|sifive/p550|p550|" ;;
        *"Megrez"*)
            echo "eswin/eic7700x|milkv/megrez|megrez|" ;;
        *"StarPro64"*)
            echo "eswin/eic7700x|pine64/starpro64|starpro64|" ;;
        *"EIC7700"*)
            echo "eswin/eic7700x|eswin/eic7700x-evb|eic7700x|" ;;
        *"VisionFive 2"*|*"VF2"*)
            echo "starfive/jh7110|starfive/vf2|vf2|user" ;;
        *"Mars"*)
            echo "starfive/jh7110|milkv/mars|mars|user" ;;
        *"Star64"*)
            echo "starfive/jh7110|pine64/star64|star64|user" ;;
        *"OrangePi RV2"*)
            echo "spacemit/k1|orangepi/rv2|rv2|" ;;
        *"OrangePi R2S"*)
            echo "spacemit/k1|orangepi/r2s|r2s|" ;;
        *"OrangePi RV"*)
            echo "starfive/jh7110|orangepi/rv|opirv|user" ;;
        *"JH7110"*)
            echo "starfive/jh7110|starfive/vf2|vf2|user" ;;
        *"Jupiter 2"*|*"SpacemiT K3"*|*"K3"*)
            echo "spacemit/k3|milkv/jupiter2|jptr2|" ;;
        *"BPI-F3"*)
            echo "spacemit/k1|bananapi/f3|bpif3|" ;;
        *"Jupiter"*|*"SpacemiT"*|*"K1"*|*"M1"*|*"Ky X1"*)
            echo "spacemit/k1|milkv/jupiter|jptr1|" ;;
        *"Titan"*|*"DP1000"*)
            echo "ultrarisc/dp1000|ultrarisc/titan|titan|" ;;
        *)
            echo "|||" ;;
    esac
}

# Normalize a board alias ("p550", "vf2", "sifive/p550", "visionfive2") -> canonical "<vendor>/<slug>"
rvdk_normalize_board_id() {
    local q
    q="$(tr '[:upper:]' '[:lower:]' <<< "${1:-}")"
    case "$q" in
        p550|premier-p550|hifive-premier-p550|sifive-p550|sifive/p550|sifive/hifive-premier-p550)
            echo "sifive/p550" ;;
        megrez|milkv-megrez|milkv/megrez|milk-v/megrez)
            echo "milkv/megrez" ;;
        starpro64|pine64/starpro64)
            echo "pine64/starpro64" ;;
        vf2|visionfive2|visionfive-2|starfive-vf2|starfive/vf2|starfive/visionfive2)
            echo "starfive/vf2" ;;
        mars|milkv-mars|milkv/mars|milk-v/mars)
            echo "milkv/mars" ;;
        jupiter|jptr1|jupiter1|milkv-jupiter|milkv/jupiter|milk-v/jupiter)
            echo "milkv/jupiter" ;;
        jupiter2|jptr2|milkv-jupiter2|milkv/jupiter2|milk-v/jupiter2)
            echo "milkv/jupiter2" ;;
        titan|dp1000|ultrarisc-titan|ultrarisc/titan|milkv/titan|milk-v/titan)
            echo "ultrarisc/titan" ;;
        */*)
            echo "$q" ;;
        *)
            echo "$q" ;;
    esac
}

# Resolve a board query to an existing directory under `${repo_root}/boards/<vendor>/<slug>`
rvdk_resolve_board_dir() {
    local repo_root="$1"
    local query="$2"
    local norm
    norm="$(rvdk_normalize_board_id "$query")"
    if [[ -d "${repo_root}/boards/${norm}" ]]; then
        echo "${repo_root}/boards/${norm}"
        return 0
    fi
    local candidate
    for candidate in "${repo_root}"/boards/*/"${query}"; do
        if [[ -d "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Detect active primary network interface dynamically without hardcoding end0/eth0
rvdk_detect_primary_nic() {
    local nic=""
    if command -v ip >/dev/null 2>&1; then
        nic="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1 || true)"
        if [[ -z "$nic" ]]; then
            nic="$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -vE '^(lo|tailscale0|docker0|br-|veth|virbr)' | head -n1 || true)"
        fi
    fi
    echo "$nic"
}

# Resolve Kit metadata (in-memory -> /etc/rvdk/kit.env -> live sysfs probe & persist if root)
# Args: [--refresh] [--soc <v/s>] [--board <v/b>] [--os <id>]
rvdk_kit_resolve() {
    local force_refresh="false"
    local cli_soc=""
    local cli_board=""
    local cli_os=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --refresh) force_refresh="true"; shift ;;
            --soc)     cli_soc="${2:-}"; shift 2 ;;
            --board)   cli_board="${2:-}"; shift 2 ;;
            --os)      cli_os="${2:-}"; shift 2 ;;
            *)         shift ;;
        esac
    done

    local has_override="false"
    [[ -n "$cli_soc" || -n "$cli_board" || -n "$cli_os" ]] && has_override="true"

    # 0ms in-memory fast-path when parent RVDK dispatcher already resolved the Kit
    if [[ "$force_refresh" == "false" && "$has_override" == "false" && "${RVDK_KIT_SCHEMA:-}" == "$RVDK_KIT_SCHEMA_VERSION" && -n "${RVDK_SOC:-}" && -n "${RVDK_OS_ID:-}" ]]; then
        return 0
    fi

    # <1ms disk fast-path: load cached /etc/rvdk/kit.env when present and no overrides/refresh requested
    if [[ "$force_refresh" == "false" && "$has_override" == "false" && -r "$RVDK_KIT_CACHE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$RVDK_KIT_CACHE_FILE"
        if [[ "${RVDK_KIT_SCHEMA:-}" == "$RVDK_KIT_SCHEMA_VERSION" && -n "${RVDK_SOC:-}" && -n "${RVDK_OS_ID:-}" ]]; then
            export RVDK_KIT_SCHEMA RVDK_DT_MODEL RVDK_SOC RVDK_SOC_SLUG RVDK_BOARD RVDK_BOARD_TAG RVDK_FACTORY_USER RVDK_OS_ID RVDK_OS_VERSION_ID RVDK_PRIMARY_NIC RVDK_CPU_HARTS
            export RVDK_KIT_SOURCE="cache"
            return 0
        fi
    fi

    local dt_model="Unknown"
    if [[ -r /proc/device-tree/model ]]; then
        dt_model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        dt_model="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m) (macOS Host)"
    fi

    local inferred soc board tag factory_user
    inferred="$(_rvdk_infer_from_dt_model "$dt_model")"
    IFS='|' read -r soc board tag factory_user <<< "$inferred"

    if [[ -n "$cli_board" ]]; then
        board="$(rvdk_normalize_board_id "$cli_board")"
        tag="${board##*/}"
    fi
    if [[ -n "$cli_soc" ]]; then
        soc="$cli_soc"
    elif [[ -z "$soc" && -n "$board" ]]; then
        case "$board" in
            sifive/p550|milkv/megrez|pine64/starpro64) soc="eswin/eic7700x" ;;
            starfive/vf2|milkv/mars|pine64/star64|orangepi/rv) soc="starfive/jh7110" ;;
            milkv/jupiter|orangepi/rv2|orangepi/r2s|bananapi/f3) soc="spacemit/k1" ;;
            milkv/jupiter2) soc="spacemit/k3" ;;
            ultrarisc/titan) soc="ultrarisc/dp1000" ;;
        esac
    fi

    if [[ -z "$board" && -n "$soc" ]]; then
        case "$soc" in
            eswin/eic7700x)   board="sifive/p550";     tag="p550" ;;
            starfive/jh7110)  board="starfive/vf2";    tag="vf2"; factory_user="user" ;;
            spacemit/k1)      board="milkv/jupiter";   tag="jptr1" ;;
            spacemit/k3)      board="milkv/jupiter2";  tag="jptr2" ;;
            ultrarisc/dp1000) board="ultrarisc/titan"; tag="titan" ;;
        esac
    fi

    local os_id="${cli_os:-}"
    local os_ver=""
    if [[ -z "$os_id" && -f /etc/os-release ]]; then
        os_id="$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")"
        os_ver="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"
    elif [[ -z "$os_id" && "$(uname -s)" == "Darwin" ]]; then
        os_id="macos"
        os_ver="$(sw_vers -productVersion 2>/dev/null || true)"
    fi
    os_id="$(tr '[:upper:]' '[:lower:]' <<< "${os_id:-unknown}")"

    local soc_slug="${soc//\//-}"
    local primary_nic
    primary_nic="$(rvdk_detect_primary_nic)"
    local cpu_harts
    cpu_harts="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"

    RVDK_KIT_SCHEMA="$RVDK_KIT_SCHEMA_VERSION"
    RVDK_DT_MODEL="$dt_model"
    RVDK_SOC="$soc"
    RVDK_SOC_SLUG="$soc_slug"
    RVDK_BOARD="$board"
    RVDK_BOARD_TAG="$tag"
    RVDK_FACTORY_USER="$factory_user"
    RVDK_OS_ID="$os_id"
    RVDK_OS_VERSION_ID="$os_ver"
    RVDK_PRIMARY_NIC="$primary_nic"
    RVDK_CPU_HARTS="$cpu_harts"
    RVDK_KIT_SOURCE="probed"

    export RVDK_KIT_SCHEMA RVDK_DT_MODEL RVDK_SOC RVDK_SOC_SLUG RVDK_BOARD RVDK_BOARD_TAG RVDK_FACTORY_USER RVDK_OS_ID RVDK_OS_VERSION_ID RVDK_PRIMARY_NIC RVDK_CPU_HARTS RVDK_KIT_SOURCE

    # Persist system-wide cache on Linux target nodes when running as root without ephemeral CLI overrides
    if [[ "$(uname -s)" == "Linux" && $EUID -eq 0 && -n "$RVDK_SOC" ]] && [[ "$has_override" == "false" || "$force_refresh" == "true" ]]; then
        local cache_dir
        cache_dir="$(dirname "$RVDK_KIT_CACHE_FILE")"
        install -d -m 0755 "$cache_dir"
        local tmp_kit="${RVDK_KIT_CACHE_FILE}.tmp.$$"
        cat <<EOF > "$tmp_kit"
# ==============================================================================
# DREW-V Labs // RVDK Kit Hardware & OS Cache (${RVDK_KIT_CACHE_FILE})
# Auto-generated once by lib/kit.sh. Refresh anytime via: sudo rvdk kit --refresh
# ==============================================================================
RVDK_KIT_SCHEMA="${RVDK_KIT_SCHEMA}"
RVDK_DT_MODEL="${RVDK_DT_MODEL}"
RVDK_SOC="${RVDK_SOC}"
RVDK_SOC_SLUG="${RVDK_SOC_SLUG}"
RVDK_BOARD="${RVDK_BOARD}"
RVDK_BOARD_TAG="${RVDK_BOARD_TAG}"
RVDK_FACTORY_USER="${RVDK_FACTORY_USER}"
RVDK_OS_ID="${RVDK_OS_ID}"
RVDK_OS_VERSION_ID="${RVDK_OS_VERSION_ID}"
RVDK_PRIMARY_NIC="${RVDK_PRIMARY_NIC}"
RVDK_CPU_HARTS="${RVDK_CPU_HARTS}"
EOF
        chmod 0644 "$tmp_kit"
        mv -f "$tmp_kit" "$RVDK_KIT_CACHE_FILE"
    fi
}

# Collect all applicable deeptune.sh layers for the resolved Kit in execution order:
#   1. os/deeptune.sh
#   2. os/deeptune-<os_id>.sh (if present)
#   3. bsp/<vendor>/<soc>/deeptune.sh (if present)
#   4. boards/<vendor>/<board>/deeptune.sh (if present)
rvdk_collect_deeptune_scripts() {
    local repo_root="$1"
    local candidates=(
        "${repo_root}/os/deeptune.sh"
        "${repo_root}/os/deeptune-${RVDK_OS_ID:-unknown}.sh"
    )
    [[ -n "${RVDK_SOC:-}" ]] && candidates+=("${repo_root}/bsp/${RVDK_SOC}/deeptune.sh")
    [[ -n "${RVDK_BOARD:-}" ]] && candidates+=("${repo_root}/boards/${RVDK_BOARD}/deeptune.sh")

    local s
    for s in "${candidates[@]}"; do
        if [[ -f "$s" && ! -L "$s" ]]; then
            echo "$s"
        fi
    done
}

rvdk_kit_print_env() {
    cat <<EOF
RVDK_KIT_SCHEMA="${RVDK_KIT_SCHEMA:-}"
RVDK_DT_MODEL="${RVDK_DT_MODEL:-}"
RVDK_SOC="${RVDK_SOC:-}"
RVDK_SOC_SLUG="${RVDK_SOC_SLUG:-}"
RVDK_BOARD="${RVDK_BOARD:-}"
RVDK_BOARD_TAG="${RVDK_BOARD_TAG:-}"
RVDK_FACTORY_USER="${RVDK_FACTORY_USER:-}"
RVDK_OS_ID="${RVDK_OS_ID:-}"
RVDK_OS_VERSION_ID="${RVDK_OS_VERSION_ID:-}"
RVDK_PRIMARY_NIC="${RVDK_PRIMARY_NIC:-}"
RVDK_CPU_HARTS="${RVDK_CPU_HARTS:-}"
EOF
}

rvdk_kit_print_summary() {
    local repo_root="$1"
    local cache_status="absent (run 'sudo rvdk kit --refresh' to persist)"
    if [[ -f "$RVDK_KIT_CACHE_FILE" ]]; then
        cache_status="${RVDK_KIT_CACHE_FILE} (${RVDK_KIT_SOURCE:-loaded})"
    fi

    local chain_str=""
    local s rel
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        rel="${s#${repo_root}/}"
        if [[ -z "$chain_str" ]]; then
            chain_str="$rel"
        else
            chain_str+=" -> ${rel}"
        fi
    done < <(rvdk_collect_deeptune_scripts "$repo_root")
    [[ -z "$chain_str" ]] && chain_str="none"

    local quirks=()
    if [[ -n "${RVDK_BOARD:-}" && -d "${repo_root}/boards/${RVDK_BOARD}/quirks" ]]; then
        local qf
        for qf in "${repo_root}/boards/${RVDK_BOARD}/quirks"/*.sh; do
            [[ -f "$qf" ]] || continue
            quirks+=("$(basename "$qf" .sh)")
        done
    fi
    local quirks_str="none"
    [[ ${#quirks[@]} -gt 0 ]] && quirks_str="${quirks[*]}"

    printf "\033[1;36m[RVDK:KIT]\033[0m Resolved Hardware & OS Kit\n"
    printf "  • Device Tree Model : %s\n" "${RVDK_DT_MODEL:-Unknown}"
    printf "  • Board (boards/)   : %s (tag: %s)\n" "${RVDK_BOARD:-unrecognized}" "${RVDK_BOARD_TAG:--}"
    printf "  • SoC (bsp/)        : %s (slug: %s)\n" "${RVDK_SOC:-unrecognized}" "${RVDK_SOC_SLUG:--}"
    printf "  • OS (os/)          : %s %s\n" "${RVDK_OS_ID:-unknown}" "${RVDK_OS_VERSION_ID:-}"
    printf "  • Primary NIC / CPU : %s | %s Harts\n" "${RVDK_PRIMARY_NIC:-none}" "${RVDK_CPU_HARTS:-?}"
    printf "  • Kit Cache File    : %s\n" "$cache_status"
    printf "  • DeepTune Chain    : %s\n" "$chain_str"
    printf "  • Board Quirks      : %s\n" "$quirks_str"
}
