#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: ntfy HTTP & Unix Socket Pub/Sub Broker (riscv64)
# Path: riscv-data-kit/mods/ntfy/forge.sh
#
# Security, Supply-Chain & Persistence Hardening:
#   • SHA-256 verifies precompiled RVDK catalog binary bundles (.tar.zst) by default
#   • Automatically falls back to (or forces via --force-build) a cold source compile
#     using SHA-256 verified go.dev/dl toolchains + silicon -march/-mtune & GORISCV64,
#     emitting a ready-to-upload RVDK catalog bundle in /var/lib/rvdk/ntfy-riscv64/bundles
#   • Binds HTTP listener to `127.0.0.1:2586` + `/run/ntfy/ntfy.sock` by default
#   • Non-loopback `--bind` requires `--ntfy-user` + `--ntfy-password` OR explicit `--allow-anonymous`
#   • Configures SQLite WAL mode on NVMe (`${DATA_MOUNT}/ntfy`) or `/var/lib/ntfy`
#   • Zero-disruption idempotency (0 restarts and 0 apt updates when already converged)
# ==============================================================================
set -Eeuo pipefail

ORIG_ARGS=("$@")
export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"

# @RVDK_INLINE_LIBS: common apt progbar
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${_REPO_ROOT}/lib/common.sh"
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/apt.sh" ]]; then
    # shellcheck source=lib/apt.sh
    source "${_REPO_ROOT}/lib/apt.sh"
fi
if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]]; then
    # shellcheck source=lib/progbar.sh
    source "${_REPO_ROOT}/lib/progbar.sh"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_log_init "RVDK:NTFY"
rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
rvdk_sanitize_locale
rvdk_resolve_caller

rvdk_load_config_env \
    MOUNT_POINT NTFY_VERSION NTFY_PORT NTFY_BIND NTFY_BASE_URL NTFY_UPSTREAM_BASE_URL \
    NTFY_ALLOW_ANONYMOUS NTFY_USER NTFY_PASSWORD NTFY_ROLE NTFY_CACHE_DURATION \
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
NTFY_ROLE="${NTFY_ROLE:-admin}"
NTFY_CACHE_DURATION="${NTFY_CACHE_DURATION:-12h}"
NTFY_BEHIND_PROXY="${NTFY_BEHIND_PROXY:-false}"
NTFY_ENABLE_WEB="${NTFY_ENABLE_WEB:-false}"
NTFY_DATABASE_URL="${NTFY_DATABASE_URL:-}"

FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
SKIP_BUNDLE_SHA="false"
BUNDLE_SHA256="${NTFY_PREBUILT_SHA256:-}"
RVDK_RELEASE_BASE="${RVDK_RELEASE_BASE:-https://github.com/drewv-labs/riscv-data-kit/releases/download/rvdk-v1}"
CLI_SOC=""
CLI_BOARD=""

if [[ -z "${MOUNT_POINT:-}" ]]; then
    if mountpoint -q /mnt/nvme_data 2>/dev/null; then
        DATA_MOUNT="/mnt/nvme_data"
    else
        DATA_MOUNT="/mnt/nvme_pgdata"
    fi
else
    DATA_MOUNT="$MOUNT_POINT"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            NTFY_VERSION="${2:-2.38.1}"
            NTFY_VERSION="${NTFY_VERSION#v}"
            shift 2 ;;
        --port)
            NTFY_PORT="${2:-2586}"; shift 2 ;;
        --bind)
            NTFY_BIND="${2:-127.0.0.1}"; shift 2 ;;
        --base-url)
            NTFY_BASE_URL="${2:-}"; shift 2 ;;
        --upstream-base-url|--upstream)
            NTFY_UPSTREAM_BASE_URL="${2:-}"; shift 2 ;;
        --allow-anonymous)
            NTFY_ALLOW_ANONYMOUS="true"; shift ;;
        --ntfy-user)
            NTFY_USER="${2:-}"; shift 2 ;;
        --ntfy-password)
            NTFY_PASSWORD="${2:-}"; shift 2 ;;
        --ntfy-role)
            NTFY_ROLE="${2:-admin}"; shift 2 ;;
        --cache-duration)
            NTFY_CACHE_DURATION="${2:-12h}"; shift 2 ;;
        --behind-proxy)
            NTFY_BEHIND_PROXY="true"; shift ;;
        --with-web|--enable-web)
            NTFY_ENABLE_WEB="true"; shift ;;
        --database-url)
            NTFY_DATABASE_URL="${2:-}"; shift 2 ;;
        --data-mount)
            DATA_MOUNT="${2:-/mnt/nvme_data}"; shift 2 ;;
        --force-build|--force-rebuild-ntfy|--compile)
            FORCE_BUILD="true"; shift ;;
        --keep-build-dir)
            KEEP_BUILD_DIR="true"; shift ;;
        --bundle-sha256)
            BUNDLE_SHA256="${2:-}"; shift 2 ;;
        --insecure-skip-sha256)
            SKIP_BUNDLE_SHA="true"; shift ;;
        --soc)
            CLI_SOC="${2:-}"; shift 2 ;;
        --board)
            CLI_BOARD="${2:-}"; shift 2 ;;
        --no-apt-update|--skip-apt-update)
            export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)
            export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)
            cat <<EOF
