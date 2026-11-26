#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Kit Inference, Compiler Profiles & Cache Library (`lib/kit.sh`)
# Path: riscv-data-kit/lib/kit.sh
#
# Description:
#   Resolves the hardware & OS "Kit" identity (Board, SoC, OS, Primary NIC,
#   CPU Hart Count, Factory Default User) and silicon compiler profiles once,
#   caching Kit state system-wide at `/etc/rvdk/kit.env` (0644) using safe
#   non-executing key-value I/O (`rvdk_kv_load` / `rvdk_kv_write`).
# ==============================================================================

[[ -n "${_RVDK_KIT_SH_LOADED:-}" ]] && return 0
_RVDK_KIT_SH_LOADED=1

if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    _RVDK_KIT_LIB_DIR=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        _RVDK_KIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [[ -n "$_RVDK_KIT_LIB_DIR" && -f "${_RVDK_KIT_LIB_DIR}/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_RVDK_KIT_LIB_DIR}/common.sh"
    fi
    unset _RVDK_KIT_LIB_DIR
fi

RVDK_KIT_CACHE_FILE="${RVDK_KIT_CACHE_FILE:-/etc/rvdk/kit.env}"
RVDK_KIT_SCHEMA_VERSION="1"

_RVDK_KIT_ALLOWED_KEYS=(
    RVDK_KIT_SCHEMA
    RVDK_DT_MODEL
    RVDK_SOC
    RVDK_SOC_SLUG
    RVDK_BOARD
    RVDK_BOARD_TAG
    RVDK_ARCH
    RVDK_MMU
    RVDK_FACTORY_USER
    RVDK_OS_ID
    RVDK_OS_VERSION_ID
    RVDK_PRIMARY_NIC
    RVDK_CPU_HARTS
)

# Infer architecture (riscv64 | riscv32 | amd64 | arm64) and MMU (sv39 | sv48 | sv57 | none | unknown)
_rvdk_infer_arch_mmu() {
    local soc="${1:-}"
    local host_m
    host_m="$(uname -m 2>/dev/null || echo unknown)"
    host_m="$(tr '[:upper:]' '[:lower:]' <<< "$host_m")"

    local arch="" mmu="unknown"
    if [[ "$soc" == "espressif/esp32p4" || "$host_m" == riscv32* ]]; then
        arch="riscv32"
        mmu="none"
    else
        case "$soc" in
            eswin/eic7700x|starfive/jh7110|sifive/fu740|spacemit/k1|spacemit/k3|ultrarisc/dp1000|tenstorrent/atlantis|tenstorrent/blackhole)
                arch="riscv64" ;;
        esac
        if [[ -z "$arch" ]]; then
            case "$host_m" in
                riscv64*)       arch="riscv64" ;;
                riscv32*)       arch="riscv32" ;;
                x86_64|amd64)   arch="amd64" ;;
                aarch64|arm64)  arch="arm64" ;;
                *)              arch="$host_m" ;;
            esac
        fi
        if [[ "$arch" == "riscv32" ]]; then
            mmu="none"
        elif [[ "$arch" == "riscv64" && -r /proc/cpuinfo ]]; then
            local probed_mmu
            probed_mmu="$(awk -F: '/^[[:space:]]*mmu[[:space:]]*:/ {gsub(/[[:space:]]/, "", $2); print tolower($2); exit}' /proc/cpuinfo 2>/dev/null || true)"
            case "$probed_mmu" in
                sv39|sv48|sv57|none) mmu="$probed_mmu" ;;
                *)                   mmu="unknown" ;;
            esac
        fi
    fi
    printf '%s|%s\n' "$arch" "$mmu"
}

