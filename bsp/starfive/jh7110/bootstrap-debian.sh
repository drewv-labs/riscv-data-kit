#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // StarFive JH7110 / JH7110S (SiFive U74) Debian BSP Bootstrapper
# Path: riscv-data-kit/bsp/starfive/jh7110/bootstrap-debian.sh
# Description: Idempotent Layer 2 BSP hardening for StarFive JH7110 / JH7110S
#              (VisionFive 2, VisionFive 2 Lite, Milk-V Mars, Orange Pi RV) on Debian:
#              - Protects vendor U-Boot & DTB hooks (/etc/kernel/postinst.d/zz-u-boot-menu)
#              - Migrates legacy StarFive snapshot/debian-ports & CN mirror sources
#                onto signed US-first HTTPS Debian mirrors (`--with-vendor-repo`
#                opt-in for StarFive's legacy vendor repository)
#              - Purges Wayland/Weston/X11/GTK & unblocks t64 prior to full-upgrade
#              - Persists primary wired NIC (eth0/end0) safely, masks sleep targets,
#                locks U74 max OPP governor, and unlocks SiFive U74 PMU counters.
#
# @RVDK_DAY0_ORDER: pre-os
#
# Usage:
#   sudo rvdk bsp [--skip-upgrade] [--full-upgrade] [--debian-suite trixie|unstable] [--with-vendor-repo] [--expose-kallsyms]
# ==============================================================================

set -Eeuo pipefail

ORIG_ARGS=("$@")
SKIP_UPGRADE="false"
FORCE_FULL_UPGRADE="false"
DEBIAN_SUITE="trixie"
EXPOSE_KALLSYMS="false"
WITH_VENDOR_REPO="false"
UPGRADE_STAMP="/var/lib/rvdk/jh7110-debian-full-upgrade.stamp"

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

# @RVDK_INLINE_LIBS: common apt bsp progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:JH7110]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_sanitize_locale() { export LANG="C.UTF-8" LC_ALL="C.UTF-8"; }
        rvdk_atomic_write() {
            local _dst="$1" _mode="${2:-0644}" _own="${3:-}" _tmp
            mkdir -p "$(dirname "$_dst")"
            _tmp="$(mktemp "$(dirname "$_dst")/.$(basename "$_dst").rvdk.XXXXXX")"
            cat > "$_tmp"
            chmod "$_mode" "$_tmp"
            [[ -n "$_own" ]] && chown "$_own" "$_tmp"
            mv -f "$_tmp" "$_dst"
        }
    fi
fi
if [[ -z "${_RVDK_APT_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/apt.sh" ]]; then
        # shellcheck source=lib/apt.sh
        source "${_REPO_ROOT}/lib/apt.sh"
    fi
fi
if [[ -z "${_RVDK_BSP_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/bsp.sh" ]]; then
        # shellcheck source=lib/bsp.sh
        source "${_REPO_ROOT}/lib/bsp.sh"
    fi
fi
if [[ -z "${_RVDK_PROGBAR_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]]; then
        # shellcheck source=lib/progbar.sh
        source "${_REPO_ROOT}/lib/progbar.sh"
    else
        rvdk_prog_init() { :; }
        rvdk_prog()      { :; }
    fi
fi

rvdk_log_init "RVDK:JH7110"

usage() {
    cat <<'EOF'
Usage: sudo rvdk bsp [OPTIONS]
Layer 2 BSP script: bsp/starfive/jh7110/bootstrap-debian.sh

Options:
  --skip-upgrade              Skip apt-get full-upgrade pass
  --full-upgrade              Force re-running apt-get full-upgrade even when stamped
  --debian-suite <suite>      Target Debian suite (trixie|unstable; default: trixie)
  --with-vendor-repo          Retain StarFive legacy Debian vendor repository if keyring exists
  --expose-kallsyms           Set kernel.kptr_restrict to 0 (exposes kernel symbols for perf; weakens KASLR)
  --keep-mirrors              Preserve existing APT mirror configuration
  --no-apt-update             Skip redundant apt-get update calls
  --noprogbar                 Disable persistent bottom progress bar
  -h, --help                  Show this help message and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-upgrade)                    SKIP_UPGRADE="true"; shift ;;
        --full-upgrade)                    FORCE_FULL_UPGRADE="true"; shift ;;
        --debian-suite)
            [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument (trixie|unstable)."
            DEBIAN_SUITE="$2"
            shift 2 ;;
        --with-vendor-repo)                WITH_VENDOR_REPO="true"; shift ;;
        --expose-kallsyms)                 EXPOSE_KALLSYMS="true"; shift ;;
        --keep-mirrors)                    export RVDK_KEEP_VENDOR_MIRRORS="1"; shift ;;
        --no-apt-update|--skip-apt-update) export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)          export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)                         usage; exit 0 ;;
        *)                                 log_fatal "Unknown argument: $1 (try --help)" ;;
    esac
