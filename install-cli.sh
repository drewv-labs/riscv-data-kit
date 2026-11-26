#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK CLI & Engine Installer
# Path: riscv-data-kit/install-cli.sh
# Description: Stages the riscv-data-kit engine and caches strictly in system
#              space (/usr/local/share/rvdk/engine, /etc/rvdk, /var/cache/rvdk)
#              with zero ~/.rvdk user-home footprint, and links /usr/bin/rvdk +
#              /usr/local/bin/rvdk without modifying OS/BSP state.
#
# Usage:
#   curl -fsSL https://rvdk.drewv-labs.dev/install-cli.sh | sudo bash
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

for _arg in "$@"; do
    if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
        cat <<'EOF'
Usage:
  curl -fsSL https://rvdk.drewv-labs.dev/install-cli.sh | sudo bash [-s -- --quiet]

Options:
  -q, --quiet   Suppress post-install banner
  -h, --help    Show this help message and exit
EOF
        exit 0
    fi
done

if [[ $EUID -ne 0 ]]; then
    if [[ -n "$SCRIPT_SELF" && -f "$SCRIPT_SELF" ]] && command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$SCRIPT_SELF" "$@"
    else
        echo "[RVDK:FATAL] Pipe into 'sudo bash': curl -fsSL https://rvdk.drewv-labs.dev/install-cli.sh | sudo bash" >&2
        exit 1
    fi
fi

# Enforce 022 umask so system directories and cloned scripts remain 0755/0644
# even on hardened root environments with umask 077/027.
umask 022

_REPO_ROOT=""
if [[ -n "$SCRIPT_SELF" && -f "$SCRIPT_SELF" ]]; then
    _REPO_ROOT="$(cd "$(dirname "$SCRIPT_SELF")" && pwd)"
fi

# @RVDK_INLINE_LIBS: common
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:CLI]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_sanitize_locale() { export LANG="C" LC_ALL="C"; }
        rvdk_resolve_caller() { REAL_USER="${SUDO_USER:-root}"; REAL_GRP="root"; REAL_HOME="/root"; }
        rvdk_atomic_write() {
            local _dst="$1" _mode="${2:-0644}" _tmp
            _tmp="$(mktemp "$(dirname "$_dst")/.$(basename "$_dst").rvdk.XXXXXX")"
            cat > "$_tmp"
            chmod "$_mode" "$_tmp"
            mv -f "$_tmp" "$_dst"
        }
        rvdk_sync_cold_clock() { :; }
    fi
fi

