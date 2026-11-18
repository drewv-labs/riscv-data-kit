#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Kit Inference & Cache Library (`lib/kit.sh`)
# Path: riscv-data-kit/lib/kit.sh
#
# Description:
#   Resolves the hardware & OS "Kit" identity (Board, SoC, OS, Primary NIC,
#   CPU Hart Count, Factory Default User) once and caches it system-wide at
#   `/etc/rvdk/kit.env` (0644) using safe non-executing key-value I/O so all
#   subsequent RVDK operations load from cache in <1ms without re-probing sysfs.
# ==============================================================================

RVDK_KIT_CACHE_FILE="${RVDK_KIT_CACHE_FILE:-/etc/rvdk/kit.env}"
RVDK_KIT_SCHEMA_VERSION="1"

_RVDK_KIT_ALLOWED_KEYS=" RVDK_KIT_SCHEMA RVDK_DT_MODEL RVDK_SOC RVDK_SOC_SLUG RVDK_BOARD RVDK_BOARD_TAG RVDK_FACTORY_USER RVDK_OS_ID RVDK_OS_VERSION_ID RVDK_PRIMARY_NIC RVDK_CPU_HARTS "

# Safe non-executing parser for /etc/rvdk/kit.env (never invokes `source`)
_rvdk_kit_read_cache() {
    local cache_file="$1"
    [[ -r "$cache_file" ]] || return 1
    local raw_line line key val
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line="${raw_line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        [[ "$key" =~ ^RVDK_[A-Z0-9_]+$ ]] || continue
        [[ "$_RVDK_KIT_ALLOWED_KEYS" == *" ${key} "* ]] || continue
        if [[ ${#val} -ge 2 && "${val:0:1}" == '"' && "${val:$(( ${#val} - 1 )):1}" == '"' ]]; then
            val="${val:1:$(( ${#val} - 2 ))}"
            val="${val//\\\"/\"}"
            val="${val//\\\$/\$}"
            val="${val//\\\`/\`}"
            val="${val//\\\\/\\}"
        fi
        printf -v "$key" '%s' "$val"
    done < "$cache_file"
}

_rvdk_kit_escape_val() {
    local v="${1:-}"
    v="${v//$'\n'/ }"
    v="${v//$'\r'/}"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//\$/\\\$}"
    v="${v//\`/\\\`}"
    printf '%s' "$v"
}

# Map a Device Tree model string -> "SOC|BOARD|BOARD_TAG|FACTORY_USER"
# Case-insensitive matching handles vendor DT strings such as "ky x1 orangepi-rv2 board".
_rvdk_infer_from_dt_model() {
    local dt_lc
    dt_lc="$(tr '[:upper:]' '[:lower:]' <<< "${1:-}")"
    case "$dt_lc" in
        *"premier p550"*)
            echo "eswin/eic7700x|sifive/p550|p550|" ;;
        *"megrez"*)
            echo "eswin/eic7700x|milkv/megrez|megrez|" ;;
        *"starpro64"*)
            echo "eswin/eic7700x|pine64/starpro64|starpro64|" ;;
        *"eic7700"*)
            echo "eswin/eic7700x|eswin/eic7700x-evb|eic7700x|" ;;
        *"unmatched"*|*"fu740"*)
            echo "sifive/fu740|sifive/unmatched|unmatched|" ;;
        *"visionfive 2 lite"*|*"vf2 lite"*|*"jh7110s"*|*"jh-7110s"*)
            echo "starfive/jh7110|starfive/vf2-lite|vf2lite|user" ;;
        *"visionfive 2"*|*"vf2"*)
            echo "starfive/jh7110|starfive/vf2|vf2|user" ;;
        *"mars"*)
            echo "starfive/jh7110|milkv/mars|mars|user" ;;
        *"star64"*)
            echo "starfive/jh7110|pine64/star64|star64|user" ;;
        *"orangepi-rv2"*|*"orangepi rv2"*|*"orange pi rv2"*)
            echo "spacemit/k1|orangepi/rv2|rv2|orangepi" ;;
        *"orangepi-r2s"*|*"orangepi r2s"*|*"orange pi r2s"*)
            echo "spacemit/k1|orangepi/r2s|r2s|orangepi" ;;
        *"orangepi-rv"*|*"orangepi rv"*|*"orange pi rv"*)
            echo "starfive/jh7110|orangepi/rv|opirv|user" ;;
        *"jh7110"*)
            echo "starfive/jh7110|starfive/vf2|vf2|user" ;;
        *"aibox-k3"*|*"firefly"*k3*)
            echo "spacemit/k3|firefly/aibox-k3|aiboxk3|" ;;
        *"jupiter 2"*|*"spacemit k3"*|*"k3"*)
            echo "spacemit/k3|milkv/jupiter2|jptr2|" ;;
        *"bpi-f3"*|*"banana pi f3"*)
            echo "spacemit/k1|bananapi/f3|bpif3|" ;;
        *"bpi-cm6"*|*"banana pi cm6"*)
            echo "spacemit/k1|bananapi/cm6|bpicm6|" ;;
        *"jupiter"*|*"spacemit"*|*"k1"*|*"m1"*|*"ky x1"*)
            echo "spacemit/k1|milkv/jupiter|jptr1|" ;;
        *"titan"*|*"dp1000"*)
            echo "ultrarisc/dp1000|milkv/titan|titan|" ;;
        *"atlantis"*|*"ascalon"*)
            echo "tenstorrent/atlantis|tenstorrent/atlantis|atlantis|" ;;
        *"blackhole"*)
            echo "tenstorrent/blackhole|tenstorrent/blackhole|blackhole|" ;;
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
        unmatched|unmatchedb|unmatched-b|fu740|hifive-unmatched|sifive-unmatched|sifive/unmatched)
            echo "sifive/unmatched" ;;
        megrez|milkv-megrez|milkv/megrez|milk-v/megrez)
            echo "milkv/megrez" ;;
        starpro64|pine64/starpro64)
            echo "pine64/starpro64" ;;
        vf2-lite|vf2lite|visionfive2-lite|visionfive-2-lite|starfive-vf2-lite|starfive/vf2-lite)
            echo "starfive/vf2-lite" ;;
        vf2|visionfive2|visionfive-2|starfive-vf2|starfive/vf2|starfive/visionfive2)
            echo "starfive/vf2" ;;
        mars|milkv-mars|milkv/mars|milk-v/mars)
            echo "milkv/mars" ;;
        rv|opirv|orangepi-rv|orangepi/rv)
            echo "orangepi/rv" ;;
        rv2|opirv2|orangepi-rv2|orangepi/rv2)
            echo "orangepi/rv2" ;;
        r2s|opir2s|orangepi-r2s|orangepi/r2s)
            echo "orangepi/r2s" ;;
        f3|bpif3|bpi-f3|bananapi-f3|bananapi/f3|bananapi/bpi-f3|banana-pi/f3)
            echo "bananapi/f3" ;;
        cm6|bpicm6|bpi-cm6|bananapi-cm6|bananapi/cm6|bananapi/bpi-cm6|banana-pi/cm6)
            echo "bananapi/cm6" ;;
        jupiter|jptr1|jupiter1|milkv-jupiter|milkv/jupiter|milk-v/jupiter)
            echo "milkv/jupiter" ;;
        jupiter2|jptr2|milkv-jupiter2|milkv/jupiter2|milk-v/jupiter2)
            echo "milkv/jupiter2" ;;
        aibox-k3|aiboxk3|firefly-k3|firefly-aibox-k3|firefly/aibox-k3)
            echo "firefly/aibox-k3" ;;
        titan|dp1000|milkv-titan|milkv/titan|milk-v/titan|ultrarisc-titan|ultrarisc/titan)
            echo "milkv/titan" ;;
        atlantis|tt-atlantis|ascalon|tenstorrent-atlantis|tenstorrent/atlantis)
            echo "tenstorrent/atlantis" ;;
        blackhole|tt-blackhole|tenstorrent-blackhole|tenstorrent/blackhole)
            echo "tenstorrent/blackhole" ;;
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

    # <1ms disk fast-path: parse cached /etc/rvdk/kit.env safely without `source`
    if [[ "$force_refresh" == "false" && "$has_override" == "false" && -r "$RVDK_KIT_CACHE_FILE" ]]; then
        _rvdk_kit_read_cache "$RVDK_KIT_CACHE_FILE" || true
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
        case "$board" in
            starfive/vf2-lite)          tag="vf2lite"; factory_user="${factory_user:-user}" ;;
            starfive/vf2|milkv/mars|pine64/star64) tag="${board##*/}"; factory_user="${factory_user:-user}" ;;
            orangepi/rv)                tag="opirv"; factory_user="${factory_user:-user}" ;;
            orangepi/rv2|orangepi/r2s)  tag="${board##*/}"; factory_user="${factory_user:-orangepi}" ;;
            milkv/jupiter)              tag="jptr1" ;;
            milkv/jupiter2)             tag="jptr2" ;;
            firefly/aibox-k3)           tag="aiboxk3" ;;
            bananapi/f3)                tag="bpif3" ;;
            bananapi/cm6)               tag="bpicm6" ;;
            *)                          tag="${board##*/}" ;;
        esac
    fi
    if [[ -n "$cli_soc" ]]; then
        soc="$cli_soc"
    elif [[ -z "$soc" && -n "$board" ]]; then
        case "$board" in
            sifive/p550|milkv/megrez|pine64/starpro64) soc="eswin/eic7700x" ;;
            sifive/unmatched) soc="sifive/fu740" ;;
            starfive/vf2|starfive/vf2-lite|milkv/mars|pine64/star64|orangepi/rv) soc="starfive/jh7110" ;;
            milkv/jupiter|orangepi/rv2|orangepi/r2s|bananapi/f3|bananapi/cm6) soc="spacemit/k1" ;;
            milkv/jupiter2|firefly/aibox-k3) soc="spacemit/k3" ;;
            milkv/titan) soc="ultrarisc/dp1000" ;;
            tenstorrent/atlantis) soc="tenstorrent/atlantis" ;;
            tenstorrent/blackhole) soc="tenstorrent/blackhole" ;;
        esac
    fi

    if [[ -z "$board" && -n "$soc" ]]; then
        case "$soc" in
            eswin/eic7700x)        board="sifive/p550";          tag="p550" ;;
            sifive/fu740)          board="sifive/unmatched";     tag="unmatched" ;;
            starfive/jh7110)       board="starfive/vf2";         tag="vf2"; factory_user="user" ;;
            spacemit/k1)           board="milkv/jupiter";        tag="jptr1" ;;
            spacemit/k3)           board="milkv/jupiter2";       tag="jptr2" ;;
            ultrarisc/dp1000)      board="milkv/titan";          tag="titan" ;;
            tenstorrent/atlantis)  board="tenstorrent/atlantis"; tag="atlantis" ;;
            tenstorrent/blackhole) board="tenstorrent/blackhole"; tag="blackhole" ;;
        esac
    fi

    # Reject malformed CLI overrides before persisting
    [[ -z "$soc"   || "$soc"   =~ ^[a-z0-9_-]+/[a-z0-9._-]+$ ]] || soc=""
    [[ -z "$board" || "$board" =~ ^[a-z0-9_-]+/[a-z0-9._-]+$ ]] || board=""

    local os_id="${cli_os:-}"
    local os_ver=""
    local os_like=""
    if [[ -z "$os_id" && -f /etc/os-release ]]; then
        os_id="$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")"
        os_ver="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"
        os_like="$(. /etc/os-release 2>/dev/null && echo "${ID_LIKE:-}")"
    elif [[ -z "$os_id" && -f /etc/openwrt_release ]]; then
        os_id="openwrt"
        os_ver="$(. /etc/openwrt_release 2>/dev/null && echo "${DISTRIB_RELEASE:-}")"
    elif [[ -z "$os_id" && "$(uname -s)" == "Darwin" ]]; then
        os_id="macos"
        os_ver="$(sw_vers -productVersion 2>/dev/null || true)"
    fi
    os_id="$(tr '[:upper:]' '[:lower:]' <<< "${os_id:-unknown}")"
    os_like="$(tr '[:upper:]' '[:lower:]' <<< "${os_like:-}")"

    # Normalize derivative RISC-V BSP distros & versioned media.json tags (ubuntu-24.04, debian-12, RockOS, RevyOS, Ky OpenWrt)
    case "$os_id" in
        debian|ubuntu|bianbu|openwrt|macos) ;;
        debian-*|rockos*|revyos*) os_id="debian" ;;
        ubuntu-*)                 os_id="ubuntu" ;;
        bianbu-*)                 os_id="bianbu" ;;
        *openwrt*)                os_id="openwrt" ;;
        *)
            case " $os_like " in
                *" openwrt "*) os_id="openwrt" ;;
                *" bianbu "*)  os_id="bianbu" ;;
                *" ubuntu "*)  os_id="ubuntu" ;;
                *" debian "*)  os_id="debian" ;;
            esac
            ;;
    esac

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

    # Persist system-wide cache on Linux target nodes using escaped non-executing serialization
    if [[ "$(uname -s)" == "Linux" && "${EUID:-$(id -u)}" -eq 0 && -n "$RVDK_SOC" ]] && [[ "$has_override" == "false" || "$force_refresh" == "true" ]]; then
        local cache_dir
        cache_dir="$(dirname "$RVDK_KIT_CACHE_FILE")"
        mkdir -p "$cache_dir"
        chmod 0755 "$cache_dir"
        local tmp_kit="${RVDK_KIT_CACHE_FILE}.tmp.$$"
        {
            printf '# ==============================================================================\n'
            printf '# DREW-V Labs // RVDK Kit Hardware & OS Cache (%s)\n' "$RVDK_KIT_CACHE_FILE"
            printf '# Auto-generated once by lib/kit.sh. Refresh anytime via: sudo rvdk kit --refresh\n'
            printf '# ==============================================================================\n'
            printf 'RVDK_KIT_SCHEMA="%s"\n'    "$(_rvdk_kit_escape_val "$RVDK_KIT_SCHEMA")"
            printf 'RVDK_DT_MODEL="%s"\n'      "$(_rvdk_kit_escape_val "$RVDK_DT_MODEL")"
            printf 'RVDK_SOC="%s"\n'           "$(_rvdk_kit_escape_val "$RVDK_SOC")"
            printf 'RVDK_SOC_SLUG="%s"\n'      "$(_rvdk_kit_escape_val "$RVDK_SOC_SLUG")"
            printf 'RVDK_BOARD="%s"\n'         "$(_rvdk_kit_escape_val "$RVDK_BOARD")"
            printf 'RVDK_BOARD_TAG="%s"\n'     "$(_rvdk_kit_escape_val "$RVDK_BOARD_TAG")"
            printf 'RVDK_FACTORY_USER="%s"\n'  "$(_rvdk_kit_escape_val "$RVDK_FACTORY_USER")"
            printf 'RVDK_OS_ID="%s"\n'         "$(_rvdk_kit_escape_val "$RVDK_OS_ID")"
            printf 'RVDK_OS_VERSION_ID="%s"\n' "$(_rvdk_kit_escape_val "$RVDK_OS_VERSION_ID")"
            printf 'RVDK_PRIMARY_NIC="%s"\n'   "$(_rvdk_kit_escape_val "$RVDK_PRIMARY_NIC")"
            printf 'RVDK_CPU_HARTS="%s"\n'     "$(_rvdk_kit_escape_val "$RVDK_CPU_HARTS")"
        } > "$tmp_kit"
        chmod 0644 "$tmp_kit"
        mv -f "$tmp_kit" "$RVDK_KIT_CACHE_FILE"
    fi
}

