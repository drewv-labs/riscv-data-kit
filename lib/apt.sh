#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Idempotent APT Cache & Package Helper Library
# Path: riscv-data-kit/lib/apt.sh
#
# Honors:
#   RVDK_NO_APT_UPDATE=1|true   Skip redundant `apt-get update` when index lists
#                               already exist in /var/lib/apt/lists/.
#   RVDK_APT_STAMP_FILE=<path>  Touched whenever `apt-get update` actually runs
#                               so parent pipelines (rvdk day0 / brakerrak) can
#                               set APT_UPDATED=true for subsequent modules.
# ==============================================================================

rvdk_apt_has_lists() {
    compgen -G "/var/lib/apt/lists/*Packages*" >/dev/null 2>&1 || \
    compgen -G "/var/lib/apt/lists/*InRelease" >/dev/null 2>&1
}

rvdk_apt_mark_updated() {
    export RVDK_NO_APT_UPDATE="1"
    if [[ -n "${RVDK_APT_STAMP_FILE:-}" ]]; then
        touch "$RVDK_APT_STAMP_FILE" 2>/dev/null || true
    fi
}

rvdk_apt_update() {
    if [[ "${RVDK_NO_APT_UPDATE:-0}" == "1" || "${RVDK_NO_APT_UPDATE:-false}" == "true" ]]; then
        if rvdk_apt_has_lists; then
            return 0
        fi
    fi
    apt-get -o Acquire::Check-Valid-Until=false -o DPkg::Lock::Timeout=120 update -q || \
        apt-get -o DPkg::Lock::Timeout=120 update -q
    rvdk_apt_mark_updated
}

rvdk_pkg_installed() {
    dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -qx "install ok installed"
}

rvdk_apt_ensure() {
    local missing=()
    local pkg
    for pkg in "$@"; do
        [[ -z "$pkg" ]] && continue
        if ! rvdk_pkg_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done

    [[ ${#missing[@]} -eq 0 ]] && return 0

    local flags=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")
    if [[ -n "${APT_FLAGS[0]+x}" ]]; then
        flags=("${APT_FLAGS[@]}")
    fi

    rvdk_apt_update
    if ! apt-get install "${flags[@]}" "${missing[@]}"; then
        # Self-heal if --no-apt-update was passed with stale mirror indices
        RVDK_NO_APT_UPDATE="0" rvdk_apt_update
        apt-get install "${flags[@]}" "${missing[@]}"
    fi
}