# Map a Device Tree model string -> "SOC|BOARD|BOARD_TAG|FACTORY_USER"
# Case-insensitive matching handles vendor DT strings such as "ky x1 orangepi-rv2 board".
# IMPORTANT: OrangePi RV2 (SpacemiT K1/Ky X1) MUST precede OrangePi RV (StarFive JH7110).
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
        *"esp32-p4-wifi6"*|*"waveshare esp32-p4"*|*"esp32-p4"*|*"esp32p4"*)
            echo "espressif/esp32p4|waveshare/esp32-p4-wifi6|p4|" ;;
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
        rv2|opirv2|orangepi-rv2|orangepi/rv2)
            echo "orangepi/rv2" ;;
        r2s|opir2s|orangepi-r2s|orangepi/r2s)
            echo "orangepi/r2s" ;;
        rv|opirv|orangepi-rv|orangepi/rv)
            echo "orangepi/rv" ;;
        f3|bpif3|bpi-f3|bananapi-f3|bananapi/f3|bananapi/bpi-f3|banana-pi/f3)
            echo "bananapi/f3" ;;
        cm6|bpicm6|bpi-cm6|bananapi-cm6|bananapi/cm6|bananapi/bpi-cm6|banana-pi/cm6)
            echo "bananapi/cm6" ;;
        jupiter2|jptr2|milkv-jupiter2|milkv/jupiter2|milk-v/jupiter2)
            echo "milkv/jupiter2" ;;
        jupiter|jptr1|jupiter1|milkv-jupiter|milkv/jupiter|milk-v/jupiter)
            echo "milkv/jupiter" ;;
        aibox-k3|aiboxk3|firefly-k3|firefly-aibox-k3|firefly/aibox-k3)
            echo "firefly/aibox-k3" ;;
        titan|dp1000|milkv-titan|milkv/titan|milk-v/titan|ultrarisc-titan|ultrarisc/titan)
            echo "milkv/titan" ;;
        espressif-esp32p4|espressif/esp32p4|waveshare-esp32-p4-wifi6|waveshare/esp32-p4-wifi6|waveshare-esp32-p4|waveshare/esp32-p4|waveshare-p4|waveshare/p4|esp32-p4-wifi6|esp32-p4-wifi6-dev-kit|esp32-p4|esp32p4|p4)
            echo "waveshare/esp32-p4-wifi6" ;;
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

_rvdk_kit_valid_pair() {
    local val="${1:-}"
    [[ "$val" =~ ^[a-z0-9][a-z0-9_-]*/[a-z0-9][a-z0-9._-]*$ ]] || return 1
    [[ "$val" != *..* ]] || return 1
    local left="${val%%/*}"
    local right="${val#*/}"
    [[ -n "$left" && "$left" != "." && "$left" != ".." ]] || return 1
    [[ -n "$right" && "$right" != "." && "$right" != ".." ]] || return 1
    [[ "$right" != .* && "$right" != *. ]] || return 1
    return 0
}