Usage: sudo rvdk mods/ntfy [options]

Options:
  --bind <ip>                 HTTP TCP bind address (default: 127.0.0.1)
  --port <port>               HTTP TCP port (default: 2586)
  --base-url <url>            Public/LAN base URL (default: http://<bind-or-ip>:<port>)
  --upstream-base-url <url>   Optional iOS APNS wakeup relay (e.g. https://ntfy.sh)
  --ntfy-user <user>          Provision user in ntfy auth DB & enforce deny-all default ACL
  --ntfy-password <pass>      Password for --ntfy-user (or pass via NTFY_PASSWORD env)
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
  --soc <vendor/soc>          Explicit SoC target override
  --board <vendor/board>      Explicit board target override
EOF
            exit 0
            ;;
        *) shift ;;
    esac
done

[[ "$NTFY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?$ ]] || log_fatal "Invalid --version '${NTFY_VERSION}'."
[[ "$NTFY_PORT" =~ ^[0-9]+$ ]] && (( NTFY_PORT >= 1 && NTFY_PORT <= 65535 )) || log_fatal "Invalid --port '${NTFY_PORT}'."
[[ "$NTFY_BIND" =~ ^[A-Za-z0-9.:_-]+$ ]] || log_fatal "Invalid --bind address '${NTFY_BIND}'."
[[ "$NTFY_CACHE_DURATION" =~ ^[0-9]+(ms|s|m|h|d)$ ]] || log_fatal "Invalid --cache-duration '${NTFY_CACHE_DURATION}'."

case "$NTFY_ROLE" in
    admin|user) ;;
    *) log_fatal "Invalid --ntfy-role '${NTFY_ROLE}' (expected: admin | user)." ;;
esac

case "$NTFY_BEHIND_PROXY" in
    true|1|yes)  NTFY_BEHIND_PROXY="true" ;;
    false|0|no|"") NTFY_BEHIND_PROXY="false" ;;
    *) log_fatal "Invalid NTFY_BEHIND_PROXY '${NTFY_BEHIND_PROXY}' (expected: true | false)." ;;
esac

case "$NTFY_ENABLE_WEB" in
    true|1|yes)  NTFY_ENABLE_WEB="true" ;;
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
    [[ -n "$NTFY_USER" && -n "$NTFY_PASSWORD" ]] || log_fatal "Both --ntfy-user and --ntfy-password (or NTFY_PASSWORD) must be provided together."
    [[ "$NTFY_USER" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --ntfy-user '${NTFY_USER}'."
fi

if [[ "$IS_LOOPBACK" == "false" && -z "$NTFY_USER" && "$NTFY_ALLOW_ANONYMOUS" != "true" ]]; then
    log_fatal "Refusing to expose unauthenticated ntfy broker on '${NTFY_BIND}:${NTFY_PORT}'. Pass --ntfy-user/--ntfy-password or explicit --allow-anonymous."
fi

if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/kit.sh" ]]; then
    # shellcheck disable=SC1091
    source "${_REPO_ROOT}/lib/kit.sh"
    _KIT_ARGS=()
    [[ -n "$CLI_SOC" ]] && _KIT_ARGS+=("--soc" "$CLI_SOC")
    [[ -n "$CLI_BOARD" ]] && _KIT_ARGS+=("--board" "$CLI_BOARD")
    rvdk_kit_resolve ${_KIT_ARGS[@]+"${_KIT_ARGS[@]}"}
fi

_NTFY_TMP_ARCHIVE=""
_NTFY_TMP_EXTRACT=""
_NTFY_TMP_GO_TGZ=""
_NTFY_BUILD_ACTIVE="false"
NTFY_LIB_ROOT="/var/lib/rvdk/ntfy-riscv64"
BUNDLE_DIR="${NTFY_LIB_ROOT}/bundles"
BUILD_DIR="${NTFY_LIB_ROOT}/build"
INSTALLED_STAMP="${NTFY_LIB_ROOT}/installed.env"

_rvdk_ntfy_cleanup() {
    [[ -n "$_NTFY_TMP_ARCHIVE" ]] && rm -f "$_NTFY_TMP_ARCHIVE" "${_NTFY_TMP_ARCHIVE}.sha256" 2>/dev/null || true
    [[ -n "$_NTFY_TMP_GO_TGZ" ]] && rm -f "$_NTFY_TMP_GO_TGZ" 2>/dev/null || true
    [[ -n "$_NTFY_TMP_EXTRACT" && -d "$_NTFY_TMP_EXTRACT" ]] && rm -rf "$_NTFY_TMP_EXTRACT" 2>/dev/null || true
    if [[ "$_NTFY_BUILD_ACTIVE" == "true" && "$KEEP_BUILD_DIR" != "true" && -d "$BUILD_DIR" ]]; then
        rm -rf "$BUILD_DIR" 2>/dev/null || true
    fi
}
trap '_rvdk_ntfy_cleanup' EXIT INT TERM

rvdk_prog_init "ntfy ${NTFY_VERSION}: detecting RISC-V silicon profile..."

# 1. Resolve Silicon Target, CGO Compiler Flags & Go RVA Profile
UNAME_M="$(uname -m)"
case "$UNAME_M" in
    riscv64)       GO_HOST_ARCH="riscv64" ;;
    x86_64|amd64)  GO_HOST_ARCH="amd64" ;;
    aarch64|arm64) GO_HOST_ARCH="arm64" ;;
    *)             log_fatal "Unsupported CPU architecture for ntfy: ${UNAME_M}" ;;
