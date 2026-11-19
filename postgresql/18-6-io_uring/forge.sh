#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: PostgreSQL 18.6 io_uring (riscv64 + Sv39 HugePages)
# Path: riscv-data-kit/postgresql/18-6-io_uring/forge.sh
#
# Security, Supply-Chain & Performance Hardening:
#   • SHA-256 verifies precompiled binary bundles prior to extraction
#     (requiring explicit --bundle-sha256 or --allow-remote-sha256 for unpinned sidecars)
#   • Verifies PGDG signing key fingerprint (B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8)
#     and compiles source packages under unprivileged `_apt` account
#   • Consolidates silicon compiler profiles via `lib/kit.sh` (including QEMU riscv64-generic)
#   • Probes kernel `io_uring` availability + `LimitMEMLOCK=infinity` (clean worker fallback)
#   • Computes exact 2MB HugePages via `postgres -C shared_memory_size_in_huge_pages`
#   • Binds `listen_addresses = 'localhost'` by default unless `--listen` or `--allow-cidr`
#   • Zero-disruption idempotency (0 restarts when converged; reload-only on HBA edits)
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

# @RVDK_INLINE_LIBS: common kit apt progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:PG18]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_sanitize_locale() { export LANG="C.UTF-8" LC_ALL="C.UTF-8"; }
        rvdk_resolve_caller() { REAL_USER="${SUDO_USER:-root}"; REAL_GRP="root"; }
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
        rvdk_validate_pg_ident() { [[ "${1:-}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; }
        rvdk_validate_abs_path() { [[ "${1:-}" =~ ^/[A-Za-z0-9._/-]+$ && ! "${1:-}" =~ (^|/)\.\.(/|$) ]]; }
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

rvdk_log_init "RVDK:PG18"

usage() {
    cat <<'EOF'
Usage: sudo rvdk postgresql/18-6-io_uring [options]

Options:
  --data-mount <path>                NVMe mount root for PGDATA relocation (default: auto /mnt/nvme_data)
  --listen <localhost|ip|*>          PostgreSQL listen_addresses (default: localhost, or '*' if --allow-cidr set)
  --allow-cidr <CIDR>                Grant scram-sha-256 HBA access to IPv4 CIDR (alias: --subnet)
  --auto-subnet                      Auto-detect primary NIC IPv4 subnet for --allow-cidr
  --register-tablespace <name>:<dir> Create & idempotently register PostgreSQL tablespace (repeatable)
  --force-build                      Compile PostgreSQL 18 from PGDG source with SoC -march/-mtune flags
  --keep-build-dir                   Retain build workspace after --force-build
  --bundle-sha256 <hex64>            Expected SHA-256 digest for prebuilt .tar.zst bundle
  --allow-remote-sha256              Trust same-origin .sha256 sidecar when --bundle-sha256 is unset
  --soc <vendor/soc>                 Explicit SoC target override
  --board <vendor/board>             Explicit board target override
  --no-apt-update                    Skip redundant apt-get update calls
  --noprogbar                        Disable persistent bottom progress bar
  -h, --help                         Show this help message and exit
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
    MOUNT_POINT PG_ALLOW_CIDR RVDK_ALLOW_CIDR PG_LISTEN_ADDRESSES \
    KERNEL_HUGEPAGES_2MB PG_SHARED_BUFFERS PG_EFFECTIVE_CACHE_SIZE PG_MAINT_WORK_MEM \
    PG_PREBUILT_DEB_URL PG_PREBUILT_SHA256 RVDK_RELEASE_BASE

PG_VERSION="18"
FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
ALLOW_REMOTE_SHA="false"
SKIP_BUNDLE_SHA="false"
BUNDLE_SHA256="${PG_PREBUILT_SHA256:-}"
ALLOW_CIDR="${PG_ALLOW_CIDR:-${RVDK_ALLOW_CIDR:-}}"
AUTO_SUBNET="false"
PG_LISTEN="${PG_LISTEN_ADDRESSES:-}"
RVDK_RELEASE_BASE="${RVDK_RELEASE_BASE:-https://github.com/drewv-labs/riscv-data-kit/releases/download/rvdk-v1}"
CLI_SOC=""
CLI_BOARD=""
EXPLICIT_DATA_MOUNT=""
TABLESPACE_SPECS=()

_require_arg() {
    [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."
    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-build|--force-rebuild-pg|--compile)
            FORCE_BUILD="true"; shift ;;
        --keep-build-dir)
            KEEP_BUILD_DIR="true"; shift ;;
        --bundle-sha256)
            _require_arg "$1" "${2:-}"; BUNDLE_SHA256="$2"; shift 2 ;;
        --allow-remote-sha256)
            ALLOW_REMOTE_SHA="true"; shift ;;
        --insecure-skip-sha256)
            SKIP_BUNDLE_SHA="true"; shift ;;
        --data-mount)
            _require_arg "$1" "${2:-}"; EXPLICIT_DATA_MOUNT="$2"; shift 2 ;;
        --allow-cidr|--subnet)
            _require_arg "$1" "${2:-}"; ALLOW_CIDR="$2"; shift 2 ;;
        --auto-subnet)
            AUTO_SUBNET="true"; shift ;;
        --listen|--listen-addresses)
            _require_arg "$1" "${2:-}"; PG_LISTEN="$2"; shift 2 ;;
        --register-tablespace)
            _require_arg "$1" "${2:-}"; TABLESPACE_SPECS+=("$2"); shift 2 ;;
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