# Resolve a board query to an existing directory under `${repo_root}/boards/<vendor>/<slug>`
rvdk_resolve_board_dir() {
    local repo_root="$1"
    local query="$2"
    [[ -n "$query" ]] || return 1
    local norm
    norm="$(rvdk_normalize_board_id "$query")"
    if _rvdk_kit_valid_pair "$norm" && [[ -d "${repo_root}/boards/${norm}" ]]; then
        echo "${repo_root}/boards/${norm}"
        return 0
    fi
    [[ "$query" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || return 1
    [[ "$query" != "." && "$query" != ".." && "$query" != *..* && "$query" != .* && "$query" != *. ]] || return 1
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
# Args: [--refresh] [--no-cache] [--soc <v/s>] [--board <v/b>] [--os <id>]
# shellcheck disable=SC2120
rvdk_kit_resolve() {
    local force_refresh="false"
    local no_cache="false"
    local cli_soc=""
    local cli_board=""
    local cli_os=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --refresh)  force_refresh="true"; shift ;;
            --no-cache) no_cache="true"; shift ;;
            --soc)      cli_soc="${2:-}"; shift 2 ;;
            --board)    cli_board="${2:-}"; shift 2 ;;
            --os)       cli_os="${2:-}"; shift 2 ;;
            *)          shift ;;
        esac
    done

    local dt_override=""
    if [[ -n "${RVDK_DT_MODEL:-}" && "${RVDK_DT_MODEL}" != "${_RVDK_LAST_PROBED_DT_MODEL:-}" ]]; then
        dt_override="$RVDK_DT_MODEL"
    fi

    local has_override="false"
    [[ -n "$cli_soc" || -n "$cli_board" || -n "$cli_os" || -n "$dt_override" ]] && has_override="true"

    # 0ms in-memory fast-path when parent RVDK dispatcher already resolved the Kit
    if [[ "$force_refresh" == "false" && "$no_cache" == "false" && "$has_override" == "false" && "${RVDK_KIT_SCHEMA:-}" == "$RVDK_KIT_SCHEMA_VERSION" && -n "${RVDK_SOC:-}" && -n "${RVDK_OS_ID:-}" ]]; then
        if [[ -z "${RVDK_ARCH:-}" || -z "${RVDK_MMU:-}" ]]; then
            local _mem_am _mem_arch _mem_mmu
            _mem_am="$(_rvdk_infer_arch_mmu "${RVDK_SOC:-}")"
            IFS='|' read -r _mem_arch _mem_mmu <<< "$_mem_am"
            RVDK_ARCH="${RVDK_ARCH:-$_mem_arch}"
            RVDK_MMU="${RVDK_MMU:-$_mem_mmu}"
        fi
        if [[ "${RVDK_MMU:-unknown}" == "unknown" ]] && [[ "${RVDK_OS_ID:-}" == "esp-idf" || "${RVDK_OS_ID:-}" == "nuttx" || "${RVDK_OS_ID:-}" == "linux-nommu" ]]; then
            RVDK_MMU="none"
        fi
        export RVDK_ARCH RVDK_MMU
        return 0
    fi

    # <1ms disk fast-path: parse cached /etc/rvdk/kit.env safely via rvdk_kv_load without `source`
    if [[ "$force_refresh" == "false" && "$no_cache" == "false" && "$has_override" == "false" && -r "$RVDK_KIT_CACHE_FILE" ]]; then
        RVDK_ARCH=""
        RVDK_MMU=""
        rvdk_kv_load "$RVDK_KIT_CACHE_FILE" "${_RVDK_KIT_ALLOWED_KEYS[@]}" || true
        if [[ "${RVDK_KIT_SCHEMA:-}" == "$RVDK_KIT_SCHEMA_VERSION" && -n "${RVDK_SOC:-}" && -n "${RVDK_OS_ID:-}" ]]; then
            if [[ -z "${RVDK_ARCH:-}" || -z "${RVDK_MMU:-}" ]]; then
                local _disk_am _disk_arch _disk_mmu
                _disk_am="$(_rvdk_infer_arch_mmu "${RVDK_SOC:-}")"
                IFS='|' read -r _disk_arch _disk_mmu <<< "$_disk_am"
                RVDK_ARCH="${RVDK_ARCH:-$_disk_arch}"
                RVDK_MMU="${RVDK_MMU:-$_disk_mmu}"
            fi
            if [[ "${RVDK_MMU:-unknown}" == "unknown" ]] && [[ "${RVDK_OS_ID:-}" == "esp-idf" || "${RVDK_OS_ID:-}" == "nuttx" || "${RVDK_OS_ID:-}" == "linux-nommu" ]]; then
                RVDK_MMU="none"
            fi
            _RVDK_LAST_PROBED_DT_MODEL="${RVDK_DT_MODEL:-}"
            export RVDK_KIT_SCHEMA RVDK_DT_MODEL RVDK_SOC RVDK_SOC_SLUG RVDK_BOARD RVDK_BOARD_TAG RVDK_ARCH RVDK_MMU RVDK_FACTORY_USER RVDK_OS_ID RVDK_OS_VERSION_ID RVDK_PRIMARY_NIC RVDK_CPU_HARTS
            export RVDK_KIT_SOURCE="cache"
            return 0
        fi
    fi

    local dt_model="Unknown"
    if [[ -n "$dt_override" ]]; then
        dt_model="$dt_override"
    elif [[ -r /proc/device-tree/model ]]; then
        dt_model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        dt_model="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m) (macOS Host)"
    fi

    local inferred soc board tag factory_user
    inferred="$(_rvdk_infer_from_dt_model "$dt_model")"
    IFS='|' read -r soc board tag factory_user <<< "$inferred"

    if [[ -n "$cli_board" ]]; then
        if [[ -z "$cli_soc" ]]; then
            soc=""
        fi
        factory_user=""
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
            waveshare/esp32-p4-wifi6)   tag="p4" ;;
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
            waveshare/esp32-p4-wifi6) soc="espressif/esp32p4" ;;
        esac
    fi

    if [[ -z "$board" && -n "$soc" ]]; then
        case "$soc" in
            eswin/eic7700x)        board="sifive/p550";              tag="p550" ;;
            sifive/fu740)          board="sifive/unmatched";         tag="unmatched" ;;
            starfive/jh7110)       board="starfive/vf2";             tag="vf2"; factory_user="user" ;;
            spacemit/k1)           board="milkv/jupiter";            tag="jptr1" ;;
            spacemit/k3)           board="milkv/jupiter2";           tag="jptr2" ;;
            ultrarisc/dp1000)      board="milkv/titan";              tag="titan" ;;
            tenstorrent/atlantis)  board="tenstorrent/atlantis";     tag="atlantis" ;;
            tenstorrent/blackhole) board="tenstorrent/blackhole";    tag="blackhole" ;;
            espressif/esp32p4)     board="waveshare/esp32-p4-wifi6"; tag="p4" ;;
        esac
    fi

    # Reject malformed CLI overrides before persisting
    if [[ -n "$soc" ]] && ! _rvdk_kit_valid_pair "$soc"; then
        soc=""
    fi
    if [[ -n "$board" ]] && ! _rvdk_kit_valid_pair "$board"; then
        board=""
        tag=""
    fi

    local os_id="${cli_os:-}"
    local os_ver=""
    local os_like=""
    if [[ -z "$os_id" && -r /etc/os-release ]]; then
        local ID="" VERSION_ID="" ID_LIKE=""
        rvdk_kv_load /etc/os-release ID VERSION_ID ID_LIKE
        os_id="${ID:-unknown}"
        os_ver="${VERSION_ID:-}"
        os_like="${ID_LIKE:-}"
    elif [[ -z "$os_id" && -r /etc/openwrt_release ]]; then
        local DISTRIB_RELEASE=""
        rvdk_kv_load /etc/openwrt_release DISTRIB_RELEASE
        os_id="openwrt"
        os_ver="${DISTRIB_RELEASE:-}"
    elif [[ -z "$os_id" && "$(uname -s)" == "Darwin" ]]; then
        os_id="macos"
        os_ver="$(sw_vers -productVersion 2>/dev/null || true)"
    fi
    os_id="$(tr '[:upper:]' '[:lower:]' <<< "${os_id:-unknown}")"
    os_like="$(tr '[:upper:]' '[:lower:]' <<< "${os_like:-}")"

    # Normalize derivative RISC-V BSP distros & versioned media.json tags (ubuntu-24.04, debian-12, RockOS, RevyOS, Ky OpenWrt, ESP-IDF/NuttX/Buildroot/nommu)
    case "$os_id" in
        debian|ubuntu|bianbu|openwrt|macos|esp-idf|nuttx|buildroot|linux-nommu) ;;
        debian-*|rockos*|revyos*)   os_id="debian" ;;
        ubuntu-*)                   os_id="ubuntu" ;;
        bianbu-*)                   os_id="bianbu" ;;
        *openwrt*)                  os_id="openwrt" ;;
        esp-idf-*|esp_idf*|espidf*) os_id="esp-idf" ;;
        nuttx-*)                    os_id="nuttx" ;;
        buildroot-*)                os_id="buildroot" ;;
        linux-nommu-*|nommu*)       os_id="linux-nommu" ;;
        *)
            case " $os_like " in
                *" openwrt "*)     os_id="openwrt" ;;
                *" bianbu "*)      os_id="bianbu" ;;
                *" ubuntu "*)      os_id="ubuntu" ;;
                *" debian "*)      os_id="debian" ;;
                *" esp-idf "*)     os_id="esp-idf" ;;
                *" nuttx "*)       os_id="nuttx" ;;
                *" buildroot "*)   os_id="buildroot" ;;
                *" linux-nommu "*) os_id="linux-nommu" ;;
            esac
            ;;
    esac

    local arch_mmu arch mmu
    arch_mmu="$(_rvdk_infer_arch_mmu "$soc")"
    IFS='|' read -r arch mmu <<< "$arch_mmu"
    if [[ "$mmu" == "unknown" ]] && [[ "$os_id" == "esp-idf" || "$os_id" == "nuttx" || "$os_id" == "linux-nommu" ]]; then
        mmu="none"
    fi

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
    RVDK_ARCH="$arch"
    RVDK_MMU="$mmu"
    RVDK_FACTORY_USER="$factory_user"
    RVDK_OS_ID="$os_id"
    RVDK_OS_VERSION_ID="$os_ver"
    RVDK_PRIMARY_NIC="$primary_nic"
    RVDK_CPU_HARTS="$cpu_harts"
    RVDK_KIT_SOURCE="probed"
    _RVDK_LAST_PROBED_DT_MODEL="$dt_model"

    export RVDK_KIT_SCHEMA RVDK_DT_MODEL RVDK_SOC RVDK_SOC_SLUG RVDK_BOARD RVDK_BOARD_TAG RVDK_ARCH RVDK_MMU RVDK_FACTORY_USER RVDK_OS_ID RVDK_OS_VERSION_ID RVDK_PRIMARY_NIC RVDK_CPU_HARTS RVDK_KIT_SOURCE

    # Persist system-wide cache on Linux target nodes using escaped atomic serialization
    if [[ "$no_cache" == "false" && -z "$dt_override" && "$(uname -s)" == "Linux" && "${EUID:-$(id -u)}" -eq 0 && -n "$RVDK_SOC" ]] && [[ "$has_override" == "false" || "$force_refresh" == "true" ]]; then
        rvdk_kv_write "$RVDK_KIT_CACHE_FILE" 0644 \
            "DREW-V Labs // RVDK Kit Hardware & OS Cache (${RVDK_KIT_CACHE_FILE}) — refresh via: sudo rvdk kit --refresh" \
            "RVDK_KIT_SCHEMA=${RVDK_KIT_SCHEMA}" \
            "RVDK_DT_MODEL=${RVDK_DT_MODEL}" \
            "RVDK_SOC=${RVDK_SOC}" \
            "RVDK_SOC_SLUG=${RVDK_SOC_SLUG}" \
            "RVDK_BOARD=${RVDK_BOARD}" \
            "RVDK_BOARD_TAG=${RVDK_BOARD_TAG}" \
            "RVDK_ARCH=${RVDK_ARCH}" \
            "RVDK_MMU=${RVDK_MMU}" \
            "RVDK_FACTORY_USER=${RVDK_FACTORY_USER}" \
            "RVDK_OS_ID=${RVDK_OS_ID}" \
            "RVDK_OS_VERSION_ID=${RVDK_OS_VERSION_ID}" \
            "RVDK_PRIMARY_NIC=${RVDK_PRIMARY_NIC}" \
            "RVDK_CPU_HARTS=${RVDK_CPU_HARTS}"
    fi
}