esac

DT_MODEL="${RVDK_DT_MODEL:-$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "unknown")}"
RESOLVED_SOC="${RVDK_SOC:-$CLI_SOC}"
if [[ -z "$RESOLVED_SOC" ]]; then
    case "$DT_MODEL" in
        *"Premier P550"*|*"Megrez"*|*"StarPro64"*|*"EIC7700"*) RESOLVED_SOC="eswin/eic7700x" ;;
        *"Unmatched"*|*"FU740"*)                               RESOLVED_SOC="sifive/fu740" ;;
        *"VisionFive 2"*|*"VF2"*|*"Mars"*|*"OrangePi RV"*|*"Orange Pi RV"*|*"JH7110"*) RESOLVED_SOC="starfive/jh7110" ;;
        *"AIBOX-K3"*|*"Jupiter 2"*|*"SpacemiT K3"*|*"K3"*)     RESOLVED_SOC="spacemit/k3" ;;
        *"OrangePi"*|*"Orange Pi"*|*"BPI-F3"*|*"BPI-CM6"*|*"Jupiter"*|*"SpacemiT"*|*"K1"*|*"M1"*) RESOLVED_SOC="spacemit/k1" ;;
        *"Titan"*|*"DP1000"*)                                  RESOLVED_SOC="ultrarisc/dp1000" ;;
        *"Atlantis"*|*"Ascalon"*)                              RESOLVED_SOC="tenstorrent/atlantis" ;;
    esac
fi

GORISCV64_CANDIDATES=()
case "$RESOLVED_SOC" in
    eswin/eic7700x)
        TARGET_SLUG="sifive-p550"
        CPU_MTUNE="sifive-p550"
        MARCH_CANDIDATES=("rv64gc_zba_zbb" "rv64gc")
        GORISCV64_CANDIDATES=("rva20u64")
        ;;
    starfive/jh7110)
        TARGET_SLUG="starfive-jh7110"
        CPU_MTUNE="sifive-u74"
        MARCH_CANDIDATES=("rv64gc_zba_zbb" "rv64gc")
        GORISCV64_CANDIDATES=("rva20u64")
        ;;
    sifive/fu740)
        TARGET_SLUG="sifive-fu740"
        CPU_MTUNE="sifive-u74"
        MARCH_CANDIDATES=("rv64gc")
        GORISCV64_CANDIDATES=("rva20u64")
        ;;
    spacemit/k1)
        TARGET_SLUG="spacemit-k1"
        CPU_MTUNE="spacemit-x60"
        MARCH_CANDIDATES=("rv64gcv_zba_zbb_zbc_zbs" "rv64gc_zba_zbb" "rv64gc")
        GORISCV64_CANDIDATES=("rva22u64" "rva20u64")
        ;;
    spacemit/k3)
        TARGET_SLUG="spacemit-k3"
        CPU_MTUNE="spacemit-x100"
        MARCH_CANDIDATES=("rva23u64" "rv64gcv_zba_zbb_zbc_zbs" "rv64gc_zba_zbb" "rv64gc")
        GORISCV64_CANDIDATES=("rva23u64" "rva22u64" "rva20u64")
        ;;
    ultrarisc/dp1000)
        TARGET_SLUG="ultrarisc-dp1000"
        CPU_MTUNE="generic-ooo"
        MARCH_CANDIDATES=("rva22u64" "rv64gc_zba_zbb_zbs" "rv64gc_zba_zbb" "rv64gc")
        GORISCV64_CANDIDATES=("rva22u64" "rva20u64")
        ;;
    tenstorrent/atlantis)
        TARGET_SLUG="tenstorrent-atlantis"
        CPU_MTUNE="tt-ascalon-d8"
        MARCH_CANDIDATES=("rva23u64" "rv64gcv_zba_zbb_zbc_zbs" "rv64gc_zba_zbb" "rv64gc")
        GORISCV64_CANDIDATES=("rva23u64" "rva22u64" "rva20u64")
        ;;
    *)
        if [[ "$GO_HOST_ARCH" == "riscv64" ]]; then
            TARGET_SLUG="riscv64-generic"
            CPU_MTUNE=""
            MARCH_CANDIDATES=("rv64gc")
            GORISCV64_CANDIDATES=("rva20u64")
        else
            TARGET_SLUG="linux-${GO_HOST_ARCH}"
            CPU_MTUNE=""
            MARCH_CANDIDATES=()
        fi
        ;;