DATA_MOUNT="$(rvdk_resolve_data_mount "$EXPLICIT_DATA_MOUNT")"

# Validate optional tablespace specifications upfront
for _ts_spec in ${TABLESPACE_SPECS[@]+"${TABLESPACE_SPECS[@]}"}; do
    [[ "$_ts_spec" == *:* ]] || log_fatal "Invalid --register-tablespace '${_ts_spec}' (expected <name>:<abs_dir>)."
    _ts_name="${_ts_spec%%:*}"
    _ts_dir="$(rvdk_normalize_mount_path "${_ts_spec#*:}")"
    rvdk_validate_pg_ident "$_ts_name" || log_fatal "Invalid PostgreSQL tablespace identifier '${_ts_name}' (expected lowercase [a-z_][a-z0-9_]{0,62})."
    [[ -n "$_ts_dir" && "$_ts_dir" != "/" ]] && rvdk_validate_abs_path "$_ts_dir" || log_fatal "Invalid PostgreSQL tablespace directory '${_ts_dir}'."
done

if [[ -z "$ALLOW_CIDR" && "$AUTO_SUBNET" == "true" ]]; then
    ALLOW_CIDR="$(rvdk_detect_primary_cidr || true)"
    [[ -z "$ALLOW_CIDR" ]] && log_fatal "--auto-subnet could not determine an active IPv4 subnet; pass --allow-cidr <CIDR>."
fi
if [[ -n "$ALLOW_CIDR" ]]; then
    if ! ALLOW_CIDR="$(rvdk_normalize_ipv4_cidr "$ALLOW_CIDR")"; then
        log_fatal "Invalid IPv4 CIDR '${ALLOW_CIDR}'."
    fi
fi
if [[ -z "$PG_LISTEN" ]]; then
    if [[ -n "$ALLOW_CIDR" ]]; then
        PG_LISTEN="*"
    else
        PG_LISTEN="localhost"
    fi
fi
[[ "$PG_LISTEN" =~ ^[A-Za-z0-9.,:*_-]+$ ]] || log_fatal "Invalid --listen value '${PG_LISTEN}'."

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

_PG_TMP_ARCHIVE=""
_PG_BUILD_ACTIVE="false"
PG_LIB_ROOT="/var/lib/rvdk/pgdg-riscv64"
BUILD_DIR="${PG_LIB_ROOT}/build"
_rvdk_pg_cleanup() {
    declare -F _rvdk_cleanup_tmpfiles >/dev/null 2>&1 && _rvdk_cleanup_tmpfiles
    [[ -n "$_PG_TMP_ARCHIVE" ]] && rm -f "$_PG_TMP_ARCHIVE" "${_PG_TMP_ARCHIVE}.sha256" 2>/dev/null || true
    if [[ "$_PG_BUILD_ACTIVE" == "true" && "$KEEP_BUILD_DIR" != "true" && -d "$BUILD_DIR" ]]; then
        rm -rf "$BUILD_DIR" 2>/dev/null || true
    fi
}
trap '_rvdk_pg_cleanup' EXIT INT TERM

rvdk_prog_init "PG 18.6: detecting RISC-V silicon profile..."

# 1. Resolve Silicon Target, ISA Flags & RAM-Aware Sv39 Profile via lib/kit.sh
_KIT_ARGS=()
[[ -n "$CLI_SOC" ]] && _KIT_ARGS+=("--soc" "$CLI_SOC")
[[ -n "$CLI_BOARD" ]] && _KIT_ARGS+=("--board" "$CLI_BOARD")
rvdk_kit_resolve ${_KIT_ARGS[@]+"${_KIT_ARGS[@]}"}

UNAME_M="$(uname -m)"
if ! rvdk_kit_compiler_profile "${CLI_SOC:-${RVDK_SOC:-}}" "$UNAME_M"; then
    log_fatal "Unsupported CPU/SoC target for PostgreSQL 18: '${RVDK_DT_MODEL:-unknown}' (${UNAME_M})."
fi
TARGET_SLUG="$RVDK_TARGET_SLUG"
CPU_MTUNE="$RVDK_CPU_MTUNE"

MEM_KB="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 8388608)"
MEM_GIB=$(( (MEM_KB + 524288) / 1048576 ))
if (( MEM_GIB >= 48 )); then
    _DEF_HP=9216; _DEF_SB="16GB"; _DEF_EC="48GB"; _DEF_MM="2GB";   _DEF_WM="64MB"
elif (( MEM_GIB >= 24 )); then
    _DEF_HP=4608; _DEF_SB="8GB";  _DEF_EC="24GB"; _DEF_MM="2GB";   _DEF_WM="64MB"
elif (( MEM_GIB >= 12 )); then
    _DEF_HP=2304; _DEF_SB="4GB";  _DEF_EC="12GB"; _DEF_MM="1GB";   _DEF_WM="32MB"
elif (( MEM_GIB >= 6 )); then
    _DEF_HP=1152; _DEF_SB="2GB";  _DEF_EC="6GB";  _DEF_MM="512MB"; _DEF_WM="32MB"
elif (( MEM_GIB >= 3 )); then
    _DEF_HP=576;  _DEF_SB="1GB";  _DEF_EC="3GB";  _DEF_MM="256MB"; _DEF_WM="16MB"
else
    _DEF_HP=256;  _DEF_SB="512MB"; _DEF_EC="1536MB"; _DEF_MM="128MB"; _DEF_WM="8MB"
fi

PG_SHARED_BUFFERS="${PG_SHARED_BUFFERS:-$_DEF_SB}"
PG_EFFECTIVE_CACHE="${PG_EFFECTIVE_CACHE_SIZE:-$_DEF_EC}"
PG_MAINT_MEM="${PG_MAINT_WORK_MEM:-$_DEF_MM}"
PG_WORK_MEM="${PG_WORK_MEM:-$_DEF_WM}"

BUNDLE_NAME="postgresql18-6-io_uring-${TARGET_SLUG}.tar.zst"
BUNDLE_URL="${PG_PREBUILT_DEB_URL:-${RVDK_RELEASE_BASE}/${BUNDLE_NAME}}"
LOCAL_REPO_DIR="${PG_LIB_ROOT}/debs"
LOCAL_LIST="/etc/apt/sources.list.d/rvdk-local-pgdg.list"

update_local_repo() {
    (
        cd "$LOCAL_REPO_DIR"
        dpkg-scanpackages . /dev/null > Packages 2>/dev/null
        gzip -9cn Packages > Packages.gz
    )
    printf 'deb [trusted=yes lang=none] file://%s ./\n' "$LOCAL_REPO_DIR" | rvdk_atomic_write "$LOCAL_LIST" 0644
    if rvdk_apt_has_lists; then
        apt-get update \
            -o Dir::Etc::sourcelist="$LOCAL_LIST" \
            -o Dir::Etc::sourceparts="-" \
            -o APT::Get::List-Cleanup="0" -q
    else
        rvdk_apt_update
    fi
}

# 2. Install PostgreSQL 18.6 (Verified Precompiled Bundle -> Unprivileged PGDG Source Fallback)
rvdk_prog 15 "PG 18.6: checking postgresql-${PG_VERSION} package state..."
PACKAGES_CHANGED="false"
if dpkg -s "postgresql-${PG_VERSION}" >/dev/null 2>&1 && [[ "$FORCE_BUILD" == "false" ]]; then
    log_skip "postgresql-${PG_VERSION} is already installed (pass --force-build to recompile)"
else
    mkdir -p /var/lib/rvdk "$PG_LIB_ROOT" "$LOCAL_REPO_DIR"
    chmod 0755 /var/lib/rvdk "$PG_LIB_ROOT" "$LOCAL_REPO_DIR" 2>/dev/null || true
    rvdk_prog 20 "PG 18.6: verifying repository & archive prerequisites..."
    rvdk_apt_ensure curl ca-certificates zstd dpkg-dev gnupg lsb-release rsync

    if [[ "$FORCE_BUILD" == "false" ]]; then
        if ! compgen -G "${LOCAL_REPO_DIR}/postgresql-${PG_VERSION}_*.deb" >/dev/null 2>&1; then
            EXPECTED_BUNDLE_SHA="$(printf '%s' "$BUNDLE_SHA256" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')"
            if [[ -z "$EXPECTED_BUNDLE_SHA" && "$ALLOW_REMOTE_SHA" != "true" && "$SKIP_BUNDLE_SHA" != "true" ]]; then
                if [[ -n "${PG_PREBUILT_DEB_URL:-}" ]]; then
                    log_fatal "Refusing to trust unpinned PG_PREBUILT_DEB_URL (${BUNDLE_URL}) without --bundle-sha256 <hex64> or explicit --allow-remote-sha256."
                fi
                log_warn "No pinned SHA-256 provided for ${BUNDLE_NAME} (pass --bundle-sha256 or --allow-remote-sha256 to use remote .sha256 sidecar); falling back to verified PGDG source build..."
                FORCE_BUILD="true"
            else
                rvdk_prog 35 "PG 18.6: pulling ${TARGET_SLUG} io_uring binary bundle..."
                log_info "Pulling precompiled ${TARGET_SLUG} bundle from ${BUNDLE_URL}..."
                _PG_TMP_ARCHIVE="$(mktemp /tmp/rvdk-pg18-bundle.XXXXXX.tar.zst)"
                if curl -fL --retry 3 "$BUNDLE_URL" -o "$_PG_TMP_ARCHIVE"; then
                    if [[ -z "$EXPECTED_BUNDLE_SHA" && "$ALLOW_REMOTE_SHA" == "true" ]]; then
                        if curl -fsSL --retry 3 "${BUNDLE_URL}.sha256" -o "${_PG_TMP_ARCHIVE}.sha256"; then
                            EXPECTED_BUNDLE_SHA="$(awk '{print tolower($1); exit}' "${_PG_TMP_ARCHIVE}.sha256")"
                        elif [[ "$SKIP_BUNDLE_SHA" != "true" ]]; then
                            rm -f "$_PG_TMP_ARCHIVE" "${_PG_TMP_ARCHIVE}.sha256"
                            _PG_TMP_ARCHIVE=""
                            log_fatal "Fail-closed security check: missing SHA-256 manifest at ${BUNDLE_URL}.sha256. Supply --bundle-sha256 <hex> or --force-build."
                        fi
                    fi
                    if [[ -n "$EXPECTED_BUNDLE_SHA" ]]; then
                        [[ "$EXPECTED_BUNDLE_SHA" =~ ^[0-9a-f]{64}$ ]] || log_fatal "Invalid SHA-256 format '${EXPECTED_BUNDLE_SHA}' for ${BUNDLE_URL}."
                        ACTUAL_BUNDLE_SHA="$(rvdk_sha256_file "$_PG_TMP_ARCHIVE")"
                        if [[ "$ACTUAL_BUNDLE_SHA" != "$EXPECTED_BUNDLE_SHA" ]]; then
                            rm -f "$_PG_TMP_ARCHIVE" "${_PG_TMP_ARCHIVE}.sha256"
                            _PG_TMP_ARCHIVE=""
                            log_fatal "SHA-256 MISMATCH on ${BUNDLE_URL}! Expected ${EXPECTED_BUNDLE_SHA}, got ${ACTUAL_BUNDLE_SHA}."
                        fi
                        log_ok "Verified bundle SHA-256: ${ACTUAL_BUNDLE_SHA:0:16}..."
                    fi
                    tar -I zstd -xf "$_PG_TMP_ARCHIVE" -C "$LOCAL_REPO_DIR"
                    rm -f "$_PG_TMP_ARCHIVE" "${_PG_TMP_ARCHIVE}.sha256" "${LOCAL_REPO_DIR}"/*-dbgsym_*.deb
                    _PG_TMP_ARCHIVE=""
                    log_ok "Extracted verified PostgreSQL 18.6 bundle to ${LOCAL_REPO_DIR}"
                else
                    rm -f "$_PG_TMP_ARCHIVE"
                    _PG_TMP_ARCHIVE=""
                    log_warn "No prebuilt bundle published at ${BUNDLE_URL}; falling back to verified PGDG source compile (--force-build)..."
                    FORCE_BUILD="true"
                fi
            fi
        fi
        if [[ "$FORCE_BUILD" == "false" ]]; then
            rvdk_prog 50 "PG 18.6: indexing local PGDG repository..."
            update_local_repo
        fi
    fi

    if [[ "$FORCE_BUILD" == "true" ]]; then
        _PG_BUILD_ACTIVE="true"
        rvdk_prog 25 "PG 18.6: preparing verified PGDG source build (${TARGET_SLUG})..."
        log_info "Executing unprivileged PGDG source build (--force-build) for ${TARGET_SLUG}..."

        PGDG_KEY_PATH="/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc"
        PGDG_EXPECTED_FPR="B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8"
        install -d -m 0755 /usr/share/postgresql-common/pgdg
        TMP_KEY="$(mktemp)"
        curl -fsSL --retry 3 https://www.postgresql.org/media/keys/ACCC4CF8.asc -o "$TMP_KEY"
        ACTUAL_FPR="$(gpg --batch --with-colons --import-options import-show --dry-run --import "$TMP_KEY" 2>/dev/null | awk -F: '$1 == "fpr" {print toupper($10); exit}')"
        if [[ "$ACTUAL_FPR" != "$PGDG_EXPECTED_FPR" ]]; then
            rm -f "$TMP_KEY"
            log_fatal "PGDG GPG key fingerprint mismatch! Expected ${PGDG_EXPECTED_FPR}, got '${ACTUAL_FPR:-none}'."
        fi
        rvdk_atomic_write "$PGDG_KEY_PATH" 0644 < "$TMP_KEY"
        rm -f "$TMP_KEY"
        log_ok "Verified PGDG signing key fingerprint (${PGDG_EXPECTED_FPR})"

        CODENAME="$(lsb_release -cs 2>/dev/null || awk -F= '/^VERSION_CODENAME=/ {gsub(/["'\'']/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || echo sid)"
        case "$CODENAME" in
            noble|jammy|plucky|questing) ;;
            jupiter|mantic|*bianbu*)     CODENAME="noble" ;;
            forky|trixie|bookworm|sid|n/a|"") CODENAME="sid" ;;
            *)
                if [[ "${RVDK_OS_ID:-}" == "ubuntu" || "${RVDK_OS_ID:-}" == "bianbu" ]]; then
                    CODENAME="noble"
                else
                    CODENAME="sid"
                fi
                ;;
        esac
        PGDG_LIST="/etc/apt/sources.list.d/pgdg.list"
        printf 'deb-src [signed-by=%s] https://apt.postgresql.org/pub/repos/apt %s-pgdg main %s\n' \
            "$PGDG_KEY_PATH" "$CODENAME" "$PG_VERSION" | rvdk_atomic_write "$PGDG_LIST" 0644
        if [[ "${RVDK_NO_APT_UPDATE:-0}" == "1" ]] && rvdk_apt_has_lists; then
            apt-get update \
                -o Dir::Etc::sourcelist="$PGDG_LIST" \
                -o Dir::Etc::sourceparts="-" \
                -o APT::Get::List-Cleanup="0" -q
        else
            apt-get update -q
            rvdk_apt_mark_updated
        fi
        rvdk_apt_ensure debhelper build-essential liburing-dev libzstd-dev liblz4-dev bc time fakeroot

        rvdk_kit_probe_cflags gcc
        OPT_FLAGS="$RVDK_OPT_CFLAGS"
        log_info "Selected compiler ISA flags: ${OPT_FLAGS}"

        DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
        BUILD_USER="_apt"
        if ! id -u "$BUILD_USER" >/dev/null 2>&1; then
            BUILD_USER="nobody"
        fi
        BUILD_GRP="$(id -gn "$BUILD_USER" 2>/dev/null || echo "nogroup")"

        mkdir -p "$BUILD_DIR" "${BUILD_DIR}/home"
        chmod 0755 /var/lib/rvdk "$PG_LIB_ROOT" "$BUILD_DIR"
        chown -R "${BUILD_USER}:${BUILD_GRP}" "$BUILD_DIR"

        if ! dpkg -s postgresql-common-dev >/dev/null 2>&1; then
            rvdk_prog 35 "PG 18.6: compiling postgresql-common as ${BUILD_USER}..."
            rm -rf "${BUILD_DIR:?}"/*
            mkdir -p "${BUILD_DIR}/home" "${BUILD_DIR}/work"
            chown -R "${BUILD_USER}:${BUILD_GRP}" "$BUILD_DIR"
            apt-get build-dep "${APT_FLAGS[@]}" postgresql-common
            run_as_user "$BUILD_USER" env \
                HOME="${BUILD_DIR}/home" \
                DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS" \
                DEB_CFLAGS_APPEND="$OPT_FLAGS" \
                DEB_CXXFLAGS_APPEND="$OPT_FLAGS" \
                bash -Eeuo pipefail -c 'cd "$1/work" && apt-get source --compile postgresql-common' _ "$BUILD_DIR"
            chown 0:0 "${BUILD_DIR}/work"/*.deb
            mv -f "${BUILD_DIR}/work"/*.deb "$LOCAL_REPO_DIR/"
            update_local_repo
            apt-get install "${APT_FLAGS[@]}" postgresql-common postgresql-common-dev
        fi

        rvdk_prog 45 "PG 18.6: compiling postgresql-${PG_VERSION} (${CPU_MTUNE:-generic} + io_uring) as ${BUILD_USER}..."
        rm -rf "${BUILD_DIR:?}"/*
        mkdir -p "${BUILD_DIR}/home" "${BUILD_DIR}/work"
        chown -R "${BUILD_USER}:${BUILD_GRP}" "$BUILD_DIR"
        apt-get build-dep "${APT_FLAGS[@]}" "postgresql-${PG_VERSION}"
        run_as_user "$BUILD_USER" env \
            HOME="${BUILD_DIR}/home" \
            DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS" \
            DEB_CFLAGS_APPEND="$OPT_FLAGS" \
            DEB_CXXFLAGS_APPEND="$OPT_FLAGS" \
            bash -Eeuo pipefail -c 'cd "$1/work" && apt-get source --compile "postgresql-$2"' _ "$BUILD_DIR" "$PG_VERSION"
        chown 0:0 "${BUILD_DIR}/work"/*.deb
        mv -f "${BUILD_DIR}/work"/*.deb "$LOCAL_REPO_DIR/"
        rm -f "${LOCAL_REPO_DIR}"/*-dbgsym_*.deb
        [[ "$KEEP_BUILD_DIR" != "true" ]] && rm -rf "$BUILD_DIR"
        _PG_BUILD_ACTIVE="false"
        update_local_repo
    fi

    rvdk_prog 60 "PG 18.6: installing postgresql-${PG_VERSION} packages..."
    rvdk_apt_update
    apt-get install "${APT_FLAGS[@]}" "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"
    PACKAGES_CHANGED="true"
    log_ok "Installed PostgreSQL ${PG_VERSION} (${TARGET_SLUG})"
fi

# 3. Kernel io_uring Preflight Probe
IO_METHOD="io_uring"
URING_DISABLED="$(sysctl -n kernel.io_uring_disabled 2>/dev/null || echo 0)"
if [[ "$URING_DISABLED" != "0" ]]; then
    if sysctl -w kernel.io_uring_disabled=0 >/dev/null 2>&1; then
        printf 'kernel.io_uring_disabled = 0\n' | rvdk_atomic_write /etc/sysctl.d/89-rvdk-io-uring.conf 0644
    else
        IO_METHOD="worker"
        log_warn "kernel.io_uring_disabled=${URING_DISABLED}; falling back to PostgreSQL 18 io_method = worker"
    fi
fi
if [[ "$IO_METHOD" == "io_uring" && -r "/boot/config-$(uname -r)" ]]; then
    if grep -q '^# CONFIG_IO_URING is not set' "/boot/config-$(uname -r)" 2>/dev/null; then
        IO_METHOD="worker"
        log_warn "Kernel $(uname -r) compiled without CONFIG_IO_URING; falling back to io_method = worker"
    fi
fi

# 4. Relocate PGDATA Cluster (if NVMe mount is present) & Compute Dynamic WAL Cap
CLUSTER_MIGRATED="false"
if [[ -n "$DATA_MOUNT" ]] && mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    TARGET_PGDATA="${DATA_MOUNT}/postgresql/${PG_VERSION}/main"
    if [[ ! -f "${TARGET_PGDATA}/PG_VERSION" ]]; then
        rvdk_prog 72 "PG 18.6: migrating PGDATA cluster to ${TARGET_PGDATA}..."
        systemctl stop postgresql
        install -d -m 0700 -o postgres -g postgres "$TARGET_PGDATA"
        rsync -a "/var/lib/postgresql/${PG_VERSION}/main/" "${TARGET_PGDATA}/"
        CLUSTER_MIGRATED="true"
        log_ok "Migrated PostgreSQL cluster to ${TARGET_PGDATA}"
    fi
else
    TARGET_PGDATA="/var/lib/postgresql/${PG_VERSION}/main"
fi

# Scale max_wal_size safely so smaller 32GB/64GB partitions never hit ENOSPC
FS_AVAIL_GIB="$(df -BG --output=avail "$(dirname "$TARGET_PGDATA")" 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 64)"
[[ -z "$FS_AVAIL_GIB" ]] && FS_AVAIL_GIB=64
WAL_MAX_GIB=$(( FS_AVAIL_GIB / 5 ))
(( WAL_MAX_GIB < 2 )) && WAL_MAX_GIB=2
(( WAL_MAX_GIB > 16 )) && WAL_MAX_GIB=16
WAL_MIN_GIB=$(( WAL_MAX_GIB >= 8 ? 2 : 1 ))

# 5. Stage Drop-In Config & Exact Sv39 2MB HugePages Reservation
rvdk_prog 82 "PG 18.6: converging io_uring config, HugePages & VIP QoS..."
CONF_DIR="/etc/postgresql/${PG_VERSION}/main/conf.d"
CONF_FILE="${CONF_DIR}/99-rvdk-${TARGET_SLUG}.conf"
install -d -m 0755 -o postgres -g postgres "$CONF_DIR"

HARTS="$(nproc)"
PAR_GATHER=$(( HARTS > 1 ? HARTS - 1 : 0 ))
(( PAR_GATHER > 4 )) && PAR_GATHER=4

WANT_PG_CONF="data_directory = '${TARGET_PGDATA}'
listen_addresses = '${PG_LISTEN}'
shared_buffers = ${PG_SHARED_BUFFERS}
huge_pages = try
huge_page_size = 2MB
effective_cache_size = ${PG_EFFECTIVE_CACHE}
work_mem = ${PG_WORK_MEM}
maintenance_work_mem = ${PG_MAINT_MEM}
jit = off
max_worker_processes = ${HARTS}
max_parallel_workers = ${HARTS}
max_parallel_workers_per_gather = ${PAR_GATHER}
io_method = ${IO_METHOD}
random_page_cost = 1.1
effective_io_concurrency = 200
wal_compression = zstd
wal_buffers = 64MB
min_wal_size = ${WAL_MIN_GIB}GB
max_wal_size = ${WAL_MAX_GIB}GB
checkpoint_completion_target = 0.9"

CONF_CHANGED="false"
if ! printf '%s\n' "$WANT_PG_CONF" | cmp -s - "$CONF_FILE" 2>/dev/null; then
    printf '%s\n' "$WANT_PG_CONF" | rvdk_atomic_write "$CONF_FILE" 0644 postgres:postgres
    CONF_CHANGED="true"
fi

# Query exact HugePages required by PostgreSQL 18 (+3% headroom) when not explicitly overridden
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin/postgres"
if [[ -n "${KERNEL_HUGEPAGES_2MB:-}" ]]; then
    HUGEPAGES_2MB="$KERNEL_HUGEPAGES_2MB"
elif [[ -x "$PG_BIN" ]]; then
    CALC_HP="$(run_as_user postgres "$PG_BIN" -D "/etc/postgresql/${PG_VERSION}/main" -C shared_memory_size_in_huge_pages 2>/dev/null | tr -dc '0-9' || true)"
    if [[ "$CALC_HP" =~ ^[0-9]+$ ]] && (( CALC_HP > 0 )); then
        HUGEPAGES_2MB=$(( CALC_HP + (CALC_HP * 3 + 99) / 100 + 8 ))
    else
        HUGEPAGES_2MB="$_DEF_HP"
    fi
else
    HUGEPAGES_2MB="$_DEF_HP"
fi

PG_GID="$(getent group postgres | cut -d: -f3)"
HP_SYSCTL="/etc/sysctl.d/90-rvdk-pg18-hugepages.conf"
WANT_HP_SYSCTL="vm.nr_hugepages = ${HUGEPAGES_2MB}
vm.hugetlb_shm_group = ${PG_GID}"

HP_CHANGED="false"
if ! printf '%s\n' "$WANT_HP_SYSCTL" | cmp -s - "$HP_SYSCTL" 2>/dev/null; then
    printf '%s\n' "$WANT_HP_SYSCTL" | rvdk_atomic_write "$HP_SYSCTL" 0644
    sysctl -p "$HP_SYSCTL" >/dev/null 2>&1 || true
    HP_CHANGED="true"
fi
ALLOC_HP="$(awk '/^HugePages_Total:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
if (( ALLOC_HP < HUGEPAGES_2MB )); then
    log_warn "Kernel allocated ${ALLOC_HP}/${HUGEPAGES_2MB} 2MB HugePages due to live RAM fragmentation; huge_pages=try will fall back gracefully until next reboot."
fi

HBA_FILE="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
HBA_CHANGED="false"
if [[ -n "$ALLOW_CIDR" && -f "$HBA_FILE" ]]; then
    WANT_HBA_RULE="host    all             all             ${ALLOW_CIDR}            scram-sha-256"
    if ! grep -qxF "$WANT_HBA_RULE" "$HBA_FILE"; then
        { cat "$HBA_FILE"; printf '%s\n' "$WANT_HBA_RULE"; } | rvdk_atomic_write "$HBA_FILE" 0640 postgres:postgres
        HBA_CHANGED="true"
    fi
fi

# VIP cgroup v2 CPU/IO QoS + LimitMEMLOCK=infinity for io_uring pinned ring buffers
PG_QOS_DIR="/etc/systemd/system/postgresql@.service.d"
PG_QOS_FILE="${PG_QOS_DIR}/90-rvdk-qos.conf"
WANT_PG_QOS="# Managed by RVDK (postgresql/18-6-io_uring/forge.sh)
# VIP CPU & block I/O priority + unlimited memlock for PostgreSQL 18 io_uring rings.
[Service]
CPUWeight=200
IOWeight=500
Nice=-5
IOSchedulingClass=best-effort
IOSchedulingPriority=0
LimitMEMLOCK=infinity
LimitNOFILE=1048576"

QOS_CHANGED="false"
install -d -m 0755 "$PG_QOS_DIR"
if ! printf "%s\n" "$WANT_PG_QOS" | cmp -s - "$PG_QOS_FILE" 2>/dev/null; then
    printf "%s\n" "$WANT_PG_QOS" | rvdk_atomic_write "$PG_QOS_FILE" 0644
    systemctl daemon-reload
    QOS_CHANGED="true"
    log_ok "Applied VIP cgroup v2 QoS & LimitMEMLOCK=infinity (${PG_QOS_FILE})"
fi

# 6. Zero-Disruption Cluster Activation (restart ONLY when required)
systemctl enable postgresql >/dev/null 2>&1 || true
PG_UNIT="postgresql@${PG_VERSION}-main.service"

if ! systemctl is-active --quiet "$PG_UNIT" 2>/dev/null; then
    systemctl start postgresql
elif [[ "$PACKAGES_CHANGED" == "true" || "$CLUSTER_MIGRATED" == "true" || "$CONF_CHANGED" == "true" || "$QOS_CHANGED" == "true" || "$HP_CHANGED" == "true" ]]; then
    systemctl restart postgresql
elif [[ "$HBA_CHANGED" == "true" ]]; then
    systemctl reload postgresql
    log_ok "Reloaded pg_hba.conf online with zero connection drops"
else
    log_skip "PostgreSQL ${PG_VERSION} cluster already active and converged (zero restarts)"
fi

# 7. Optional Declarative PostgreSQL Tablespace Registration (--register-tablespace <name>:<dir>)
for _ts_spec in ${TABLESPACE_SPECS[@]+"${TABLESPACE_SPECS[@]}"}; do
    _ts_name="${_ts_spec%%:*}"
    _ts_dir="$(rvdk_normalize_mount_path "${_ts_spec#*:}")"
    install -d -m 0700 -o postgres -g postgres "$_ts_dir"
    _exists_ts="$(run_as_user postgres psql -v ts="$_ts_name" -tAc "SELECT 1 FROM pg_tablespace WHERE spcname = :'ts';" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$_exists_ts" != "1" ]]; then
        _escaped_loc="${_ts_dir//\'/\'\'}"
        run_as_user postgres psql -c "CREATE TABLESPACE \"${_ts_name}\" LOCATION '${_escaped_loc}';" >/dev/null
        log_ok "Registered PostgreSQL Tablespace '${_ts_name}' -> ${_ts_dir}"
    else
        log_skip "PostgreSQL Tablespace '${_ts_name}' already registered"
    fi
done

ACTIVE_IO="$(run_as_user postgres psql -tAc 'SHOW io_method;' 2>/dev/null | xargs || echo "$IO_METHOD")"
rvdk_prog 100 "PostgreSQL 18.6 (${ACTIVE_IO}) online"
log_ok "PostgreSQL 18.6 online (listen=${PG_LISTEN}, io_method=${ACTIVE_IO}, shared_buffers=${PG_SHARED_BUFFERS})"
