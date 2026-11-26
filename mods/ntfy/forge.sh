#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: ntfy HTTP & Unix Socket Pub/Sub Broker (riscv64)
# Path: riscv-data-kit/mods/ntfy/forge.sh
#
# Security, Supply-Chain & Persistence Hardening:
#   • SHA-256 verifies precompiled RVDK catalog binary bundles (.tar.zst) by default
#     (failing fast unless pinned in catalog or --bundle-sha256 / --allow-remote-sha256 / --force-build)
#   • Supports explicit --force-build unprivileged source compilation using SHA-256
#     verified go.dev/dl toolchains + lib/kit.sh compiler profiles
#   • Binds HTTP listener to `127.0.0.1:2586` + `0660` `/run/ntfy/ntfy.sock` (`Group=ntfy`)
#   • Non-loopback `--bind` requires `--ntfy-user` + `--ntfy-password`/`--ntfy-password-file`
#     OR explicit `--allow-anonymous`
#   • Runs `ntfy user` mutations as user `ntfy` (never `root`) & tracks convergence via
#     keyed HMAC-SHA256 (`/etc/ntfy/.rvdk-auth.key` + `/etc/ntfy/.rvdk-auth.sha256`)
# ==============================================================================
set -Eeuo pipefail

ORIG_ARGS=("$@")
export DEBIAN_FRONTEND=noninteractive
# shellcheck disable=SC2034 # Consumed by lib/apt.sh rvdk_apt_ensure
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"

# @RVDK_INLINE_LIBS: common kit apt progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:NTFY]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_sanitize_locale() { export LANG="C.UTF-8" LC_ALL="C.UTF-8"; }
        rvdk_resolve_caller() { REAL_USER="${SUDO_USER:-root}"; REAL_GRP="root"; export REAL_USER REAL_GRP; }
        rvdk_load_config_env() { :; }
        rvdk_normalize_mount_path() {
            local p="${1:-}"
            while [[ "$p" != "/" && "$p" == */ ]]; do p="${p%/}"; done
            printf '%s\n' "$p"
        }
        rvdk_resolve_data_mount() {
            local explicit="${1:-${MOUNT_POINT:-}}"
            if [[ -n "$explicit" ]]; then
                rvdk_normalize_mount_path "$explicit"
            elif mountpoint -q /mnt/nvme_data 2>/dev/null; then
                printf '%s\n' "/mnt/nvme_data"
            else
                printf '%s' ""
            fi
        }
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
if [[ -z "${_RVDK_KIT_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/kit.sh" ]]; then
        # shellcheck source=lib/kit.sh
        source "${_REPO_ROOT}/lib/kit.sh"
    fi
fi
if [[ -z "${_RVDK_APT_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/apt.sh" ]]; then
        # shellcheck source=lib/apt.sh
        source "${_REPO_ROOT}/lib/apt.sh"
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

rvdk_log_init "RVDK:NTFY"

usage() {
    cat <<'EOF'
Usage: sudo rvdk mods/ntfy [options]

Options:
  --bind <ip>                 HTTP TCP bind address (default: 127.0.0.1)
  --port <port>               HTTP TCP port (default: 2586)
  --base-url <url>            Public/LAN base URL (default: http://<bind-or-ip>:<port>)
  --upstream-base-url <url>   Optional iOS APNS wakeup relay (e.g. https://ntfy.sh)
  --ntfy-user <user>          Provision user in ntfy auth DB & enforce deny-all default ACL
  --ntfy-password <pass>      Password for --ntfy-user (prefer --ntfy-password-file or NTFY_PASSWORD env)
  --ntfy-password-file <path> Read password for --ntfy-user from file (avoids argv exposure)
  --ntfy-role <admin|user>    Role for --ntfy-user (default: admin)
  --allow-anonymous           Explicitly permit unauthenticated clients on non-loopback --bind
  --cache-duration <dur>      Message cache retention duration (default: 12h)
  --behind-proxy              Trust X-Forwarded-For reverse proxy headers
  --with-web                  Enable embedded React web UI at / (builds web/ on --force-build)
  --database-url <pg-url>     Use PostgreSQL backend instead of local SQLite cache/auth DBs
  --data-mount <path>         Optional NVMe mount root for persistence directory
  --version <X.Y.Z>           ntfy upstream release version (default: 2.38.1)
  --force-build               Cold-compile ntfy from source & emit RVDK catalog .tar.zst bundle
  --keep-build-dir            Retain build workspace after --force-build
  --bundle-sha256 <hex64>     Expected SHA-256 digest for prebuilt .tar.zst bundle
  --allow-remote-sha256       Trust same-origin .sha256 sidecar when --bundle-sha256 is unset
  --soc <vendor/soc>          Explicit SoC target override
  --board <vendor/board>      Explicit board target override
  --no-apt-update             Skip redundant apt-get update calls
  --noprogbar                 Disable persistent bottom progress bar
  -h, --help                  Show this help message and exit
EOF
}

for _arg in "$@"; do
    if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
        usage
        exit 0
    fi
done

rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
rvdk_sanitize_locale
rvdk_resolve_caller

rvdk_load_config_env \
    MOUNT_POINT NTFY_VERSION NTFY_PORT NTFY_BIND NTFY_BASE_URL NTFY_UPSTREAM_BASE_URL \
    NTFY_ALLOW_ANONYMOUS NTFY_USER NTFY_PASSWORD NTFY_PASSWORD_FILE NTFY_ROLE NTFY_CACHE_DURATION \
    NTFY_BEHIND_PROXY NTFY_ENABLE_WEB NTFY_DATABASE_URL \
    NTFY_PREBUILT_URL NTFY_PREBUILT_SHA256 RVDK_RELEASE_BASE

NTFY_VERSION="${NTFY_VERSION:-2.38.1}"
NTFY_VERSION="${NTFY_VERSION#v}"
NTFY_PORT="${NTFY_PORT:-2586}"
NTFY_BIND="${NTFY_BIND:-127.0.0.1}"
NTFY_BASE_URL="${NTFY_BASE_URL:-}"
NTFY_UPSTREAM_BASE_URL="${NTFY_UPSTREAM_BASE_URL:-}"
NTFY_ALLOW_ANONYMOUS="${NTFY_ALLOW_ANONYMOUS:-}"
NTFY_USER="${NTFY_USER:-}"
NTFY_PASSWORD="${NTFY_PASSWORD:-}"
NTFY_PASSWORD_FILE="${NTFY_PASSWORD_FILE:-}"
NTFY_ROLE="${NTFY_ROLE:-admin}"
NTFY_CACHE_DURATION="${NTFY_CACHE_DURATION:-12h}"
NTFY_BEHIND_PROXY="${NTFY_BEHIND_PROXY:-false}"
NTFY_ENABLE_WEB="${NTFY_ENABLE_WEB:-false}"
NTFY_DATABASE_URL="${NTFY_DATABASE_URL:-}"

FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
ALLOW_REMOTE_SHA="false"
SKIP_BUNDLE_SHA="false"
BUNDLE_SHA256="${NTFY_PREBUILT_SHA256:-}"
RVDK_RELEASE_BASE="${RVDK_RELEASE_BASE:-https://github.com/drewv-labs/riscv-data-kit/releases/download/rvdk-v1}"
CLI_SOC=""
CLI_BOARD=""
EXPLICIT_DATA_MOUNT=""

_require_arg() {
    [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."
    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            _require_arg "$1" "${2:-}"
            NTFY_VERSION="${2#v}"
            shift 2 ;;
        --port)
            _require_arg "$1" "${2:-}"; NTFY_PORT="$2"; shift 2 ;;
        --bind)
            _require_arg "$1" "${2:-}"; NTFY_BIND="$2"; shift 2 ;;
        --base-url)
            _require_arg "$1" "${2:-}"; NTFY_BASE_URL="$2"; shift 2 ;;
        --upstream-base-url|--upstream)
            _require_arg "$1" "${2:-}"; NTFY_UPSTREAM_BASE_URL="$2"; shift 2 ;;
        --allow-anonymous)
            NTFY_ALLOW_ANONYMOUS="true"; shift ;;
        --ntfy-user)
            _require_arg "$1" "${2:-}"; NTFY_USER="$2"; shift 2 ;;
        --ntfy-password)
            [[ -z "${2:-}" ]] && log_fatal "Option '$1' requires an argument."
            NTFY_PASSWORD="$2"; shift 2 ;;
        --ntfy-password-file)
            _require_arg "$1" "${2:-}"; NTFY_PASSWORD_FILE="$2"; shift 2 ;;
        --ntfy-role)
            _require_arg "$1" "${2:-}"; NTFY_ROLE="$2"; shift 2 ;;
        --cache-duration)
            _require_arg "$1" "${2:-}"; NTFY_CACHE_DURATION="$2"; shift 2 ;;
        --behind-proxy)
            NTFY_BEHIND_PROXY="true"; shift ;;
        --with-web|--enable-web)
            NTFY_ENABLE_WEB="true"; shift ;;
        --database-url)
            _require_arg "$1" "${2:-}"; NTFY_DATABASE_URL="$2"; shift 2 ;;
        --data-mount)
            _require_arg "$1" "${2:-}"; EXPLICIT_DATA_MOUNT="$2"; shift 2 ;;
        --force-build|--force-rebuild-ntfy|--compile)
            FORCE_BUILD="true"; shift ;;
        --keep-build-dir)
            KEEP_BUILD_DIR="true"; shift ;;
        --bundle-sha256)
            _require_arg "$1" "${2:-}"; BUNDLE_SHA256="$2"; shift 2 ;;
        --allow-remote-sha256)
            ALLOW_REMOTE_SHA="true"; shift ;;
        --insecure-skip-sha256)
            SKIP_BUNDLE_SHA="true"; shift ;;
        --soc)
            _require_arg "$1" "${2:-}"; CLI_SOC="$2"; shift 2 ;;
        --board)
            _require_arg "$1" "${2:-}"; CLI_BOARD="$2"; shift 2 ;;
        --no-apt-update|--skip-apt-update)
            export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)
            export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            log_fatal "Unknown argument: $1 (try --help)" ;;
    esac