# Single source of truth for silicon compiler profiles across C/C++ (GCC/Clang) & Go (GORISCV64).
# Sets: RVDK_TARGET_SLUG, RVDK_CPU_MTUNE, RVDK_MARCH_CANDIDATES, RVDK_MABI, RVDK_GORISCV64_CANDIDATES
# shellcheck disable=SC2120
rvdk_kit_compiler_profile() {
    local soc="${1:-${RVDK_SOC:-}}"
    local host_arch="${2:-$(uname -m)}"

    case "$host_arch" in
        riscv64)         host_arch="riscv64" ;;
        riscv32*)        host_arch="riscv32" ;;
        x86_64|amd64)    host_arch="amd64" ;;
        aarch64|arm64)   host_arch="arm64" ;;
    esac

    case "$soc" in
        eswin/eic7700x)
            RVDK_TARGET_SLUG="sifive-p550"
            RVDK_CPU_MTUNE="sifive-p550"
            RVDK_MARCH_CANDIDATES="rv64gc_zba_zbb rv64gc"
            RVDK_MABI="lp64d"
            RVDK_GORISCV64_CANDIDATES="rva20u64"
            ;;
        starfive/jh7110)
            RVDK_TARGET_SLUG="starfive-jh7110"
            RVDK_CPU_MTUNE="sifive-u74"
            RVDK_MARCH_CANDIDATES="rv64gc_zba_zbb rv64gc"
            RVDK_MABI="lp64d"
            RVDK_GORISCV64_CANDIDATES="rva20u64"
            ;;
        sifive/fu740)
            RVDK_TARGET_SLUG="sifive-fu740"
            RVDK_CPU_MTUNE="sifive-u74"
            RVDK_MARCH_CANDIDATES="rv64gc"
            RVDK_MABI="lp64d"
            RVDK_GORISCV64_CANDIDATES="rva20u64"
            ;;
        spacemit/k1)
            RVDK_TARGET_SLUG="spacemit-k1"
            RVDK_CPU_MTUNE="spacemit-x60"
            RVDK_MARCH_CANDIDATES="rv64gcv_zba_zbb_zbc_zbs rv64gc_zba_zbb rv64gc"
            RVDK_MABI="lp64d"
            RVDK_GORISCV64_CANDIDATES="rva22u64 rva20u64"
            ;;
        spacemit/k3)
            RVDK_TARGET_SLUG="spacemit-k3"
            RVDK_CPU_MTUNE="spacemit-x100"
            RVDK_MARCH_CANDIDATES="rva23u64 rv64gcv_zba_zbb_zbc_zbs rv64gc_zba_zbb rv64gc"
            RVDK_MABI="lp64d"
            RVDK_GORISCV64_CANDIDATES="rva23u64 rva22u64 rva20u64"
            ;;
        ultrarisc/dp1000)
            RVDK_TARGET_SLUG="ultrarisc-dp1000"
            RVDK_CPU_MTUNE="generic-ooo"
            RVDK_MARCH_CANDIDATES="rva22u64 rv64gc_zba_zbb_zbs rv64gc_zba_zbb rv64gc"
            RVDK_MABI="lp64d"
            RVDK_GORISCV64_CANDIDATES="rva22u64 rva20u64"
            ;;
        tenstorrent/atlantis|tenstorrent/blackhole)
            RVDK_TARGET_SLUG="${soc//\//-}"
            RVDK_CPU_MTUNE="tt-ascalon-d8"
            RVDK_MARCH_CANDIDATES="rva23u64 rv64gcv_zba_zbb_zbc_zbs rv64gc_zba_zbb rv64gc"
            RVDK_MABI="lp64d"
            RVDK_GORISCV64_CANDIDATES="rva23u64 rva22u64 rva20u64"
            ;;
        espressif/esp32p4)
            RVDK_TARGET_SLUG="espressif-esp32p4"
            RVDK_CPU_MTUNE=""
            RVDK_MARCH_CANDIDATES="rv32imafc_zicsr_zifencei_xespv2p1 rv32imafc_zicsr_zifencei rv32imafc"
            RVDK_MABI="ilp32f"
            RVDK_GORISCV64_CANDIDATES=""
            ;;
        *)
            case "$host_arch" in
                riscv64)
                    RVDK_TARGET_SLUG="riscv64-generic"
                    RVDK_CPU_MTUNE=""
                    RVDK_MARCH_CANDIDATES="rv64gc"
                    RVDK_MABI="lp64d"
                    RVDK_GORISCV64_CANDIDATES="rva20u64"
                    ;;
                riscv32)
                    RVDK_TARGET_SLUG="riscv32-generic"
                    RVDK_CPU_MTUNE=""
                    RVDK_MARCH_CANDIDATES="rv32imafc_zicsr_zifencei rv32imac"
                    RVDK_MABI="ilp32f"
                    RVDK_GORISCV64_CANDIDATES=""
                    ;;
                amd64|arm64)
                    RVDK_TARGET_SLUG="linux-${host_arch}"
                    RVDK_CPU_MTUNE=""
                    RVDK_MARCH_CANDIDATES=""
                    RVDK_MABI=""
                    RVDK_GORISCV64_CANDIDATES=""
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
    esac

    export RVDK_TARGET_SLUG RVDK_CPU_MTUNE RVDK_MARCH_CANDIDATES RVDK_MABI RVDK_GORISCV64_CANDIDATES
    return 0
}