# Collect all applicable deeptune.sh layers for the resolved Kit in execution order:
#   1. os/deeptune.sh
#   2. os/deeptune-${RVDK_OS_ID:-unknown}.sh (if present)
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
    printf 'RVDK_KIT_SCHEMA=%q\n'    "${RVDK_KIT_SCHEMA:-}"
    printf 'RVDK_DT_MODEL=%q\n'      "${RVDK_DT_MODEL:-}"
    printf 'RVDK_SOC=%q\n'           "${RVDK_SOC:-}"
    printf 'RVDK_SOC_SLUG=%q\n'      "${RVDK_SOC_SLUG:-}"
    printf 'RVDK_BOARD=%q\n'         "${RVDK_BOARD:-}"
    printf 'RVDK_BOARD_TAG=%q\n'     "${RVDK_BOARD_TAG:-}"
    printf 'RVDK_FACTORY_USER=%q\n'  "${RVDK_FACTORY_USER:-}"
    printf 'RVDK_OS_ID=%q\n'         "${RVDK_OS_ID:-}"
    printf 'RVDK_OS_VERSION_ID=%q\n' "${RVDK_OS_VERSION_ID:-}"
    printf 'RVDK_PRIMARY_NIC=%q\n'   "${RVDK_PRIMARY_NIC:-}"
    printf 'RVDK_CPU_HARTS=%q\n'     "${RVDK_CPU_HARTS:-}"
}