done

if [[ "$SKIP_BUNDLE_SHA" == "true" ]]; then
    log_warn "SECURITY WARNING: --insecure-skip-sha256 enabled — prebuilt bundle SHA-256 verification is DISABLED!"
fi

if [[ -n "$NTFY_PASSWORD_FILE" ]]; then
    [[ -r "$NTFY_PASSWORD_FILE" ]] || log_fatal "Cannot read --ntfy-password-file '${NTFY_PASSWORD_FILE}'."
    NTFY_PASSWORD="$(tr -d '\r\n' < "$NTFY_PASSWORD_FILE")"
fi

DATA_MOUNT="$(rvdk_resolve_data_mount "$EXPLICIT_DATA_MOUNT")"

[[ "$NTFY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?$ ]] || log_fatal "Invalid --version '${NTFY_VERSION}'."
[[ "$NTFY_PORT" =~ ^[0-9]+$ ]] && (( NTFY_PORT >= 1 && NTFY_PORT <= 65535 )) || log_fatal "Invalid --port '${NTFY_PORT}'."
[[ "$NTFY_BIND" =~ ^[A-Za-z0-9.:_-]+$ ]] || log_fatal "Invalid --bind address '${NTFY_BIND}'."
[[ "$NTFY_CACHE_DURATION" =~ ^[0-9]+(ms|s|m|h|d)$ ]] || log_fatal "Invalid --cache-duration '${NTFY_CACHE_DURATION}'."

case "$NTFY_ROLE" in
    admin|user) ;;
    *) log_fatal "Invalid --ntfy-role '${NTFY_ROLE}' (expected: admin | user)." ;;
esac

case "$NTFY_BEHIND_PROXY" in
    true|1|yes)    NTFY_BEHIND_PROXY="true" ;;
    false|0|no|"") NTFY_BEHIND_PROXY="false" ;;
    *) log_fatal "Invalid NTFY_BEHIND_PROXY '${NTFY_BEHIND_PROXY}' (expected: true | false)." ;;
esac

case "$NTFY_ENABLE_WEB" in
    true|1|yes)    NTFY_ENABLE_WEB="true" ;;
    false|0|no|"") NTFY_ENABLE_WEB="false" ;;
    *) log_fatal "Invalid NTFY_ENABLE_WEB '${NTFY_ENABLE_WEB}' (expected: true | false)." ;;
esac