# Probe local GCC support against RVDK_MARCH_CANDIDATES, RVDK_MABI, & RVDK_CPU_MTUNE.
# Sets: RVDK_SELECTED_MARCH, RVDK_OPT_CFLAGS
# shellcheck disable=SC2120
rvdk_kit_probe_cflags() {
    local cc_bin="${1:-gcc}"
    RVDK_SELECTED_MARCH=""
    RVDK_OPT_CFLAGS="-O3 -pipe"

    if [[ -n "${RVDK_MARCH_CANDIDATES:-}" ]]; then
        local -a cands=()
        read -r -a cands <<< "$RVDK_MARCH_CANDIDATES"
        if (( ${#cands[@]} > 0 )); then
            RVDK_SELECTED_MARCH="${cands[${#cands[@]}-1]}"
            local cand_march
            for cand_march in "${cands[@]}"; do
                if [[ -n "${RVDK_MABI:-}" ]] && "$cc_bin" -march="$cand_march" -mabi="${RVDK_MABI}" -E -x c /dev/null >/dev/null 2>&1; then
                    RVDK_SELECTED_MARCH="$cand_march"
                    break
                elif "$cc_bin" -march="$cand_march" -E -x c /dev/null >/dev/null 2>&1; then
                    RVDK_SELECTED_MARCH="$cand_march"
                    break
                fi
            done
            RVDK_OPT_CFLAGS="-O3 -pipe -march=${RVDK_SELECTED_MARCH}"
            if [[ -n "${RVDK_MABI:-}" ]]; then
                if "$cc_bin" -march="${RVDK_SELECTED_MARCH}" -mabi="${RVDK_MABI}" -E -x c /dev/null >/dev/null 2>&1; then
                    RVDK_OPT_CFLAGS="${RVDK_OPT_CFLAGS} -mabi=${RVDK_MABI}"
                fi
            fi
            if [[ -n "${RVDK_CPU_MTUNE:-}" ]]; then
                if "$cc_bin" -march="${RVDK_SELECTED_MARCH}" -mcpu="${RVDK_CPU_MTUNE}" -E -x c /dev/null >/dev/null 2>&1; then
                    RVDK_OPT_CFLAGS="${RVDK_OPT_CFLAGS} -mcpu=${RVDK_CPU_MTUNE} -mtune=${RVDK_CPU_MTUNE}"
                elif "$cc_bin" -march="${RVDK_SELECTED_MARCH}" -mtune="${RVDK_CPU_MTUNE}" -E -x c /dev/null >/dev/null 2>&1; then
                    RVDK_OPT_CFLAGS="${RVDK_OPT_CFLAGS} -mtune=${RVDK_CPU_MTUNE}"
                fi
            fi
        fi
    fi

    export RVDK_SELECTED_MARCH RVDK_OPT_CFLAGS
    return 0
}

# Probe Go toolchain support against RVDK_GORISCV64_CANDIDATES.
# Sets: RVDK_SELECTED_GORISCV64
# shellcheck disable=SC2120
rvdk_kit_probe_goriscv64() {
    local go_bin="${1:-go}"
    RVDK_SELECTED_GORISCV64=""

    if [[ "$(uname -m)" == "riscv64" && -n "${RVDK_GORISCV64_CANDIDATES:-}" ]]; then
        local -a go_cands=()
        read -r -a go_cands <<< "$RVDK_GORISCV64_CANDIDATES"
        if (( ${#go_cands[@]} > 0 )); then
            RVDK_SELECTED_GORISCV64="rva20u64"
            local cand_gorv
            for cand_gorv in "${go_cands[@]}"; do
                if GORISCV64="$cand_gorv" "$go_bin" list runtime >/dev/null 2>&1; then
                    RVDK_SELECTED_GORISCV64="$cand_gorv"
                    break
                fi
            done
        fi
    fi

    export RVDK_SELECTED_GORISCV64
    return 0
}

# Collect all applicable deeptune.sh layers for the resolved Kit in execution order:
#   1. os/deeptune.sh (Linux OSes; omitted for RTOSes such as esp-idf / nuttx)
#   2. os/deeptune-${RVDK_OS_ID:-unknown}.sh (if present)
#   3. bsp/<vendor>/<soc>/deeptune.sh (if present)
#   4. boards/<vendor>/<board>/deeptune.sh (if present)
rvdk_collect_deeptune_scripts() {
    local repo_root="$1"
    local candidates=()
    if [[ "${RVDK_OS_ID:-}" != "esp-idf" && "${RVDK_OS_ID:-}" != "nuttx" ]]; then
        candidates+=("${repo_root}/os/deeptune.sh")
        candidates+=("${repo_root}/os/deeptune-${RVDK_OS_ID:-unknown}.sh")
    fi
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
    printf 'RVDK_ARCH=%q\n'          "${RVDK_ARCH:-}"
    printf 'RVDK_MMU=%q\n'           "${RVDK_MMU:-}"
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

    local active_tune=""
    local dt_env="${RVDK_DEEPTUNE_ENV:-/etc/rvdk/deeptune.env}"
    if [[ ! -r "$dt_env" && -r /var/lib/rvdk/deeptune.conf ]]; then
        dt_env="/var/lib/rvdk/deeptune.conf"
    fi
    if [[ -r "$dt_env" ]]; then
        local RVDK_TUNE=""
        rvdk_kv_load "$dt_env" RVDK_TUNE || true
        active_tune="${RVDK_TUNE:-}"
    fi
    if [[ -n "$active_tune" ]]; then
        chain_str="${chain_str} (active: ${active_tune})"
    fi

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
    printf "  • Arch / MMU        : %s (mmu: %s)\n" "${RVDK_ARCH:-unknown}" "${RVDK_MMU:-unknown}"
    printf "  • OS (os/)          : %s %s\n" "${RVDK_OS_ID:-unknown}" "${RVDK_OS_VERSION_ID:-}"
    printf "  • Primary NIC / CPU : %s | %s Harts\n" "${RVDK_PRIMARY_NIC:-none}" "${RVDK_CPU_HARTS:-?}"
    printf "  • Kit Cache File    : %s\n" "$cache_status"
    printf "  • DeepTune Chain    : %s\n" "$chain_str"
    printf "  • Board Quirks      : %s\n" "$quirks_str"
}