rvdk_kit_print_summary() {
    local repo_root="$1"
    local mode="${2:-full}"
    local cache_status="absent (run 'sudo rvdk kit --refresh' to persist)"
    if [[ -f "$RVDK_KIT_CACHE_FILE" ]]; then
        cache_status="${RVDK_KIT_CACHE_FILE} (${RVDK_KIT_SOURCE:-loaded})"
    fi

    local chain_str=""
    local s rel
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        rel="${s#"${repo_root}/"}"
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

    if [[ "$mode" != "--motd" ]]; then
        printf "\033[1;36m[RVDK:KIT]\033[0m Resolved Hardware & OS Kit\n"
    fi
    printf "  • Device Tree Model : %s\n" "${RVDK_DT_MODEL:-Unknown}"
    printf "  • Board (boards/)   : %s (tag: %s)\n" "${RVDK_BOARD:-unrecognized}" "${RVDK_BOARD_TAG:--}"
    printf "  • SoC (bsp/)        : %s (slug: %s)\n" "${RVDK_SOC:-unrecognized}" "${RVDK_SOC_SLUG:--}"
    printf "  • OS (os/)          : %s %s\n" "${RVDK_OS_ID:-unknown}" "${RVDK_OS_VERSION_ID:-}"
    printf "  • Primary NIC / CPU : %s | %s Harts\n" "${RVDK_PRIMARY_NIC:-none}" "${RVDK_CPU_HARTS:-?}"
    printf "  • Kit Cache File    : %s\n" "$cache_status"
    printf "  • DeepTune Chain    : %s\n" "$chain_str"
    printf "  • Board Quirks      : %s\n" "$quirks_str"
}