if [[ -n "$NTFY_BASE_URL" ]]; then
    NTFY_BASE_URL="${NTFY_BASE_URL%/}"
    [[ "$NTFY_BASE_URL" =~ ^https?://[A-Za-z0-9.:/_-]+$ ]] || log_fatal "Invalid --base-url '${NTFY_BASE_URL}'."
fi
if [[ -n "$NTFY_UPSTREAM_BASE_URL" ]]; then
    NTFY_UPSTREAM_BASE_URL="${NTFY_UPSTREAM_BASE_URL%/}"
    [[ "$NTFY_UPSTREAM_BASE_URL" =~ ^https?://[A-Za-z0-9.:/_-]+$ ]] || log_fatal "Invalid --upstream-base-url '${NTFY_UPSTREAM_BASE_URL}'."
fi
if [[ -n "$NTFY_DATABASE_URL" ]]; then
    [[ "$NTFY_DATABASE_URL" != *$'\n'* && "$NTFY_DATABASE_URL" != *'"'* ]] || log_fatal "Invalid characters in --database-url."
fi

IS_LOOPBACK="false"
if [[ "$NTFY_BIND" == "127.0.0.1" || "$NTFY_BIND" == "localhost" || "$NTFY_BIND" == "::1" ]]; then
    IS_LOOPBACK="true"
fi

if [[ -n "$NTFY_USER" || -n "$NTFY_PASSWORD" ]]; then
    [[ -n "$NTFY_USER" && -n "$NTFY_PASSWORD" ]] || log_fatal "Both --ntfy-user and --ntfy-password/--ntfy-password-file (or NTFY_PASSWORD) must be provided together."
    [[ "$NTFY_USER" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --ntfy-user '${NTFY_USER}'."
fi

if [[ "$IS_LOOPBACK" == "false" && -z "$NTFY_USER" && "$NTFY_ALLOW_ANONYMOUS" != "true" ]]; then
    log_fatal "Refusing to expose unauthenticated ntfy broker on '${NTFY_BIND}:${NTFY_PORT}'. Pass --ntfy-user/--ntfy-password-file or explicit --allow-anonymous."
fi

run_as_user() {
    local acct="$1"
    shift
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$acct" -- "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u "$acct" "$@"
    else
        su -s /bin/sh "$acct" -c 'exec "$@"' -- sh "$@"
    fi
}

run_ntfy_as_user() {
    if command -v runuser >/dev/null 2>&1; then
        NTFY_PASSWORD="$NTFY_PASSWORD" runuser -u ntfy -- /usr/bin/ntfy "$@"
    elif command -v sudo >/dev/null 2>&1; then
        NTFY_PASSWORD="$NTFY_PASSWORD" sudo --preserve-env=NTFY_PASSWORD -u ntfy /usr/bin/ntfy "$@"
    else
        NTFY_PASSWORD="$NTFY_PASSWORD" su -s /bin/sh ntfy -c 'exec /usr/bin/ntfy "$@"' -- sh "$@"
    fi
}

_ntfy_curl() {
    local url="$1"
    shift
    if [[ "$url" == https://* ]]; then
        curl --proto '=https' --tlsv1.2 "$@" "$url"
    else
        curl "$@" "$url"
    fi
}

_NTFY_TMP_ARCHIVE=""
_NTFY_TMP_EXTRACT=""
_NTFY_TMP_PKG=""
_NTFY_TMP_GO_TGZ=""
_NTFY_BUILD_ACTIVE="false"
NTFY_LIB_ROOT="/var/lib/rvdk/ntfy-riscv64"
BUNDLE_DIR="${NTFY_LIB_ROOT}/bundles"
BUILD_DIR="${NTFY_LIB_ROOT}/build"
INSTALLED_STAMP="${NTFY_LIB_ROOT}/installed.env"

_rvdk_ntfy_cleanup() {
    if [[ "${_RVDK_CLEANUP_RUNNING:-0}" != "1" ]]; then
        declare -F _rvdk_cleanup_tmpfiles >/dev/null 2>&1 && _rvdk_cleanup_tmpfiles || true
    fi
    [[ -n "$_NTFY_TMP_ARCHIVE" ]] && rm -f "$_NTFY_TMP_ARCHIVE" "${_NTFY_TMP_ARCHIVE}.sha256" 2>/dev/null || true
    [[ -n "$_NTFY_TMP_GO_TGZ" ]] && rm -f "$_NTFY_TMP_GO_TGZ" 2>/dev/null || true
    [[ -n "$_NTFY_TMP_EXTRACT" && -d "$_NTFY_TMP_EXTRACT" ]] && rm -rf "$_NTFY_TMP_EXTRACT" 2>/dev/null || true
    [[ -n "$_NTFY_TMP_PKG" && -d "$_NTFY_TMP_PKG" ]] && rm -rf "$_NTFY_TMP_PKG" 2>/dev/null || true
    if [[ "$_NTFY_BUILD_ACTIVE" == "true" && "$KEEP_BUILD_DIR" != "true" && -d "$BUILD_DIR" ]]; then
        rm -rf "$BUILD_DIR" 2>/dev/null || true
    fi
}
if declare -F rvdk_register_cleanup >/dev/null 2>&1; then
    rvdk_register_cleanup _rvdk_ntfy_cleanup
elif [[ -z "$(trap -p EXIT 2>/dev/null || true)" ]]; then
    trap '_rvdk_ntfy_cleanup' EXIT
    trap '_rvdk_ntfy_cleanup; trap - EXIT INT; kill -INT $$' INT
    trap '_rvdk_ntfy_cleanup; trap - EXIT TERM; kill -TERM $$' TERM
fi

rvdk_prog_init "ntfy ${NTFY_VERSION}: detecting RISC-V silicon profile..."

# 1. Resolve Silicon Target, CGO Compiler Flags & Go RVA Profile via lib/kit.sh
UNAME_M="$(uname -m)"
case "$UNAME_M" in
    riscv64)       GO_HOST_ARCH="riscv64" ;;
    x86_64|amd64)  GO_HOST_ARCH="amd64" ;;
    aarch64|arm64) GO_HOST_ARCH="arm64" ;;
    *)             log_fatal "Unsupported CPU architecture for ntfy: ${UNAME_M}" ;;
esac

_KIT_ARGS=()
[[ -n "$CLI_SOC" ]] && _KIT_ARGS+=("--soc" "$CLI_SOC")
[[ -n "$CLI_BOARD" ]] && _KIT_ARGS+=("--board" "$CLI_BOARD")
rvdk_kit_resolve ${_KIT_ARGS[@]+"${_KIT_ARGS[@]}"}

if ! rvdk_kit_compiler_profile "${CLI_SOC:-${RVDK_SOC:-}}" "$UNAME_M"; then
    log_fatal "Unsupported CPU/SoC target for ntfy: '${RVDK_DT_MODEL:-unknown}' (${UNAME_M})."
fi
TARGET_SLUG="$RVDK_TARGET_SLUG"

BUNDLE_NAME="ntfy-${NTFY_VERSION}-${TARGET_SLUG}.tar.zst"
BUNDLE_URL="${NTFY_PREBUILT_URL:-${RVDK_RELEASE_BASE}/${BUNDLE_NAME}}"
LOCAL_BUNDLE="${BUNDLE_DIR}/${BUNDLE_NAME}"
LOCAL_BUNDLE_SHA="${LOCAL_BUNDLE}.sha256"

# Official rvdk-v1 release bundle SHA-256 registry, keyed by TARGET_SLUG and BUNDLE_NAME.
# Returns empty when a target/bundle has no published pinned digest recorded yet.
_ntfy_pinned_bundle_sha256() {
    local target_slug="${1:-${TARGET_SLUG:-}}"
    local bundle_name="${2:-${BUNDLE_NAME:-ntfy-${NTFY_VERSION:-2.38.1}-${target_slug}.tar.zst}}"
    case "${target_slug}:${bundle_name}" in
        # Add only verified rvdk-v1 release digests here as:
        # <target_slug>:<bundle_name>) printf '%s\n' '<64-char lowercase hex>' ;;
        *)
            printf ''
            ;;
    esac
}

go_meets_min_version() {
    local go_bin="$1"
    local req_ver="${2:-1.26}"
    [[ -x "$go_bin" ]] || return 1
    local raw_ver
    raw_ver="$("$go_bin" env GOVERSION 2>/dev/null || "$go_bin" version 2>/dev/null | awk '{print $3}' || true)"
    raw_ver="${raw_ver#go}"
    [[ "$raw_ver" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    local got_maj="${BASH_REMATCH[1]}" got_min="${BASH_REMATCH[2]}"
    [[ "$req_ver" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    local req_maj="${BASH_REMATCH[1]}" req_min="${BASH_REMATCH[2]}"
    (( got_maj > req_maj || (got_maj == req_maj && got_min >= req_min) ))
}

ensure_go_toolchain() {
    local req_ver="${1:-1.26}"
    local base_cache="${RVDK_CACHE_DIR:-/var/cache/rvdk}"
    local go_cache_root="${base_cache}/go"
    local cand_bin=""

    if command -v go >/dev/null 2>&1; then
        cand_bin="$(command -v go)"
        if go_meets_min_version "$cand_bin" "$req_ver"; then
            printf '%s\n' "$cand_bin"
            return 0
        fi
    fi

    if [[ -x "${go_cache_root}/current/bin/go" ]] && go_meets_min_version "${go_cache_root}/current/bin/go" "$req_ver"; then
        printf '%s\n' "${go_cache_root}/current/bin/go"
        return 0
    fi

    mkdir -p "$go_cache_root"
    chmod 0755 "$base_cache" "$go_cache_root" 2>/dev/null || true

    local dl_json meta go_ver go_file go_sha
    dl_json="$(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "https://go.dev/dl/?mode=json")" || log_fatal "Failed to query Go toolchain catalog at https://go.dev/dl/?mode=json"
    meta="$(jq -r --arg arch "$GO_HOST_ARCH" '
        [ .[] | select(.stable == true) ][0] as $rel
        | ($rel.files[] | select(.os == "linux" and .arch == $arch and .kind == "archive"))
        | "\($rel.version)|\(.filename)|\(.sha256)"
    ' <<< "$dl_json" | head -n1)"
    IFS='|' read -r go_ver go_file go_sha <<< "$meta"
    [[ -n "$go_ver" && -n "$go_file" && "$go_sha" =~ ^[0-9a-fA-F]{64}$ ]] || log_fatal "No official Go linux-${GO_HOST_ARCH} archive advertised by go.dev/dl"
    go_sha="$(tr '[:upper:]' '[:lower:]' <<< "$go_sha")"

    local cached_tgz="${go_cache_root}/${go_file}"
    local need_dl="true"
    if [[ -f "$cached_tgz" ]]; then
        if [[ "$(rvdk_sha256_file "$cached_tgz")" == "$go_sha" ]]; then
            need_dl="false"
        fi
    fi

    if [[ "$need_dl" == "true" ]]; then
        log_info "Downloading official Go toolchain ${go_ver} (${go_file})..." >&2
        _NTFY_TMP_GO_TGZ="${cached_tgz}.tmp.$$"
        curl --proto '=https' --tlsv1.2 -fL --retry 3 "https://go.dev/dl/${go_file}" -o "$_NTFY_TMP_GO_TGZ"
        local actual_sha
        actual_sha="$(rvdk_sha256_file "$_NTFY_TMP_GO_TGZ")"
        if [[ "$actual_sha" != "$go_sha" ]]; then
            rm -f "$_NTFY_TMP_GO_TGZ"
            _NTFY_TMP_GO_TGZ=""
            log_fatal "SHA-256 MISMATCH for ${go_file}: expected ${go_sha}, got ${actual_sha}."
        fi
        mv -f "$_NTFY_TMP_GO_TGZ" "$cached_tgz"
        _NTFY_TMP_GO_TGZ=""
        chmod 0644 "$cached_tgz"
    fi

    local ver_dir="${go_cache_root}/${go_ver}"
    if [[ ! -x "${ver_dir}/go/bin/go" ]]; then
        rm -rf "$ver_dir"
        mkdir -p "$ver_dir"
        tar --no-same-owner --no-same-permissions -xzf "$cached_tgz" -C "$ver_dir"
        chmod -R a+rX "$ver_dir" 2>/dev/null || true
    fi
    ln -sfn "${ver_dir}/go" "${go_cache_root}/current"
    log_ok "Verified Go toolchain ${go_ver} (${go_sha:0:16}...)" >&2
    printf '%s\n' "${go_cache_root}/current/bin/go"
}

_ntfy_stage_built_binary() {
    local stage_root="$1"
    local dst_bin="$2"
    local src_bin="${stage_root}/usr/bin/ntfy"
    if [[ -L "$stage_root" || ! -d "$stage_root" || -L "${stage_root}/usr" || ! -d "${stage_root}/usr" || -L "${stage_root}/usr/bin" || ! -d "${stage_root}/usr/bin" ]]; then
        log_fatal "Refusing symlinked or invalid ntfy staging directory: ${stage_root}"
    fi
    if [[ ! -f "$src_bin" || -L "$src_bin" ]]; then
        log_fatal "Refusing symlink or non-regular ntfy binary at ${src_bin}"
    fi
    install -d -m 0755 -o root -g root "$(dirname "$dst_bin")"
    install -m 0755 -o root -g root "$src_bin" "$dst_bin"
}

# 2. Install ntfy (Verified RVDK Precompiled Bundle -> Unprivileged Source Compile Fallback)
rvdk_prog 15 "ntfy ${NTFY_VERSION}: checking binary & service state..."
INSTALLED_VER=""
if [[ -x /usr/bin/ntfy ]]; then
    INSTALLED_VER="$(/usr/bin/ntfy --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//' || true)"
fi

INSTALLED_WEB_EMBEDDED="false"
if [[ -r "$INSTALLED_STAMP" ]]; then
    NTFY_STAMP_WEB=""
    rvdk_kv_load "$INSTALLED_STAMP" NTFY_STAMP_WEB
    INSTALLED_WEB_EMBEDDED="${NTFY_STAMP_WEB:-false}"
fi

NEED_BINARY="true"
if [[ "$INSTALLED_VER" == "$NTFY_VERSION" && -f /etc/systemd/system/ntfy.service && "$FORCE_BUILD" == "false" ]]; then
    if [[ "$NTFY_ENABLE_WEB" != "true" || "$INSTALLED_WEB_EMBEDDED" == "true" ]]; then
        NEED_BINARY="false"
    fi
fi

if [[ -n "$NTFY_USER" ]] && ! command -v python3 >/dev/null 2>&1; then
    rvdk_apt_ensure python3-minimal
fi

BINARIES_CHANGED="false"
if [[ "$NEED_BINARY" == "false" ]]; then
    log_skip "ntfy ${NTFY_VERSION} (${TARGET_SLUG}) is already installed (pass --force-build to recompile)"
else
    mkdir -p /var/lib/rvdk "$NTFY_LIB_ROOT" "$BUNDLE_DIR"
    chmod 0755 /var/lib/rvdk "$NTFY_LIB_ROOT" 2>/dev/null || true
    rvdk_prog 20 "ntfy ${NTFY_VERSION}: verifying archive & download prerequisites..."
    rvdk_apt_ensure curl ca-certificates zstd

    if [[ "$FORCE_BUILD" == "false" ]]; then
        HAVE_VERIFIED_LOCAL="false"
        if [[ -f "$LOCAL_BUNDLE" ]]; then
            EXPECTED_LOCAL_SHA="$(printf '%s' "$BUNDLE_SHA256" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')"
            if [[ -z "$EXPECTED_LOCAL_SHA" && -f "$LOCAL_BUNDLE_SHA" ]]; then
                EXPECTED_LOCAL_SHA="$(awk '{print tolower($1); exit}' "$LOCAL_BUNDLE_SHA")"
            fi
            if [[ -z "$EXPECTED_LOCAL_SHA" && -z "${NTFY_PREBUILT_URL:-}" && "${RVDK_RELEASE_BASE%/}" == */rvdk-v1 ]]; then
                EXPECTED_LOCAL_SHA="$(_ntfy_pinned_bundle_sha256 "$TARGET_SLUG" "$BUNDLE_NAME" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')"
            fi
            if [[ "$EXPECTED_LOCAL_SHA" =~ ^[0-9a-f]{64}$ ]]; then
                if [[ "$(rvdk_sha256_file "$LOCAL_BUNDLE")" == "$EXPECTED_LOCAL_SHA" ]]; then
                    HAVE_VERIFIED_LOCAL="true"
                    log_skip "Using verified local RVDK bundle: ${LOCAL_BUNDLE}"
                fi
            fi
        fi

        if [[ "$HAVE_VERIFIED_LOCAL" == "false" ]]; then
            EXPECTED_BUNDLE_SHA="$(printf '%s' "$BUNDLE_SHA256" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')"
            if [[ -z "$EXPECTED_BUNDLE_SHA" && -z "${NTFY_PREBUILT_URL:-}" && "${RVDK_RELEASE_BASE%/}" == */rvdk-v1 ]]; then
                EXPECTED_BUNDLE_SHA="$(_ntfy_pinned_bundle_sha256 "$TARGET_SLUG" "$BUNDLE_NAME" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')"
            fi
            if [[ -z "$EXPECTED_BUNDLE_SHA" && "$ALLOW_REMOTE_SHA" != "true" && "$SKIP_BUNDLE_SHA" != "true" ]]; then
                if [[ -n "${NTFY_PREBUILT_URL:-}" ]]; then
                    log_fatal "Refusing to trust unpinned NTFY_PREBUILT_URL (${BUNDLE_URL}) without --bundle-sha256 <hex64>, --allow-remote-sha256, or --force-build."
                fi
                log_fatal "No pinned SHA-256 digest is recorded for ${BUNDLE_NAME} (${TARGET_SLUG}). Pass --bundle-sha256 <hex64>, --allow-remote-sha256, or --force-build."
            else
                if [[ -n "$EXPECTED_BUNDLE_SHA" ]] && [[ ! "$EXPECTED_BUNDLE_SHA" =~ ^[0-9a-f]{64}$ ]]; then
                    log_fatal "Invalid SHA-256 format '${EXPECTED_BUNDLE_SHA}' for ${BUNDLE_URL}."
                fi
                if [[ -z "$EXPECTED_BUNDLE_SHA" && "$ALLOW_REMOTE_SHA" == "true" && "$BUNDLE_URL" != https://* ]]; then
                    log_fatal "Refusing to fetch remote .sha256 sidecar over insecure non-HTTPS URL (${BUNDLE_URL}); use https:// or pass an explicit --bundle-sha256 <hex64> pin."
                fi
                rvdk_prog 32 "ntfy ${NTFY_VERSION}: pulling ${TARGET_SLUG} binary bundle..."
                log_info "Pulling precompiled ${TARGET_SLUG} bundle from ${BUNDLE_URL}..."
                _NTFY_TMP_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/rvdk-ntfy-bundle.XXXXXX")"
                if _ntfy_curl "$BUNDLE_URL" -fL --retry 3 -o "$_NTFY_TMP_ARCHIVE" 2>/dev/null; then
                    if [[ -z "$EXPECTED_BUNDLE_SHA" && "$ALLOW_REMOTE_SHA" == "true" ]]; then
                        if _ntfy_curl "${BUNDLE_URL}.sha256" -fsSL --retry 3 -o "${_NTFY_TMP_ARCHIVE}.sha256" 2>/dev/null; then
                            EXPECTED_BUNDLE_SHA="$(awk '{print tolower($1); exit}' "${_NTFY_TMP_ARCHIVE}.sha256")"
                        elif [[ "$SKIP_BUNDLE_SHA" != "true" ]]; then
                            rm -f "$_NTFY_TMP_ARCHIVE" "${_NTFY_TMP_ARCHIVE}.sha256"
                            _NTFY_TMP_ARCHIVE=""
                            log_fatal "Fail-closed security check: missing SHA-256 manifest at ${BUNDLE_URL}.sha256. Supply --bundle-sha256 <hex> or --force-build."
                        fi
                    fi
                    if [[ -z "$EXPECTED_BUNDLE_SHA" && "$SKIP_BUNDLE_SHA" != "true" ]]; then
                        rm -f "$_NTFY_TMP_ARCHIVE" "${_NTFY_TMP_ARCHIVE}.sha256"
                        _NTFY_TMP_ARCHIVE=""
                        log_fatal "Fail-closed security check: empty SHA-256 manifest at ${BUNDLE_URL}.sha256. Supply --bundle-sha256 <hex> or --force-build."
                    fi
                    if [[ -n "$EXPECTED_BUNDLE_SHA" ]]; then
                        [[ "$EXPECTED_BUNDLE_SHA" =~ ^[0-9a-f]{64}$ ]] || log_fatal "Invalid SHA-256 format '${EXPECTED_BUNDLE_SHA}' for ${BUNDLE_URL}."
                        ACTUAL_BUNDLE_SHA="$(rvdk_sha256_file "$_NTFY_TMP_ARCHIVE")"
                        if [[ "$ACTUAL_BUNDLE_SHA" != "$EXPECTED_BUNDLE_SHA" ]]; then
                            rm -f "$_NTFY_TMP_ARCHIVE" "${_NTFY_TMP_ARCHIVE}.sha256"
                            _NTFY_TMP_ARCHIVE=""
                            log_fatal "SHA-256 MISMATCH on ${BUNDLE_URL}! Expected ${EXPECTED_BUNDLE_SHA}, got ${ACTUAL_BUNDLE_SHA}."
                        fi
                        printf '%s  %s\n' "$ACTUAL_BUNDLE_SHA" "$BUNDLE_NAME" | rvdk_atomic_write "$LOCAL_BUNDLE_SHA" 0644
                        log_ok "Verified bundle SHA-256: ${ACTUAL_BUNDLE_SHA:0:16}..."
                    fi
                    mv -f "$_NTFY_TMP_ARCHIVE" "$LOCAL_BUNDLE"
                    rm -f "${_NTFY_TMP_ARCHIVE}.sha256" 2>/dev/null || true
                    _NTFY_TMP_ARCHIVE=""
                    chmod 0644 "$LOCAL_BUNDLE"
                else
                    rm -f "$_NTFY_TMP_ARCHIVE" "${_NTFY_TMP_ARCHIVE}.sha256"
                    _NTFY_TMP_ARCHIVE=""
                    if [[ -n "$EXPECTED_BUNDLE_SHA" || -n "${NTFY_PREBUILT_URL:-}" ]]; then
                        log_fatal "Failed to download prebuilt bundle from ${BUNDLE_URL} (pass --force-build to compile from source)."
                    fi
                    log_warn "No prebuilt bundle published at ${BUNDLE_URL}; falling back to unprivileged source compile (--force-build)..."
                    FORCE_BUILD="true"
                fi
            fi
        fi

        if [[ "$FORCE_BUILD" == "false" && "$NTFY_ENABLE_WEB" == "true" ]]; then
            _CHECK_INFO="$(tar -I zstd -xOf "$LOCAL_BUNDLE" ./BUILD_INFO.env 2>/dev/null || tar -I zstd -xOf "$LOCAL_BUNDLE" BUILD_INFO.env 2>/dev/null || true)"
            if [[ "$_CHECK_INFO" != *'NTFY_WEB_EMBEDDED="true"'* ]]; then
                log_warn "Prebuilt bundle ${BUNDLE_NAME} was compiled headless; recompiling from source to embed --with-web UI..."
                FORCE_BUILD="true"
            fi
        fi
    fi

    if [[ "$FORCE_BUILD" == "true" ]]; then
        _NTFY_BUILD_ACTIVE="true"
        rvdk_prog 38 "ntfy ${NTFY_VERSION}: installing cold-compile prerequisites (${TARGET_SLUG})..."
        log_info "Executing unprivileged source build (--force-build) for ntfy ${NTFY_VERSION} (${TARGET_SLUG})..."

        BUILD_PKGS=(git build-essential jq)
        if [[ "$NTFY_ENABLE_WEB" == "true" ]] && ! command -v npm >/dev/null 2>&1; then
            BUILD_PKGS+=(nodejs npm)
        fi
        rvdk_apt_ensure "${BUILD_PKGS[@]}"

        BUILD_USER="_apt"
        if ! id -u "$BUILD_USER" >/dev/null 2>&1; then
            BUILD_USER="nobody"
        fi
        BUILD_GRP="$(id -gn "$BUILD_USER" 2>/dev/null || echo "nogroup")"

        MOD_CACHE_DIR="${RVDK_CACHE_DIR:-/var/cache/rvdk}/go/pkg/mod"
        rm -rf "$BUILD_DIR"
        mkdir -p "${BUILD_DIR}/src" "${BUILD_DIR}/stage/usr/bin" "${BUILD_DIR}/stage/etc/systemd/system" "${BUILD_DIR}/stage/etc/ntfy" \
            "${BUILD_DIR}/gocache" "${BUILD_DIR}/gopath" "${BUILD_DIR}/home" "${BUILD_DIR}/npm-cache" "$MOD_CACHE_DIR"
        chmod 0755 /var/lib/rvdk "$NTFY_LIB_ROOT" "${RVDK_CACHE_DIR:-/var/cache/rvdk}" "${RVDK_CACHE_DIR:-/var/cache/rvdk}/go" 2>/dev/null || true
        chown -R "${BUILD_USER}:${BUILD_GRP}" "$BUILD_DIR" "$MOD_CACHE_DIR"

        rvdk_prog 45 "ntfy ${NTFY_VERSION}: cloning binwiederhier/ntfy tag v${NTFY_VERSION} as ${BUILD_USER}..."
        run_as_user "$BUILD_USER" env HOME="${BUILD_DIR}/home" \
            git clone --depth 1 --branch "v${NTFY_VERSION}" https://github.com/binwiederhier/ntfy.git "${BUILD_DIR}/src" -q

        REQ_GO_VER="$(awk '/^go [0-9]+\.[0-9]+/ {print $2; exit}' "${BUILD_DIR}/src/go.mod" 2>/dev/null || echo "1.26")"
        rvdk_prog 52 "ntfy ${NTFY_VERSION}: provisioning Go >= ${REQ_GO_VER} toolchain..."
        GO_BIN="$(ensure_go_toolchain "$REQ_GO_VER")"
        GO_BIN_DIR="$(dirname "$GO_BIN")"

        rvdk_kit_probe_cflags gcc
        OPT_FLAGS="$RVDK_OPT_CFLAGS"
        rvdk_kit_probe_goriscv64 "$GO_BIN"
        SELECTED_GORISCV64="$RVDK_SELECTED_GORISCV64"
        log_info "Selected silicon build profile: CGO_CFLAGS='${OPT_FLAGS}'${SELECTED_GORISCV64:+ GORISCV64=${SELECTED_GORISCV64}}"

        run_as_user "$BUILD_USER" mkdir -p "${BUILD_DIR}/src/server/docs" "${BUILD_DIR}/src/server/site"
        run_as_user "$BUILD_USER" touch "${BUILD_DIR}/src/server/docs/index.html" "${BUILD_DIR}/src/server/site/app.html"

        WEB_BUILT="false"
        if [[ "$NTFY_ENABLE_WEB" == "true" ]]; then
            rvdk_prog 58 "ntfy ${NTFY_VERSION}: building embedded React web UI as ${BUILD_USER}..."
            run_as_user "$BUILD_USER" env \
                HOME="${BUILD_DIR}/home" \
                NPM_CONFIG_CACHE="${BUILD_DIR}/npm-cache" \
                PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
                bash -Eeuo pipefail -c '
                    cd "$1/src/web"
                    npm ci --ignore-scripts
                    npm run build
                    mv -f build/index.html build/app.html
                    rm -f build/config.js
                    rm -rf ../server/site
                    mv build ../server/site
                ' _ "$BUILD_DIR"
            WEB_BUILT="true"
        fi

        GIT_COMMIT="$(run_as_user "$BUILD_USER" git -C "${BUILD_DIR}/src" rev-parse --short=7 HEAD)"
        BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        STAGE_ROOT="${BUILD_DIR}/stage"

        rvdk_prog 64 "ntfy ${NTFY_VERSION}: compiling server & CLI (${TARGET_SLUG}) as ${BUILD_USER}..."
        BASE_LDFLAGS="-s -w -X main.version=${NTFY_VERSION} -X main.commit=${GIT_COMMIT} -X main.date=${BUILD_DATE}"
        STATIC_LDFLAGS="-linkmode=external -extldflags=-static ${BASE_LDFLAGS}"
        BUILD_TAGS="sqlite_omit_load_extension,osusergo,netgo"

        if ! run_as_user "$BUILD_USER" env \
            HOME="${BUILD_DIR}/home" \
            PATH="${GO_BIN_DIR}:${PATH}" \
            GOPATH="${BUILD_DIR}/gopath" \
            GOMODCACHE="$MOD_CACHE_DIR" \
            GOCACHE="${BUILD_DIR}/gocache" \
            GOTOOLCHAIN="local" \
            CGO_ENABLED=1 \
            CGO_CFLAGS="$OPT_FLAGS" \
            ${SELECTED_GORISCV64:+GORISCV64="$SELECTED_GORISCV64"} \
            "$GO_BIN" build -C "${BUILD_DIR}/src" -trimpath -tags "$BUILD_TAGS" -ldflags "$STATIC_LDFLAGS" -o "${STAGE_ROOT}/usr/bin/ntfy" . 2>/dev/null; then
            log_warn "Static glibc link unavailable; linking dynamically with system libc..."
            run_as_user "$BUILD_USER" env \
                HOME="${BUILD_DIR}/home" \
                PATH="${GO_BIN_DIR}:${PATH}" \
                GOPATH="${BUILD_DIR}/gopath" \
                GOMODCACHE="$MOD_CACHE_DIR" \
                GOCACHE="${BUILD_DIR}/gocache" \
                GOTOOLCHAIN="local" \
                CGO_ENABLED=1 \
                CGO_CFLAGS="$OPT_FLAGS" \
                ${SELECTED_GORISCV64:+GORISCV64="$SELECTED_GORISCV64"} \
                "$GO_BIN" build -C "${BUILD_DIR}/src" -trimpath -tags "$BUILD_TAGS" -ldflags "$BASE_LDFLAGS" -o "${STAGE_ROOT}/usr/bin/ntfy" .
        fi

        _NTFY_TMP_PKG="$(mktemp -d)"
        chmod 0755 "$_NTFY_TMP_PKG"
        _ntfy_stage_built_binary "$STAGE_ROOT" "${_NTFY_TMP_PKG}/usr/bin/ntfy"
        "${_NTFY_TMP_PKG}/usr/bin/ntfy" --version >/dev/null

        install -d -m 0755 -o root -g root "${_NTFY_TMP_PKG}/etc/systemd/system" "${_NTFY_TMP_PKG}/etc/ntfy"
        for _src_dir in "${BUILD_DIR}/src" "${BUILD_DIR}/src/server" "${BUILD_DIR}/src/client"; do
            if [[ -L "$_src_dir" ]]; then
                log_fatal "Refusing symlinked source directory in ntfy build workspace: ${_src_dir}"
            fi
        done
        if [[ -L "${BUILD_DIR}/src/server/ntfy.service" ]]; then
            log_fatal "Refusing symlinked unit file in ntfy build workspace: ${BUILD_DIR}/src/server/ntfy.service"
        fi
        if [[ -L "${BUILD_DIR}/src/server/server.yml" ]]; then
            log_fatal "Refusing symlinked config file in ntfy build workspace: ${BUILD_DIR}/src/server/server.yml"
        fi
        if [[ -L "${BUILD_DIR}/src/client/client.yml" ]]; then
            log_fatal "Refusing symlinked config file in ntfy build workspace: ${BUILD_DIR}/src/client/client.yml"
        fi
        if [[ -f "${BUILD_DIR}/src/server/ntfy.service" ]]; then
            install -m 0644 -o root -g root "${BUILD_DIR}/src/server/ntfy.service" "${_NTFY_TMP_PKG}/etc/systemd/system/ntfy.service"
        fi
        if [[ -f "${BUILD_DIR}/src/server/server.yml" ]]; then
            install -m 0644 -o root -g root "${BUILD_DIR}/src/server/server.yml" "${_NTFY_TMP_PKG}/etc/ntfy/server.yml.dist"
        fi
        if [[ -f "${BUILD_DIR}/src/client/client.yml" ]]; then
            install -m 0644 -o root -g root "${BUILD_DIR}/src/client/client.yml" "${_NTFY_TMP_PKG}/etc/ntfy/client.yml"
        fi

        rvdk_kv_write "${_NTFY_TMP_PKG}/BUILD_INFO.env" 0644 "Managed by RVDK (mods/ntfy/forge.sh)" \
            "NTFY_VERSION=${NTFY_VERSION}" \
            "NTFY_COMMIT=${GIT_COMMIT}" \
            "TARGET_SLUG=${TARGET_SLUG}" \
            "GORISCV64=${SELECTED_GORISCV64}" \
            "CGO_CFLAGS=${OPT_FLAGS}" \
            "NTFY_WEB_EMBEDDED=${WEB_BUILT}" \
            "BUILT_AT=${BUILD_DATE}"

        rvdk_prog 72 "ntfy ${NTFY_VERSION}: packaging RVDK catalog bundle (${BUNDLE_NAME})..."
        tar -I 'zstd -9 -T0' -cf "$LOCAL_BUNDLE" -C "$_NTFY_TMP_PKG" .
        rm -rf "$_NTFY_TMP_PKG"
        _NTFY_TMP_PKG=""
        BUILT_SHA="$(rvdk_sha256_file "$LOCAL_BUNDLE")"
        printf '%s  %s\n' "$BUILT_SHA" "$BUNDLE_NAME" | rvdk_atomic_write "$LOCAL_BUNDLE_SHA" 0644
        chmod 0644 "$LOCAL_BUNDLE"
        log_ok "Packaged RVDK catalog bundle: ${LOCAL_BUNDLE} (SHA-256: ${BUILT_SHA:0:16}...)"

        [[ "$KEEP_BUILD_DIR" != "true" ]] && rm -rf "$BUILD_DIR"
        _NTFY_BUILD_ACTIVE="false"
    fi

    rvdk_prog 78 "ntfy ${NTFY_VERSION}: installing binary & systemd unit from verified bundle..."
    _NTFY_TMP_EXTRACT="$(mktemp -d)"
    tar --no-same-owner --no-same-permissions -I zstd -xf "$LOCAL_BUNDLE" -C "$_NTFY_TMP_EXTRACT"
    if [[ -n "$(find "$_NTFY_TMP_EXTRACT" -type l -print -quit)" ]]; then
        log_fatal "Refusing ntfy bundle containing symbolic links inside ${LOCAL_BUNDLE}."
    fi
    [[ -f "${_NTFY_TMP_EXTRACT}/usr/bin/ntfy" && ! -L "${_NTFY_TMP_EXTRACT}/usr/bin/ntfy" ]] || log_fatal "Invalid or symlinked ntfy bundle layout inside ${LOCAL_BUNDLE} (missing or non-regular usr/bin/ntfy)."

    install -d -m 0755 /usr/bin /etc/systemd/system /etc/ntfy
    _ntfy_stage_built_binary "$_NTFY_TMP_EXTRACT" /usr/bin/ntfy

    if [[ -f "${_NTFY_TMP_EXTRACT}/etc/systemd/system/ntfy.service" && ! -L "${_NTFY_TMP_EXTRACT}/etc/systemd/system/ntfy.service" ]]; then
        install -m 0644 -o root -g root "${_NTFY_TMP_EXTRACT}/etc/systemd/system/ntfy.service" /etc/systemd/system/ntfy.service
    elif [[ -f "${_NTFY_TMP_EXTRACT}/lib/systemd/system/ntfy.service" && ! -L "${_NTFY_TMP_EXTRACT}/lib/systemd/system/ntfy.service" ]]; then
        install -m 0644 -o root -g root "${_NTFY_TMP_EXTRACT}/lib/systemd/system/ntfy.service" /etc/systemd/system/ntfy.service
    else
        rvdk_atomic_write /etc/systemd/system/ntfy.service 0644 <<'EOF'
[Unit]
Description=ntfy server
After=network.target

[Service]
User=ntfy
Group=ntfy
RuntimeDirectory=ntfy
RuntimeDirectoryMode=0750
ExecStart=/usr/bin/ntfy serve --no-log-dates
ExecReload=/bin/kill --signal HUP $MAINPID
Restart=on-failure
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65536
PrivateDevices=true
ProtectClock=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
RestrictRealtime=true
ProtectHostname=true

[Install]
WantedBy=multi-user.target
EOF
    fi

    if [[ -f "${_NTFY_TMP_EXTRACT}/etc/ntfy/server.yml.dist" && ! -L "${_NTFY_TMP_EXTRACT}/etc/ntfy/server.yml.dist" ]]; then
        install -m 0644 -o root -g root "${_NTFY_TMP_EXTRACT}/etc/ntfy/server.yml.dist" /etc/ntfy/server.yml.dist
    fi
    if [[ -f "${_NTFY_TMP_EXTRACT}/etc/ntfy/client.yml" && ! -L "${_NTFY_TMP_EXTRACT}/etc/ntfy/client.yml" && ! -f /etc/ntfy/client.yml ]]; then
        install -m 0644 -o root -g root "${_NTFY_TMP_EXTRACT}/etc/ntfy/client.yml" /etc/ntfy/client.yml
    fi

    BUNDLE_WEB_EMBEDDED="false"
    if [[ -r "${_NTFY_TMP_EXTRACT}/BUILD_INFO.env" && ! -L "${_NTFY_TMP_EXTRACT}/BUILD_INFO.env" ]]; then
        NTFY_WEB_EMBEDDED=""
        rvdk_kv_load "${_NTFY_TMP_EXTRACT}/BUILD_INFO.env" NTFY_WEB_EMBEDDED
        BUNDLE_WEB_EMBEDDED="${NTFY_WEB_EMBEDDED:-false}"
    fi
    rvdk_kv_write "$INSTALLED_STAMP" 0644 "Managed by RVDK (mods/ntfy/forge.sh)" \
        "NTFY_VERSION=${NTFY_VERSION}" \
        "TARGET_SLUG=${TARGET_SLUG}" \
        "NTFY_STAMP_WEB=${BUNDLE_WEB_EMBEDDED}"

    rm -rf "$_NTFY_TMP_EXTRACT"
    _NTFY_TMP_EXTRACT=""
    systemctl daemon-reload
    BINARIES_CHANGED="true"
    log_ok "Installed ntfy ${NTFY_VERSION} (${TARGET_SLUG}) -> /usr/bin/ntfy"
fi

# 3. System Account, Group Membership, Persistence Directory & Systemd Runtime Drop-In
rvdk_prog 84 "ntfy ${NTFY_VERSION}: staging system user, SQLite WAL storage & runtime socket..."
if ! getent group ntfy >/dev/null 2>&1; then
    groupadd --system ntfy
fi
if ! id -u ntfy >/dev/null 2>&1; then
    NOLOGIN_SHELL="/usr/sbin/nologin"
    [[ ! -x "$NOLOGIN_SHELL" && -x /sbin/nologin ]] && NOLOGIN_SHELL="/sbin/nologin"
    [[ ! -x "$NOLOGIN_SHELL" ]] && NOLOGIN_SHELL="/bin/false"
    useradd --system --gid ntfy --home-dir /var/lib/ntfy --no-create-home --shell "$NOLOGIN_SHELL" ntfy
fi

if [[ -n "${REAL_USER:-}" && "$REAL_USER" != "root" ]] && id -u "$REAL_USER" >/dev/null 2>&1; then
    if ! id -nG "$REAL_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "ntfy"; then
        usermod -aG ntfy "$REAL_USER" 2>/dev/null || true
    fi
fi

if [[ -n "$DATA_MOUNT" ]] && mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    NTFY_DATA="${DATA_MOUNT}/ntfy"
else
    NTFY_DATA="/var/lib/ntfy"
fi

install -d -m 0755 /etc/ntfy
install -d -m 0750 -o ntfy -g ntfy "$NTFY_DATA" "${NTFY_DATA}/attachments"
install -d -m 0750 -o ntfy -g ntfy /run/ntfy

NTFY_DROPIN_DIR="/etc/systemd/system/ntfy.service.d"
NTFY_DROPIN_FILE="${NTFY_DROPIN_DIR}/90-rvdk-runtime.conf"
WANT_DROPIN="# Managed by RVDK (mods/ntfy/forge.sh)
[Service]
User=ntfy
Group=ntfy
RuntimeDirectory=ntfy
RuntimeDirectoryMode=0750
LimitNOFILE=65536"

DROPIN_CHANGED="false"
install -d -m 0755 "$NTFY_DROPIN_DIR"
if ! printf '%s\n' "$WANT_DROPIN" | cmp -s - "$NTFY_DROPIN_FILE" 2>/dev/null; then
    printf '%s\n' "$WANT_DROPIN" | rvdk_atomic_write "$NTFY_DROPIN_FILE" 0644
    systemctl daemon-reload
    DROPIN_CHANGED="true"
fi

# 4. Converge /etc/ntfy/server.yml & Declarative Auth User
if [[ "$NTFY_BIND" == *:* && "$NTFY_BIND" != \[*\] ]]; then
    LISTEN_HTTP_ADDR="[${NTFY_BIND}]:${NTFY_PORT}"
    DEFAULT_URL_HOST="[${NTFY_BIND}]"
else
    LISTEN_HTTP_ADDR="${NTFY_BIND}:${NTFY_PORT}"
    DEFAULT_URL_HOST="$NTFY_BIND"
fi

if [[ "$DEFAULT_URL_HOST" == "0.0.0.0" || "$DEFAULT_URL_HOST" == "[::]" ]]; then
    DETECTED_IP=""
    if command -v ip >/dev/null 2>&1; then
        PRIMARY_NIC="${RVDK_PRIMARY_NIC:-$(ip -o -4 route show to default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)}"
        if [[ -n "$PRIMARY_NIC" ]]; then
            DETECTED_IP="$(ip -o -4 addr show dev "$PRIMARY_NIC" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)"
        fi
    fi
    DEFAULT_URL_HOST="${DETECTED_IP:-127.0.0.1}"
fi
EFFECTIVE_BASE_URL="${NTFY_BASE_URL:-http://${DEFAULT_URL_HOST}:${NTFY_PORT}}"

UNIX_SOCK_MODE="0660"
if [[ -n "$NTFY_USER" ]]; then
    AUTH_DEFAULT_ACCESS="deny-all"
else
    AUTH_DEFAULT_ACCESS="read-write"
fi

if [[ "$NTFY_ENABLE_WEB" == "true" ]]; then
    WEB_ROOT_VAL="/"
else
    WEB_ROOT_VAL="disable"
fi

if [[ -n "$NTFY_DATABASE_URL" ]]; then
    STORAGE_YAML="database-url: \"${NTFY_DATABASE_URL}\"
cache-duration: \"${NTFY_CACHE_DURATION}\"
auth-default-access: \"${AUTH_DEFAULT_ACCESS}\""
else
    STORAGE_YAML="cache-file: \"${NTFY_DATA}/cache.db\"
cache-duration: \"${NTFY_CACHE_DURATION}\"
cache-startup-queries: |
  pragma journal_mode = WAL;
  pragma synchronous = normal;
  pragma temp_store = memory;
  pragma busy_timeout = 15000;
auth-file: \"${NTFY_DATA}/user.db\"
auth-default-access: \"${AUTH_DEFAULT_ACCESS}\"
auth-startup-queries: |
  pragma journal_mode = WAL;
  pragma synchronous = normal;
  pragma temp_store = memory;
  pragma busy_timeout = 15000;"
fi

UPSTREAM_YAML=""
if [[ -n "$NTFY_UPSTREAM_BASE_URL" ]]; then
    UPSTREAM_YAML=$'\n'"upstream-base-url: \"${NTFY_UPSTREAM_BASE_URL}\""
fi

NTFY_CONF="/etc/ntfy/server.yml"
WANT_NTFY_CONF="# DREW-V Labs // RVDK ntfy Notification Broker (mods/ntfy/forge.sh)
base-url: \"${EFFECTIVE_BASE_URL}\"
listen-http: \"${LISTEN_HTTP_ADDR}\"
listen-unix: \"/run/ntfy/ntfy.sock\"
listen-unix-mode: ${UNIX_SOCK_MODE}

${STORAGE_YAML}

attachment-cache-dir: \"${NTFY_DATA}/attachments\"
behind-proxy: ${NTFY_BEHIND_PROXY}
web-root: \"${WEB_ROOT_VAL}\"${UPSTREAM_YAML}
"

CONF_CHANGED="false"
if ! printf '%s' "$WANT_NTFY_CONF" | cmp -s - "$NTFY_CONF" 2>/dev/null; then
    printf '%s' "$WANT_NTFY_CONF" | rvdk_atomic_write "$NTFY_CONF" 0640 root:ntfy
    CONF_CHANGED="true"
fi

AUTH_CHANGED="false"
AUTH_KEY_FILE="/etc/ntfy/.rvdk-auth.key"
AUTH_STAMP="/etc/ntfy/.rvdk-auth.sha256"
if [[ -n "$NTFY_USER" ]]; then
    if [[ ! -s "$AUTH_KEY_FILE" ]]; then
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | rvdk_atomic_write "$AUTH_KEY_FILE" 0600 root:root
    else
        chmod 0600 "$AUTH_KEY_FILE" 2>/dev/null || true
    fi

    WANT_AUTH_DIGEST="$(
        _RVDK_NTFY_PW="$NTFY_PASSWORD" python3 - "$AUTH_KEY_FILE" "$NTFY_USER" "$NTFY_ROLE" <<'PY'
import hashlib, hmac, os, sys

key_path, user, role = sys.argv[1], sys.argv[2], sys.argv[3]
pw = os.environ["_RVDK_NTFY_PW"]
with open(key_path, "rb") as fh:
    key = fh.read().rstrip(b"\n")
msg = f"{user}:{role}:{pw}".encode("utf-8")
print(hmac.new(key, msg, hashlib.sha256).hexdigest())
PY
    )"
    HAVE_AUTH_DIGEST=""
    [[ -r "$AUTH_STAMP" ]] && HAVE_AUTH_DIGEST="$(awk '{print tolower($1); exit}' "$AUTH_STAMP" 2>/dev/null || true)"
    HAVE_AUTH_DB="true"
    [[ -z "$NTFY_DATABASE_URL" && ! -f "${NTFY_DATA}/user.db" ]] && HAVE_AUTH_DB="false"

    if [[ "$WANT_AUTH_DIGEST" != "$HAVE_AUTH_DIGEST" || "$HAVE_AUTH_DB" == "false" ]]; then
        rvdk_prog 90 "ntfy ${NTFY_VERSION}: provisioning authenticated user '${NTFY_USER}' (${NTFY_ROLE}) as ntfy..."
        if [[ -z "$NTFY_DATABASE_URL" ]]; then
            chown ntfy:ntfy "${NTFY_DATA}"/user.db* 2>/dev/null || true
        fi
        run_ntfy_as_user \
            user add --config="$NTFY_CONF" --ignore-exists --role="$NTFY_ROLE" "$NTFY_USER" >/dev/null
        run_ntfy_as_user \
            user change-pass --config="$NTFY_CONF" "$NTFY_USER" >/dev/null
        run_as_user ntfy \
            /usr/bin/ntfy user change-role --config="$NTFY_CONF" "$NTFY_USER" "$NTFY_ROLE" >/dev/null
        if [[ -z "$NTFY_DATABASE_URL" && -f "${NTFY_DATA}/user.db" ]]; then
            chmod 0640 "${NTFY_DATA}/user.db" 2>/dev/null || true
        fi
        printf '%s\n' "$WANT_AUTH_DIGEST" | rvdk_atomic_write "$AUTH_STAMP" 0600 root:root
        AUTH_CHANGED="true"
    fi
fi

# 5. Zero-Disruption Daemon Activation & Socket Verification
rvdk_prog 94 "ntfy ${NTFY_VERSION}: converging listener ${LISTEN_HTTP_ADDR} + /run/ntfy/ntfy.sock..."
systemctl enable ntfy.service >/dev/null 2>&1 || true

SERVICE_STARTED="false"
if ! systemctl is-active --quiet ntfy.service; then
    systemctl start ntfy.service
    SERVICE_STARTED="true"
elif [[ "$BINARIES_CHANGED" == "true" || "$DROPIN_CHANGED" == "true" || "$CONF_CHANGED" == "true" || "$AUTH_CHANGED" == "true" ]]; then
    systemctl restart ntfy.service
    SERVICE_STARTED="true"
fi

for (( w=0; w<15; w++ )); do
    [[ -S /run/ntfy/ntfy.sock ]] && systemctl is-active --quiet ntfy.service && break
    sleep 0.4
done

if ! systemctl is-active --quiet ntfy.service; then
    journalctl -u ntfy.service -n 25 --no-pager >&2 || true
    log_fatal "ntfy.service failed to become active"
fi

if [[ "$SERVICE_STARTED" == "true" ]]; then
    log_ok "Converged ntfy ${NTFY_VERSION} on ${LISTEN_HTTP_ADDR} & /run/ntfy/ntfy.sock (Storage: ${NTFY_DATA})"
else
    log_skip "ntfy ${NTFY_VERSION} already converged on ${LISTEN_HTTP_ADDR} (${NTFY_CONF})"
fi

rvdk_prog 100 "ntfy ${NTFY_VERSION} broker converged (${LISTEN_HTTP_ADDR})"