esac

BUNDLE_NAME="ntfy-${NTFY_VERSION}-${TARGET_SLUG}.tar.zst"
BUNDLE_URL="${NTFY_PREBUILT_URL:-${RVDK_RELEASE_BASE}/${BUNDLE_NAME}}"
LOCAL_BUNDLE="${BUNDLE_DIR}/${BUNDLE_NAME}"
LOCAL_BUNDLE_SHA="${LOCAL_BUNDLE}.sha256"

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
    dl_json="$(curl -fsSL --retry 3 "https://go.dev/dl/?mode=json")" || log_fatal "Failed to query Go toolchain catalog at https://go.dev/dl/?mode=json"
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
        curl -fL --retry 3 "https://go.dev/dl/${go_file}" -o "$_NTFY_TMP_GO_TGZ"
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
        tar -xzf "$cached_tgz" -C "$ver_dir"
    fi
    ln -sfn "${ver_dir}/go" "${go_cache_root}/current"
    log_ok "Verified Go toolchain ${go_ver} (${go_sha:0:16}...)" >&2
    printf '%s\n' "${go_cache_root}/current/bin/go"
}

# 2. Install ntfy (Verified RVDK Precompiled Bundle -> Cold Source Compile Fallback)
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

BINARIES_CHANGED="false"
if [[ "$NEED_BINARY" == "false" ]]; then
    log_skip "ntfy ${NTFY_VERSION} (${TARGET_SLUG}) is already installed (pass --force-build to recompile)"