if ! typeset -f rvdk_assert_safe_managed_dir >/dev/null 2>&1; then
    rvdk_assert_safe_managed_dir() {
        local raw_path="${1:-}"
        local var_name="${2:-PATH}"

        if [[ -z "$raw_path" || "$raw_path" != /* ]]; then
            log_fatal "Unsafe ${var_name}: '${raw_path}' must be a non-empty absolute path."
        fi
        if [[ "$raw_path" =~ [[:cntrl:]] ]]; then
            log_fatal "Unsafe ${var_name}: '${raw_path}' contains control characters."
        fi

        local norm="$raw_path"
        while [[ "$norm" == *//* ]]; do
            norm="${norm//\/\///}"
        done
        while [[ "$norm" != "/" && "$norm" == */ ]]; do
            norm="${norm%/}"
        done

        if [[ "$norm" == "/" ]]; then
            log_fatal "Unsafe ${var_name}: '${raw_path}' resolves to root '/'."
        fi

        local comp_count=0 seg rest="${norm#/}"
        while [[ -n "$rest" ]]; do
            if [[ "$rest" == */* ]]; then
                seg="${rest%%/*}"
                rest="${rest#*/}"
            else
                seg="$rest"
                rest=""
            fi
            [[ -z "$seg" ]] && continue
            if [[ "$seg" == "." || "$seg" == ".." ]]; then
                log_fatal "Unsafe ${var_name}: '${raw_path}' contains '.' or '..' traversal segment."
            fi
            comp_count=$(( comp_count + 1 ))
        done

        if [[ -L "$raw_path" || -L "$norm" ]]; then
            log_fatal "Unsafe ${var_name}: '${raw_path}' is a symbolic link."
        fi

        if (( comp_count < 2 )); then
            log_fatal "Unsafe ${var_name}: '${raw_path}' must have at least 2 path components."
        fi

        if [[ -n "${REAL_HOME:-}" ]]; then
            local norm_home="$REAL_HOME"
            while [[ "$norm_home" == *//* ]]; do
                norm_home="${norm_home//\/\///}"
            done
            while [[ "$norm_home" != "/" && "$norm_home" == */ ]]; do
                norm_home="${norm_home%/}"
            done
            if [[ "$norm" == "$norm_home" ]]; then
                log_fatal "Unsafe ${var_name}: '${raw_path}' resolves to user home '${norm_home}'."
            fi
        fi

        case "$norm" in
            /usr|/usr/local|/usr/local/share|/var|/var/cache|/var/lib|/etc|/home|/root|/opt|/tmp)
                log_fatal "Unsafe ${var_name}: '${raw_path}' is a protected system directory."
                ;;
        esac

        return 0
    }
fi

rvdk_log_init "RVDK:CLI"
rvdk_sanitize_locale
rvdk_resolve_caller

LEGACY_HOME_RVDK="${REAL_HOME}/.rvdk"
SYS_ETC_DIR="/etc/rvdk"
CACHE_DIR="${RVDK_CACHE_DIR:-/var/cache/rvdk}"
ENGINE_DIR="${RVDK_ENGINE_DIR:-/usr/local/share/rvdk/engine}"
rvdk_assert_safe_managed_dir "$CACHE_DIR" "RVDK_CACHE_DIR"
rvdk_assert_safe_managed_dir "$ENGINE_DIR" "RVDK_ENGINE_DIR"
while [[ "$CACHE_DIR" == *//* ]]; do CACHE_DIR="${CACHE_DIR//\/\///}"; done
while [[ "$CACHE_DIR" != "/" && "$CACHE_DIR" == */ ]]; do CACHE_DIR="${CACHE_DIR%/}"; done
while [[ "$ENGINE_DIR" == *//* ]]; do ENGINE_DIR="${ENGINE_DIR//\/\///}"; done
while [[ "$ENGINE_DIR" != "/" && "$ENGINE_DIR" == */ ]]; do ENGINE_DIR="${ENGINE_DIR%/}"; done
ENGINE_PARENT="$(dirname "$ENGINE_DIR")"
REPO_URL="${RVDK_REPO_URL:-https://github.com/drewv-labs/riscv-data-kit.git}"
REPO_BRANCH="${RVDK_BRANCH:-main}"
QUIET_MODE="false"

for arg in "$@"; do
    case "$arg" in
        -q|--quiet) QUIET_MODE="true" ;;
        *) log_fatal "Unknown argument: ${arg} (try --help)" ;;
    esac
done

if [[ ! "$REPO_BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
    log_fatal "Invalid RVDK_BRANCH name: '${REPO_BRANCH}'."
fi

# 0. Recover cold-RTC clocks (< 2026-01-01 floor) on batteryless Linux SBCs
#    monotonically before APT InRelease validation or git HTTPS transport runs.
rvdk_sync_cold_clock

# 0b. Scrub factory CN mirrors onto US-first signed HTTPS endpoints BEFORE Day-0
#     prerequisite installs (`git`, `curl`, `bash`) ever touch `apt-get` / `opkg` / `apk`.
normalize_pkg_mirrors_early() {
    [[ "$(uname -s)" == "Linux" ]] || return 0
    if [[ "${RVDK_KEEP_VENDOR_MIRRORS:-0}" == "1" || "${RVDK_KEEP_VENDOR_MIRRORS:-false}" == "true" ]]; then
        return 0
    fi

    local cn_hosts="repo\\.huaweicloud\\.com|mirrors\\.tuna\\.tsinghua\\.edu\\.cn|mirrors\\.bfsu\\.edu\\.cn|mirrors\\.ustc\\.edu\\.cn|mirrors\\.aliyun\\.com|mirrors\\.163\\.com|mirrors\\.cloud\\.tencent\\.com|mirrors\\.sohu\\.com|mirrors\\.zju\\.edu\\.cn|mirrors\\.nju\\.edu\\.cn|mirrors\\.sjtug\\.sjtu\\.edu\\.cn|mirrors\\.shanghaitech\\.edu\\.cn|mirrors\\.hit\\.edu\\.cn|mirrors\\.lzu\\.edu\\.cn|mirrors\\.cqu\\.edu\\.cn|mirrors\\.neusoft\\.edu\\.cn|mirrors\\.xjtu\\.edu\\.cn|mirror\\.iscas\\.ac\\.cn|mirror\\.sjtu\\.edu\\.cn|mirror\\.lzu\\.edu\\.cn|cn\\.archive\\.ubuntu\\.com|hk\\.archive\\.ubuntu\\.com|ftp\\.cn\\.debian\\.org|ftp\\.hk\\.debian\\.org"
    local scheme="http"
    [[ -s /etc/ssl/certs/ca-certificates.crt || -s /etc/ssl/certs/ca-bundle.crt ]] && scheme="https"

    if command -v apt-get >/dev/null 2>&1; then
        local src_files=() f
        [[ -f /etc/apt/sources.list ]] && src_files+=("/etc/apt/sources.list")
        if [[ -d /etc/apt/sources.list.d ]]; then
            while IFS= read -r f; do
                [[ -n "$f" ]] && src_files+=("$f")
            done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null | sort)
        fi
        local changed="false" rendered bname backup_dir="/var/lib/rvdk/backups/apt"
        local -a sed_exprs=(
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/debian-security([[:space:]/]|$)@${scheme}://security.debian.org/debian-security\\2@g"
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/debian([[:space:]/]|$)@${scheme}://deb.debian.org/debian\\2@g"
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/ubuntu-ports([[:space:]/]|$)@${scheme}://ports.ubuntu.com/ubuntu-ports\\2@g"
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/ubuntu([[:space:]/]|$)@${scheme}://us.archive.ubuntu.com/ubuntu\\2@g"
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/armbian([[:space:]/]|$)@${scheme}://apt.armbian.com\\2@g"
        )
        if [[ "$scheme" == "https" ]]; then
            sed_exprs+=(-e '/^[[:space:]]*#/! s@http://apt\.armbian\.com([[:space:]/]|$)@https://apt.armbian.com\1@g')
        fi
        for f in ${src_files[@]+"${src_files[@]}"}; do
            [[ -f "$f" ]] || continue
            rendered="$(sed -E "${sed_exprs[@]}" "$f")"
            if ! printf '%s\n' "$rendered" | cmp -s - "$f" 2>/dev/null; then
                mkdir -p "$backup_dir"
                bname="$(printf '%s' "$f" | sed 's@^/@@; s@/@__@g')"
                [[ -f "${backup_dir}/${bname}.orig" ]] || cp -a "$f" "${backup_dir}/${bname}.orig" 2>/dev/null || true
                printf '%s\n' "$rendered" | rvdk_atomic_write "$f" 0644
                changed="true"
            fi
        done
        if [[ "$changed" == "true" ]]; then
            rm -rf /var/lib/apt/lists/* 2>/dev/null || true
            log_ok "Normalized factory APT mirrors onto US-first signed ${scheme} endpoints"
        fi
    fi

    local owrt_f owrt_rendered
    for owrt_f in /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf /etc/apk/repositories; do
        [[ -f "$owrt_f" ]] || continue
        owrt_rendered="$(sed -E "/^[[:space:]]*#/! s@https?://(${cn_hosts})/openwrt([[:space:]/]|$)@${scheme}://downloads.openwrt.org\\2@g" "$owrt_f")"
        if ! printf '%s\n' "$owrt_rendered" | cmp -s - "$owrt_f" 2>/dev/null; then
            mkdir -p /var/lib/rvdk/backups/openwrt
            [[ -f "/var/lib/rvdk/backups/openwrt/$(basename "$owrt_f").orig" ]] || cp -a "$owrt_f" "/var/lib/rvdk/backups/openwrt/$(basename "$owrt_f").orig" 2>/dev/null || true
            printf '%s\n' "$owrt_rendered" | rvdk_atomic_write "$owrt_f" 0644
            log_ok "Normalized OpenWrt package feeds onto ${scheme}://downloads.openwrt.org"
        fi
    done
}

# 1. Ensure bash, git (+ HTTPS transport), and curl are installed across Debian/Ubuntu/Bianbu & OpenWrt
NEED_GIT_HTTP="false"
if [[ -f /etc/openwrt_release ]] && command -v git >/dev/null 2>&1 && [[ ! -x /usr/lib/git-core/git-remote-https ]]; then
    NEED_GIT_HTTP="true"
fi

if ! command -v bash >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || [[ "$NEED_GIT_HTTP" == "true" ]]; then
    normalize_pkg_mirrors_early
    if command -v apt-get >/dev/null 2>&1; then
        log_info "Installing bash, git, and curl prerequisites (APT)..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o DPkg::Lock::Timeout=120 update -q || true
        apt-get -o DPkg::Lock::Timeout=120 install -y bash git ca-certificates curl
    elif command -v opkg >/dev/null 2>&1; then
        log_info "Installing bash, git-http, and curl prerequisites (OpenWrt opkg)..."
        opkg update
        opkg install bash git git-http curl ca-bundle
    elif command -v apk >/dev/null 2>&1; then
        log_info "Installing bash, git, and curl prerequisites (OpenWrt/Alpine apk)..."
        apk add --no-cache bash git curl ca-certificates
    else
        log_fatal "Missing git or curl. On macOS, run 'xcode-select --install' or 'brew install git curl'."
    fi
fi

# 2. Stage system-space directories (/etc/rvdk, /var/cache/rvdk, /usr/local/share/rvdk/engine)
mkdir -p "$SYS_ETC_DIR" "$CACHE_DIR" "$ENGINE_PARENT"
chmod 0755 "$SYS_ETC_DIR" /usr/local /usr/local/share "$ENGINE_PARENT" 2>/dev/null || true
if [[ "$(uname -s)" == "Darwin" ]]; then
    chown 0:admin "$CACHE_DIR" 2>/dev/null || chown 0:0 "$CACHE_DIR" 2>/dev/null || true
    chmod 1775 "$CACHE_DIR" 2>/dev/null || chmod 0755 "$CACHE_DIR" 2>/dev/null || true
else
    chown 0:0 "$CACHE_DIR" 2>/dev/null || true
    chmod 0755 "$CACHE_DIR" 2>/dev/null || true
fi

if [[ -d "${ENGINE_DIR}/.git" ]]; then
    log_info "Updating RVDK engine in ${ENGINE_DIR} (${REPO_BRANCH})..."
    chown -R 0:0 "$ENGINE_DIR" 2>/dev/null || true
    git -C "$ENGINE_DIR" fetch origin "$REPO_BRANCH" -q
    git -C "$ENGINE_DIR" reset --hard "origin/${REPO_BRANCH}" -q
else
    log_info "Cloning ${REPO_URL} into ${ENGINE_DIR}..."
    rm -rf "$ENGINE_DIR"
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$ENGINE_DIR" -q
fi

chown -R 0:0 "$ENGINE_DIR" 2>/dev/null || true
chmod -R a+rX "$ENGINE_DIR" 2>/dev/null || true
chmod 0755 "$ENGINE_DIR"
chmod +x \
    "${ENGINE_DIR}/bootstrap.sh" \
    "${ENGINE_DIR}/install-cli.sh" \
    "${ENGINE_DIR}"/lib/*.sh \
    "${ENGINE_DIR}"/os/*.sh \
    "${ENGINE_DIR}"/bsp/*/*/*.sh \
    "${ENGINE_DIR}"/boards/*/*/*.sh \
    "${ENGINE_DIR}"/boards/*/*/quirks/*.sh \
    "${ENGINE_DIR}"/postgresql/*/forge.sh \
    "${ENGINE_DIR}"/mods/*/forge.sh \
    "${ENGINE_DIR}"/utils/*.sh 2>/dev/null || true

# Promote & retire any legacy ~/.rvdk user-home directory into system space
if [[ -d "$LEGACY_HOME_RVDK" && "$ENGINE_DIR" != "${LEGACY_HOME_RVDK}/engine" ]]; then
    if [[ -f "${LEGACY_HOME_RVDK}/config.env" ]]; then
        if [[ ! -f "${SYS_ETC_DIR}/config.env" ]]; then
            cp -a "${LEGACY_HOME_RVDK}/config.env" "${SYS_ETC_DIR}/config.env"
            chown 0:0 "${SYS_ETC_DIR}/config.env" 2>/dev/null || true
            chmod 0640 "${SYS_ETC_DIR}/config.env" 2>/dev/null || true
        fi
        rm -f "${LEGACY_HOME_RVDK}/config.env" 2>/dev/null || true
    fi
    if [[ -d "${LEGACY_HOME_RVDK}/cache" ]]; then
        for _citem in "${LEGACY_HOME_RVDK}/cache/"*; do
            [[ -e "$_citem" ]] || continue
            _cbase="$(basename "$_citem")"
            [[ -e "${CACHE_DIR}/${_cbase}" ]] || mv -f "$_citem" "${CACHE_DIR}/${_cbase}" 2>/dev/null || true
        done
        rm -rf "${LEGACY_HOME_RVDK}/cache" 2>/dev/null || true
    fi
    rm -rf "${LEGACY_HOME_RVDK}/engine" 2>/dev/null || true
    rmdir "$LEGACY_HOME_RVDK" 2>/dev/null || true
fi

# Persist /etc/rvdk/kit.env cache on Linux target nodes right away if recognized
if [[ "$(uname -s)" == "Linux" && -f "${ENGINE_DIR}/lib/kit.sh" ]]; then
    # shellcheck source=lib/kit.sh
    source "${ENGINE_DIR}/lib/kit.sh"
    rvdk_kit_resolve --refresh || true
fi

# 3. Link /usr/local/bin/rvdk AND (on Linux) /usr/bin/rvdk so classic sudo,
#    Debian forky/sid sudo-rs, doas, OpenWrt, and root/user shells always resolve `rvdk`.
mkdir -p /usr/local/bin
chmod 0755 /usr/local /usr/local/bin 2>/dev/null || true
ln -sf "${ENGINE_DIR}/bootstrap.sh" /usr/local/bin/rvdk
LINKED_PATHS="/usr/local/bin/rvdk"
if [[ "$(uname -s)" == "Linux" && -d /usr/bin ]]; then
    if ln -sf "${ENGINE_DIR}/bootstrap.sh" /usr/bin/rvdk 2>/dev/null; then
        LINKED_PATHS="/usr/bin/rvdk & /usr/local/bin/rvdk"
    fi
fi
COMMIT_SHA="$(git -C "$ENGINE_DIR" rev-parse --short HEAD 2>/dev/null || echo "main")"
log_ok "Linked ${LINKED_PATHS} -> ${ENGINE_DIR}/bootstrap.sh (${COMMIT_SHA})"

if [[ "$QUIET_MODE" == "false" ]]; then
    DT_MODEL="${RVDK_DT_MODEL:-Unknown}"
    if [[ "$DT_MODEL" == "Unknown" ]]; then
        if [[ -r /proc/device-tree/model ]]; then
            DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")"
        elif [[ "$(uname -s)" == "Darwin" ]]; then
            DT_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m) (macOS Host)"
        fi
    fi

    OS_PRETTY="Unknown"
    if [[ -r /etc/os-release ]]; then
        OS_PRETTY="$(awk -F= '/^PRETTY_NAME=/ {sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit}' /etc/os-release 2>/dev/null || echo "Unknown")"
    elif [[ -r /etc/openwrt_release ]]; then
        OS_PRETTY="$(awk -F= '/^DISTRIB_DESCRIPTION=/ {sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit}' /etc/openwrt_release 2>/dev/null || echo "OpenWrt")"
    elif command -v sw_vers >/dev/null 2>&1; then
        OS_PRETTY="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) ($(uname -m))"
    fi

    cat <<EOF

======================================================================
 DREW-V Labs // RVDK CLI Installed (${COMMIT_SHA})
   Board : ${DT_MODEL}
   OS    : ${OS_PRETTY}
   Root  : ${ENGINE_DIR}

 Usage:
   sudo rvdk                      # Run full Day-0 (OS + Silicon BSP) bootstrap
   rvdk kit                       # Inspect resolved Board/SoC/OS Kit cache
   sudo rvdk deeptune             # Multi-layer DeepTune (--tune data|ai|iot)
   sudo rvdk storage [status|...] # Live LVM elastic manager (grow, shrink, autotune)
   sudo rvdk quirk <name|list>    # Toggle board quirks (e.g. hdmi, fusb)
   rvdk flash <board> <medium>    # Flash board media (e.g. rvdk flash p550 usb 4)
   sudo rvdk bsp                  # Run Silicon BSP hardening only
   sudo rvdk os                   # Run OS normalization & rvdk-net-guard only
   sudo rvdk postgresql           # Install PostgreSQL 18.6 (cache or --force-build)
   sudo rvdk mods/nvme-4kn        # Format 4Kn NVMe + LVM vg_rvdk + XFS/Btrfs
   sudo rvdk mods/btrfs-raid
   sudo rvdk mods/mosquitto
   sudo rvdk mods/ntfy            # Install ntfy pub/sub broker (cache or --force-build)
   sudo rvdk mods/nfs-vault
   sudo rvdk mods/tailscale       # Install static riscv64 Tailscale VPN [--ssh|--up]
   sudo rvdk utils/purge-user.sh  # Migrate state & purge factory default user
   sudo rvdk update               # Pull latest RVDK engine from GitHub
   sudo rvdk uninstall            # Remove RVDK CLI & caches (--purge for full wipe)
======================================================================
EOF
fi