done

case "$DEBIAN_SUITE" in
    trixie|testing|sid|unstable) ;;
    *) log_fatal "Invalid --debian-suite '${DEBIAN_SUITE}' (expected trixie or unstable)." ;;
esac

rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
rvdk_sanitize_locale

rvdk_prog_init "JH7110 BSP: inspecting device tree..."
DT_MODEL="$(rvdk_bsp_read_dt_model)"
log_info "Detected Device-Tree Model: ${DT_MODEL}"

# 1. Bootloader, FIT & Vendor U-Boot Hook Protection (without permanent --force-overwrite)
rvdk_prog 12 "JH7110 BSP: protecting U-Boot & FIT/DTB hooks..."
rvdk_bsp_protect_dpkg "/etc/apt/apt.conf.d/90-starfive-bsp-protect" "StarFive U-Boot/DTB"
rvdk_bsp_backup_boot_configs \
    /boot/extlinux/extlinux.conf \
    /boot/boot/extlinux/extlinux.conf \
    /boot/efi/extlinux.conf \
    /etc/default/u-boot \
    /etc/kernel/postinst.d/zz-u-boot-menu

# 2. Migrate Legacy StarFive Snapshot / debian-ports / CN Mirrors Over Signed US-First HTTPS
rvdk_prog 28 "JH7110 BSP: checking APT sources & keyring..."
SNAPSHOT_MIGRATION="false"
if grep -rqE "snapshot\.debian\.org|debian-ports|VF2-Lite" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    SNAPSHOT_MIGRATION="true"
    DEBIAN_KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
    if [[ ! -s "$DEBIAN_KEYRING" ]]; then
        log_fatal "Cannot safely migrate legacy StarFive snapshot sources: missing ${DEBIAN_KEYRING}. Install debian-archive-keyring manually before retrying."
    fi

    log_info "Migrating legacy StarFive snapshot APT sources to signed HTTPS Debian (${DEBIAN_SUITE})..."
    mkdir -p /var/lib/rvdk/backups/apt
    if [[ -f /etc/apt/sources.list && ! -f /var/lib/rvdk/backups/apt/etc__apt__sources.list.orig ]]; then
        cp -a /etc/apt/sources.list "/var/lib/rvdk/backups/apt/etc__apt__sources.list.orig" 2>/dev/null || true
    fi
    rm -f /etc/apt/trusted.gpg.d/debian-ports* 2>/dev/null || true

    NEW_SOURCES="deb [signed-by=${DEBIAN_KEYRING}] https://deb.debian.org/debian ${DEBIAN_SUITE} main contrib non-free non-free-firmware"
    if [[ "$DEBIAN_SUITE" == "trixie" || "$DEBIAN_SUITE" == "testing" ]]; then
        NEW_SOURCES+=$'\n'"deb [signed-by=${DEBIAN_KEYRING}] https://deb.debian.org/debian ${DEBIAN_SUITE}-updates main contrib non-free non-free-firmware"
        NEW_SOURCES+=$'\n'"deb [signed-by=${DEBIAN_KEYRING}] https://security.debian.org/debian-security ${DEBIAN_SUITE}-security main contrib non-free non-free-firmware"
    fi
    if [[ "$WITH_VENDOR_REPO" == "true" ]] && [[ -f /etc/apt/trusted.gpg.d/starfive.gpg || -f /usr/share/keyrings/starfive-archive-keyring.gpg ]]; then
        NEW_SOURCES+=$'\n'"deb https://debianrepo-t.starfivetech.com starfive-debian main"
    fi
    printf '%s\n' "$NEW_SOURCES" | rvdk_atomic_write /etc/apt/sources.list 0644

    rm -rf /var/lib/apt/lists/*
    apt-get clean
    RVDK_NO_APT_UPDATE="0" rvdk_apt_update
    rvdk_apt_ensure ca-certificates debian-archive-keyring
    log_ok "Migrated legacy StarFive snapshot sources to signed US-first HTTPS (${DEBIAN_SUITE})"
else
    declare -F rvdk_apt_normalize_mirrors >/dev/null 2>&1 && rvdk_apt_normalize_mirrors
fi

if command -v systemctl >/dev/null 2>&1 && [[ "$(systemctl get-default 2>/dev/null || true)" != "multi-user.target" ]]; then
    systemctl set-default multi-user.target
    log_ok "Boot target set to headless multi-user.target"
fi

# 3. Strip Legacy Factory Wayland/Weston/X11/GTK Prior to t64 Upgrade
rvdk_prog 42 "JH7110 BSP: checking desktop GUI & t64 blockers..."
VF2_GUI_PKGS=("weston*" "wayland*" "x11-common" "libx11-*" "libgtk*" "lightdm*" "task-desktop" "plymouth")
NEED_GUI_PURGE="false"
for pattern in weston x11-common lightdm task-desktop plymouth; do
    if dpkg -l "$pattern" 2>/dev/null | grep -q "^ii"; then
        NEED_GUI_PURGE="true"
        break
    fi
done

if [[ "$NEED_GUI_PURGE" == "true" ]]; then
    log_info "Purging StarFive desktop GUI packages prior to upgrade..."
    apt-get purge "${APT_FLAGS[@]}" "${VF2_GUI_PKGS[@]}" || true
    apt-get autoremove "${APT_FLAGS[@]}" --purge
    apt-get clean
    log_ok "Purged Wayland, Weston, X11, GTK, and LightDM desktop bloat"
else
    log_skip "Desktop GUI packages already purged"
fi

if [[ "$SNAPSHOT_MIGRATION" == "true" ]] && dpkg -l 2>/dev/null | grep -q "^ii.*libcurl3-gnutls"; then
    dpkg --remove --force-depends libcurl3-gnutls:riscv64 2>/dev/null || true
    log_ok "Removed legacy libcurl3-gnutls:riscv64 t64 blocker"
fi

JH7110_CORE_PKGS=(
    build-essential dkms pciutils nvme-cli lvm2 parted git curl wget
    htop jq tmux bc rsync time sysstat linux-perf zstd dpkg-dev
)

if [[ "$SKIP_UPGRADE" == "true" ]]; then
    log_skip "Skipped apt-get full-upgrade (--skip-upgrade)"
elif [[ -f "$UPGRADE_STAMP" && "$FORCE_FULL_UPGRADE" != "true" && "$SNAPSHOT_MIGRATION" != "true" ]]; then
    rvdk_prog 72 "JH7110 BSP: verifying core build & perf packages..."
    rvdk_apt_ensure "${JH7110_CORE_PKGS[@]}"
    log_skip "Initial Debian ${DEBIAN_SUITE} full-upgrade already converged (${UPGRADE_STAMP}; pass --full-upgrade to re-run)"
else
    rvdk_prog 58 "JH7110 BSP: converging system packages & utilities..."
    rvdk_apt_update
    UPGRADE_FLAGS=("${APT_FLAGS[@]}")
    if [[ "$SNAPSHOT_MIGRATION" == "true" ]]; then
        UPGRADE_FLAGS+=(-o Dpkg::Options::="--force-overwrite")
    fi
    apt-get full-upgrade "${UPGRADE_FLAGS[@]}"
    rvdk_prog 72 "JH7110 BSP: verifying core build & perf packages..."
    rvdk_apt_ensure "${JH7110_CORE_PKGS[@]}"
    K_HDR="linux-headers-$(uname -r)"
    if ! dpkg -s "$K_HDR" >/dev/null 2>&1; then
        apt-get install "${APT_FLAGS[@]}" "$K_HDR" 2>/dev/null || true
    fi
    mkdir -p /var/lib/rvdk
    printf 'SUITE=%s\nCONVERGED_AT=%s\n' "$DEBIAN_SUITE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | rvdk_atomic_write "$UPGRADE_STAMP" 0644
    log_ok "System packages and JH7110 utilities converged"
fi

# 4. SSH-Safe Primary Wired NIC Persistence & Sleep Lockout
rvdk_prog 82 "JH7110 BSP: persisting primary wired NIC & masking sleep..."
rvdk_bsp_persist_wired_nic "jh7110" eth0 end0
rvdk_bsp_mask_sleep_targets apt-daily.timer apt-daily-upgrade.timer

# 5. Lock Max OPP Governor & Unlock SiFive U74 PMU Counters (kptr_restrict=1 default)
MAX_KHZ="$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "")"
if [[ "$MAX_KHZ" =~ ^[0-9]+$ ]] && (( MAX_KHZ > 0 )); then
    MAX_MHZ_LABEL="$(( MAX_KHZ / 1000 )) MHz"
else
    MAX_MHZ_LABEL="max OPP"
fi

rvdk_prog 92 "JH7110 BSP: locking ${MAX_MHZ_LABEL} governor & U74 PMU..."
rvdk_bsp_lock_cpufreq_performance "jh7110" "Lock StarFive JH7110/JH7110S SiFive U74 Harts to Performance Governor"
rvdk_bsp_unlock_pmu "/etc/sysctl.d/90-starfive-u74-pmu.conf" "SiFive U74" "$EXPOSE_KALLSYMS"

rvdk_prog 100 "StarFive JH7110/JH7110S BSP hardening complete"
log_info "StarFive JH7110/JH7110S (Debian) BSP bootstrap complete."