else
    mkdir -p "$BUNDLE_DIR"
    rvdk_prog 20 "ntfy ${NTFY_VERSION}: verifying archive & download prerequisites..."
    rvdk_apt_ensure curl ca-certificates zstd

    if [[ "$FORCE_BUILD" == "false" ]]; then
        HAVE_VERIFIED_LOCAL="false"
        if [[ -f "$LOCAL_BUNDLE" ]]; then
            EXPECTED_LOCAL_SHA="$(printf '%s' "$BUNDLE_SHA256" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')"
            if [[ -z "$EXPECTED_LOCAL_SHA" && -f "$LOCAL_BUNDLE_SHA" ]]; then
                EXPECTED_LOCAL_SHA="$(awk '{print tolower($1); exit}' "$LOCAL_BUNDLE_SHA")"
            fi
            if [[ "$EXPECTED_LOCAL_SHA" =~ ^[0-9a-f]{64}$ ]]; then
                if [[ "$(rvdk_sha256_file "$LOCAL_BUNDLE")" == "$EXPECTED_LOCAL_SHA" ]]; then
                    HAVE_VERIFIED_LOCAL="true"
                    log_skip "Using verified local RVDK bundle: ${LOCAL_BUNDLE}"
                fi
            fi
        fi

        if [[ "$HAVE_VERIFIED_LOCAL" == "false" ]]; then
            rvdk_prog 32 "ntfy ${NTFY_VERSION}: pulling ${TARGET_SLUG} binary bundle..."
            log_info "Pulling precompiled ${TARGET_SLUG} bundle from ${BUNDLE_URL}..."
            _NTFY_TMP_ARCHIVE="$(mktemp /tmp/rvdk-ntfy-bundle.XXXXXX.tar.zst)"
            if curl -fL --retry 3 "$BUNDLE_URL" -o "$_NTFY_TMP_ARCHIVE" 2>/dev/null; then
                EXPECTED_BUNDLE_SHA="$(printf '%s' "$BUNDLE_SHA256" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')"
                if [[ -z "$EXPECTED_BUNDLE_SHA" ]]; then
                    if curl -fsSL --retry 3 "${BUNDLE_URL}.sha256" -o "${_NTFY_TMP_ARCHIVE}.sha256" 2>/dev/null; then
                        EXPECTED_BUNDLE_SHA="$(awk '{print tolower($1); exit}' "${_NTFY_TMP_ARCHIVE}.sha256")"
                    elif [[ "$SKIP_BUNDLE_SHA" != "true" ]]; then
                        rm -f "$_NTFY_TMP_ARCHIVE" "${_NTFY_TMP_ARCHIVE}.sha256"
                        _NTFY_TMP_ARCHIVE=""
                        log_fatal "Fail-closed security check: missing SHA-256 manifest at ${BUNDLE_URL}.sha256. Supply --bundle-sha256 <hex> or --force-build."
                    fi
                fi
                if [[ -n "$EXPECTED_BUNDLE_SHA" ]]; then
                    [[ "$EXPECTED_BUNDLE_SHA" =~ ^[0-9a-f]{64}$ ]] || log_fatal "Invalid SHA-256 format '${EXPECTED_BUNDLE_SHA}' for ${BUNDLE_URL}."
                    ACTUAL_BUNDLE_SHA="$(rvdk_sha256_file "$_NTFY_TMP_ARCHIVE")"
                    if [[ "$ACTUAL_BUNDLE_SHA" != "$EXPECTED_BUNDLE_SHA" ]]; then
                        rm -f "$_NTFY_TMP_ARCHIVE" "${_NTFY_TMP_ARCHIVE}.sha256"
                        _NTFY_TMP_ARCHIVE=""
                        log_fatal "SHA-256 MISMATCH on ${BUNDLE_URL}! Expected ${EXPECTED_BUNDLE_SHA}, got ${ACTUAL_BUNDLE_SHA}."
                    fi
                    printf '%s  %s\n' "$ACTUAL_BUNDLE_SHA" "$BUNDLE_NAME" > "$LOCAL_BUNDLE_SHA"
                    chmod 0644 "$LOCAL_BUNDLE_SHA"
                    log_ok "Verified bundle SHA-256: ${ACTUAL_BUNDLE_SHA:0:16}..."
                fi
                mv -f "$_NTFY_TMP_ARCHIVE" "$LOCAL_BUNDLE"
                rm -f "${_NTFY_TMP_ARCHIVE}.sha256" 2>/dev/null || true
                _NTFY_TMP_ARCHIVE=""
                chmod 0644 "$LOCAL_BUNDLE"
            else
                rm -f "$_NTFY_TMP_ARCHIVE"
                _NTFY_TMP_ARCHIVE=""
                log_warn "No prebuilt bundle published at ${BUNDLE_URL}; falling back to cold source compile (--force-build)..."
                FORCE_BUILD="true"
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
        log_info "Executing cold source build (--force-build) for ntfy ${NTFY_VERSION} (${TARGET_SLUG})..."

        BUILD_PKGS=(git build-essential jq)
        if [[ "$NTFY_ENABLE_WEB" == "true" ]] && ! command -v npm >/dev/null 2>&1; then
            BUILD_PKGS+=(nodejs npm)
        fi
        rvdk_apt_ensure "${BUILD_PKGS[@]}"

        rm -rf "$BUILD_DIR"
        mkdir -p "${BUILD_DIR}/src" "${BUILD_DIR}/stage" "${BUILD_DIR}/gocache" "${BUILD_DIR}/gopath"

        rvdk_prog 45 "ntfy ${NTFY_VERSION}: cloning binwiederhier/ntfy tag v${NTFY_VERSION}..."
        git clone --depth 1 --branch "v${NTFY_VERSION}" https://github.com/binwiederhier/ntfy.git "${BUILD_DIR}/src" -q

        REQ_GO_VER="$(awk '/^go [0-9]+\.[0-9]+/ {print $2; exit}' "${BUILD_DIR}/src/go.mod" 2>/dev/null || echo "1.26")"
        rvdk_prog 52 "ntfy ${NTFY_VERSION}: provisioning Go >= ${REQ_GO_VER} toolchain..."
        GO_BIN="$(ensure_go_toolchain "$REQ_GO_VER")"
        GO_BIN_DIR="$(dirname "$GO_BIN")"

        OPT_FLAGS="-O3 -pipe"
        if [[ ${#MARCH_CANDIDATES[@]} -gt 0 ]]; then
            SELECTED_MARCH="${MARCH_CANDIDATES[${#MARCH_CANDIDATES[@]}-1]}"
            for cand_march in "${MARCH_CANDIDATES[@]}"; do
                if gcc -march="$cand_march" -E -x c /dev/null >/dev/null 2>&1; then
                    SELECTED_MARCH="$cand_march"
                    break
                fi
            done
            OPT_FLAGS="-O3 -pipe -march=${SELECTED_MARCH}"
            if [[ -n "$CPU_MTUNE" ]]; then
                if gcc -march="${SELECTED_MARCH}" -mcpu="${CPU_MTUNE}" -E -x c /dev/null >/dev/null 2>&1; then
                    OPT_FLAGS="${OPT_FLAGS} -mcpu=${CPU_MTUNE} -mtune=${CPU_MTUNE}"
                elif gcc -march="${SELECTED_MARCH}" -mtune="${CPU_MTUNE}" -E -x c /dev/null >/dev/null 2>&1; then
                    OPT_FLAGS="${OPT_FLAGS} -mtune=${CPU_MTUNE}"
                fi
            fi
        fi

        SELECTED_GORISCV64=""
        if [[ "$GO_HOST_ARCH" == "riscv64" && ${#GORISCV64_CANDIDATES[@]} -gt 0 ]]; then
            SELECTED_GORISCV64="rva20u64"
            for cand_gorv in "${GORISCV64_CANDIDATES[@]}"; do
                if GORISCV64="$cand_gorv" "$GO_BIN" list runtime >/dev/null 2>&1; then
                    SELECTED_GORISCV64="$cand_gorv"
                    break
                fi
            done
        fi
        log_info "Selected silicon build profile: CGO_CFLAGS='${OPT_FLAGS}'${SELECTED_GORISCV64:+ GORISCV64=${SELECTED_GORISCV64}}"

        mkdir -p "${BUILD_DIR}/src/server/docs" "${BUILD_DIR}/src/server/site"
        touch "${BUILD_DIR}/src/server/docs/index.html" "${BUILD_DIR}/src/server/site/app.html"

        WEB_BUILT="false"
        if [[ "$NTFY_ENABLE_WEB" == "true" ]]; then
            rvdk_prog 58 "ntfy ${NTFY_VERSION}: building embedded React web UI..."
            (
                cd "${BUILD_DIR}/src/web"
                PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts
                npm run build
                mv -f build/index.html build/app.html
                rm -f build/config.js
                rm -rf ../server/site
                mv build ../server/site
            )
            WEB_BUILT="true"
        fi

        GIT_COMMIT="$(git -C "${BUILD_DIR}/src" rev-parse --short=7 HEAD)"
        BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        MOD_CACHE_DIR="${RVDK_CACHE_DIR:-/var/cache/rvdk}/go/pkg/mod"
        mkdir -p "$MOD_CACHE_DIR"

        STAGE_ROOT="${BUILD_DIR}/stage"
        install -d -m 0755 "${STAGE_ROOT}/usr/bin" "${STAGE_ROOT}/etc/systemd/system" "${STAGE_ROOT}/etc/ntfy"

        rvdk_prog 64 "ntfy ${NTFY_VERSION}: compiling server & CLI (${TARGET_SLUG})..."
        BASE_LDFLAGS="-s -w -X main.version=${NTFY_VERSION} -X main.commit=${GIT_COMMIT} -X main.date=${BUILD_DATE}"
        STATIC_LDFLAGS="-linkmode=external -extldflags=-static ${BASE_LDFLAGS}"
        BUILD_TAGS="sqlite_omit_load_extension,osusergo,netgo"

        (
            cd "${BUILD_DIR}/src"
            export PATH="${GO_BIN_DIR}:${PATH}"
            export GOPATH="${BUILD_DIR}/gopath"
            export GOMODCACHE="$MOD_CACHE_DIR"
            export GOCACHE="${BUILD_DIR}/gocache"
            export GOTOOLCHAIN="local"
            export CGO_ENABLED=1
            export CGO_CFLAGS="$OPT_FLAGS"
            [[ -n "$SELECTED_GORISCV64" ]] && export GORISCV64="$SELECTED_GORISCV64"

            if ! "$GO_BIN" build -trimpath -tags "$BUILD_TAGS" -ldflags "$STATIC_LDFLAGS" -o "${STAGE_ROOT}/usr/bin/ntfy" . 2>/dev/null; then
                log_warn "Static glibc link unavailable; linking dynamically with system libc..."
                "$GO_BIN" build -trimpath -tags "$BUILD_TAGS" -ldflags "$BASE_LDFLAGS" -o "${STAGE_ROOT}/usr/bin/ntfy" .
            fi
        )
        chmod 0755 "${STAGE_ROOT}/usr/bin/ntfy"
        "${STAGE_ROOT}/usr/bin/ntfy" --version >/dev/null

        if [[ -f "${BUILD_DIR}/src/server/ntfy.service" ]]; then
            install -m 0644 "${BUILD_DIR}/src/server/ntfy.service" "${STAGE_ROOT}/etc/systemd/system/ntfy.service"
        fi
        if [[ -f "${BUILD_DIR}/src/server/server.yml" ]]; then
            install -m 0644 "${BUILD_DIR}/src/server/server.yml" "${STAGE_ROOT}/etc/ntfy/server.yml.dist"
        fi
        if [[ -f "${BUILD_DIR}/src/client/client.yml" ]]; then
            install -m 0644 "${BUILD_DIR}/src/client/client.yml" "${STAGE_ROOT}/etc/ntfy/client.yml"
        fi

        rvdk_kv_write "${STAGE_ROOT}/BUILD_INFO.env" 0644 "Managed by RVDK (mods/ntfy/forge.sh)" \
            "NTFY_VERSION=${NTFY_VERSION}" \
            "NTFY_COMMIT=${GIT_COMMIT}" \
            "TARGET_SLUG=${TARGET_SLUG}" \
            "GORISCV64=${SELECTED_GORISCV64}" \
            "CGO_CFLAGS=${OPT_FLAGS}" \
            "NTFY_WEB_EMBEDDED=${WEB_BUILT}" \
            "BUILT_AT=${BUILD_DATE}"

        rvdk_prog 72 "ntfy ${NTFY_VERSION}: packaging RVDK catalog bundle (${BUNDLE_NAME})..."
        tar -I 'zstd -9 -T0' -cf "$LOCAL_BUNDLE" -C "$STAGE_ROOT" .
        BUILT_SHA="$(rvdk_sha256_file "$LOCAL_BUNDLE")"
        printf '%s  %s\n' "$BUILT_SHA" "$BUNDLE_NAME" > "$LOCAL_BUNDLE_SHA"
        chmod 0644 "$LOCAL_BUNDLE" "$LOCAL_BUNDLE_SHA"
        log_ok "Packaged RVDK catalog bundle: ${LOCAL_BUNDLE} (SHA-256: ${BUILT_SHA:0:16}...)"

        [[ "$KEEP_BUILD_DIR" != "true" ]] && rm -rf "$BUILD_DIR"
        _NTFY_BUILD_ACTIVE="false"
    fi

    rvdk_prog 78 "ntfy ${NTFY_VERSION}: installing binary & systemd unit from verified bundle..."
    _NTFY_TMP_EXTRACT="$(mktemp -d)"
    tar -I zstd -xf "$LOCAL_BUNDLE" -C "$_NTFY_TMP_EXTRACT"
    [[ -x "${_NTFY_TMP_EXTRACT}/usr/bin/ntfy" ]] || log_fatal "Invalid ntfy bundle layout inside ${LOCAL_BUNDLE} (missing usr/bin/ntfy)."

    install -d -m 0755 /usr/bin /etc/systemd/system /etc/ntfy
    install -m 0755 "${_NTFY_TMP_EXTRACT}/usr/bin/ntfy" /usr/bin/ntfy

    if [[ -f "${_NTFY_TMP_EXTRACT}/etc/systemd/system/ntfy.service" ]]; then
        install -m 0644 "${_NTFY_TMP_EXTRACT}/etc/systemd/system/ntfy.service" /etc/systemd/system/ntfy.service
    elif [[ -f "${_NTFY_TMP_EXTRACT}/lib/systemd/system/ntfy.service" ]]; then
        install -m 0644 "${_NTFY_TMP_EXTRACT}/lib/systemd/system/ntfy.service" /etc/systemd/system/ntfy.service
    else
        cat <<'EOF' > /etc/systemd/system/ntfy.service
[Unit]
Description=ntfy server
After=network.target

[Service]
User=ntfy
Group=ntfy
RuntimeDirectory=ntfy
RuntimeDirectoryMode=0755
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
        chmod 0644 /etc/systemd/system/ntfy.service
    fi

    if [[ -f "${_NTFY_TMP_EXTRACT}/etc/ntfy/server.yml.dist" ]]; then
        install -m 0644 "${_NTFY_TMP_EXTRACT}/etc/ntfy/server.yml.dist" /etc/ntfy/server.yml.dist
    fi
    if [[ -f "${_NTFY_TMP_EXTRACT}/etc/ntfy/client.yml" && ! -f /etc/ntfy/client.yml ]]; then
        install -m 0644 "${_NTFY_TMP_EXTRACT}/etc/ntfy/client.yml" /etc/ntfy/client.yml
    fi

    BUNDLE_WEB_EMBEDDED="false"
    if [[ -r "${_NTFY_TMP_EXTRACT}/BUILD_INFO.env" ]]; then
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

# 3. System Account, Persistence Directory & Systemd Runtime Drop-In
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

if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    NTFY_DATA="${DATA_MOUNT}/ntfy"
else
    NTFY_DATA="/var/lib/ntfy"
fi

install -d -m 0755 /etc/ntfy
install -d -m 0750 -o ntfy -g ntfy "$NTFY_DATA" "${NTFY_DATA}/attachments"
install -d -m 0755 -o ntfy -g ntfy /run/ntfy

NTFY_DROPIN_DIR="/etc/systemd/system/ntfy.service.d"
NTFY_DROPIN_FILE="${NTFY_DROPIN_DIR}/90-rvdk-runtime.conf"
WANT_DROPIN="# Managed by RVDK (mods/ntfy/forge.sh)
[Service]
RuntimeDirectory=ntfy
RuntimeDirectoryMode=0755
LimitNOFILE=65536"

DROPIN_CHANGED="false"
install -d -m 0755 "$NTFY_DROPIN_DIR"
if ! printf '%s\n' "$WANT_DROPIN" | cmp -s - "$NTFY_DROPIN_FILE" 2>/dev/null; then
    printf '%s\n' "$WANT_DROPIN" > "$NTFY_DROPIN_FILE"
    chmod 0644 "$NTFY_DROPIN_FILE"
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
        PRIMARY_NIC="${RVDK_PRIMARY_NIC:-$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)}"
        if [[ -n "$PRIMARY_NIC" ]]; then
            DETECTED_IP="$(ip -o -4 addr show dev "$PRIMARY_NIC" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)"
        fi
    fi
    DEFAULT_URL_HOST="${DETECTED_IP:-127.0.0.1}"
fi
EFFECTIVE_BASE_URL="${NTFY_BASE_URL:-http://${DEFAULT_URL_HOST}:${NTFY_PORT}}"

if [[ -n "$NTFY_USER" ]]; then
    AUTH_DEFAULT_ACCESS="deny-all"
    UNIX_SOCK_MODE="0660"
else
    AUTH_DEFAULT_ACCESS="read-write"
    UNIX_SOCK_MODE="0666"
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
    TMP_CONF="${NTFY_CONF}.tmp.$$"
    printf '%s' "$WANT_NTFY_CONF" > "$TMP_CONF"
    chown root:ntfy "$TMP_CONF"
    chmod 0640 "$TMP_CONF"
    mv -f "$TMP_CONF" "$NTFY_CONF"
    CONF_CHANGED="true"
fi

AUTH_CHANGED="false"
AUTH_STAMP="/etc/ntfy/.rvdk-auth.sha256"
if [[ -n "$NTFY_USER" ]]; then
    WANT_AUTH_DIGEST="$(printf '%s:%s:%s' "$NTFY_USER" "$NTFY_ROLE" "$NTFY_PASSWORD" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print tolower($1)}')"
    HAVE_AUTH_DIGEST=""
    [[ -r "$AUTH_STAMP" ]] && HAVE_AUTH_DIGEST="$(awk '{print tolower($1); exit}' "$AUTH_STAMP" 2>/dev/null || true)"
    HAVE_AUTH_DB="true"
    [[ -z "$NTFY_DATABASE_URL" && ! -f "${NTFY_DATA}/user.db" ]] && HAVE_AUTH_DB="false"

    if [[ "$WANT_AUTH_DIGEST" != "$HAVE_AUTH_DIGEST" || "$HAVE_AUTH_DB" == "false" ]]; then
        rvdk_prog 90 "ntfy ${NTFY_VERSION}: provisioning authenticated user '${NTFY_USER}' (${NTFY_ROLE})..."
        NTFY_PASSWORD="$NTFY_PASSWORD" /usr/bin/ntfy user add --config="$NTFY_CONF" --ignore-exists --role="$NTFY_ROLE" "$NTFY_USER" >/dev/null
        NTFY_PASSWORD="$NTFY_PASSWORD" /usr/bin/ntfy user change-pass --config="$NTFY_CONF" "$NTFY_USER" >/dev/null
        /usr/bin/ntfy user change-role --config="$NTFY_CONF" "$NTFY_USER" "$NTFY_ROLE" >/dev/null
        if [[ -z "$NTFY_DATABASE_URL" ]]; then
            chown ntfy:ntfy "${NTFY_DATA}"/user.db* 2>/dev/null || true
            chmod 0640 "${NTFY_DATA}/user.db" 2>/dev/null || true
        fi
        (
            umask 077
            printf '%s\n' "$WANT_AUTH_DIGEST" > "$AUTH_STAMP"
        )
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
