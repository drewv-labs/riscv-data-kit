#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: PostgreSQL 18.6 io_uring (riscv64 + Sv39 HugePages)
# Path: riscv-data-kit/postgresql/18-6-io_uring/forge.sh
#
# Security, Supply-Chain & Performance Hardening:
#   • SHA-256 verifies precompiled binary bundles prior to extraction
#   • Verifies PGDG signing key fingerprint (B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8)
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

rvdk_log_init "RVDK:PG18"
rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
rvdk_sanitize_locale
rvdk_resolve_caller

rvdk_load_config_env \
    MOUNT_POINT PG_ALLOW_CIDR LAB_SUBNET PG_LISTEN_ADDRESSES \
    KERNEL_HUGEPAGES_2MB PG_SHARED_BUFFERS PG_EFFECTIVE_CACHE_SIZE PG_MAINT_WORK_MEM \
    PG_PREBUILT_DEB_URL PG_PREBUILT_SHA256 RVDK_RELEASE_BASE

PG_VERSION="18"
FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
SKIP_BUNDLE_SHA="false"
BUNDLE_SHA256="${PG_PREBUILT_SHA256:-}"
ALLOW_CIDR="${PG_ALLOW_CIDR:-${LAB_SUBNET:-}}"
AUTO_SUBNET="false"
PG_LISTEN="${PG_LISTEN_ADDRESSES:-}"
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
        --force-build|--force-rebuild-pg|--compile)
            FORCE_BUILD="true"; shift ;;
        --keep-build-dir)
            KEEP_BUILD_DIR="true"; shift ;;
        --bundle-sha256)
            BUNDLE_SHA256="${2:-}"; shift 2 ;;
        --insecure-skip-sha256)
            SKIP_BUNDLE_SHA="true"; shift ;;
        --data-mount)
            DATA_MOUNT="${2:-}"; shift 2 ;;
        --allow-cidr|--subnet)
            ALLOW_CIDR="${2:-}"; shift 2 ;;
        --auto-subnet)
            AUTO_SUBNET="true"; shift ;;
        --listen|--listen-addresses)
            PG_LISTEN="${2:-}"; shift 2 ;;
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
Usage: sudo rvdk postgresql/18-6-io_uring [options]

Options:
  --data-mount <path>         NVMe mount root for PGDATA relocation (default: auto /mnt/nvme_data)
  --listen <localhost|ip|*>   PostgreSQL listen_addresses (default: localhost, or '*' if --allow-cidr set)
  --allow-cidr <CIDR>         Grant scram-sha-256 HBA access to IPv4 CIDR (alias: --subnet)
  --auto-subnet               Auto-detect primary NIC IPv4 subnet for --allow-cidr
  --force-build               Compile PostgreSQL 18 from PGDG source with SoC -march/-mtune flags
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

if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/kit.sh" ]]; then
    # shellcheck disable=SC1091
    source "${_REPO_ROOT}/lib/kit.sh"
    _KIT_ARGS=()
    [[ -n "$CLI_SOC" ]] && _KIT_ARGS+=("--soc" "$CLI_SOC")
    [[ -n "$CLI_BOARD" ]] && _KIT_ARGS+=("--board" "$CLI_BOARD")
    rvdk_kit_resolve ${_KIT_ARGS[@]+"${_KIT_ARGS[@]}"}
fi

_PG_TMP_ARCHIVE=""
_PG_BUILD_ACTIVE="false"
BUILD_DIR="/var/lib/rvdk/pgdg-riscv64/build"
_rvdk_pg_cleanup() {
    [[ -n "$_PG_TMP_ARCHIVE" ]] && rm -f "$_PG_TMP_ARCHIVE" "${_PG_TMP_ARCHIVE}.sha256" 2>/dev/null || true
    if [[ "$_PG_BUILD_ACTIVE" == "true" && "$KEEP_BUILD_DIR" != "true" && -d "$BUILD_DIR" ]]; then
        rm -rf "$BUILD_DIR" 2>/dev/null || true
    fi
}
trap '_rvdk_pg_cleanup' EXIT INT TERM

rvdk_prog_init "PG 18.6: detecting RISC-V silicon profile..."

# 1. Resolve Silicon Target, ISA Flags & RAM-Aware Sv39 Profile
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

case "$RESOLVED_SOC" in
    eswin/eic7700x)
        TARGET_SLUG="sifive-p550"
        CPU_MTUNE="sifive-p550"
        MARCH_CANDIDATES=("rv64gc_zba_zbb" "rv64gc")
        ;;
    starfive/jh7110)
        TARGET_SLUG="starfive-jh7110"
        CPU_MTUNE="sifive-u74"
        MARCH_CANDIDATES=("rv64gc_zba_zbb" "rv64gc")
        ;;
    sifive/fu740)
        TARGET_SLUG="sifive-fu740"
        CPU_MTUNE="sifive-u74"
        MARCH_CANDIDATES=("rv64gc")
        ;;
    spacemit/k1)
        TARGET_SLUG="spacemit-k1"
        CPU_MTUNE="spacemit-x60"
        MARCH_CANDIDATES=("rv64gcv_zba_zbb_zbc_zbs" "rv64gc_zba_zbb" "rv64gc")
        ;;
    spacemit/k3)
        TARGET_SLUG="spacemit-k3"
        CPU_MTUNE="spacemit-x100"
        MARCH_CANDIDATES=("rva23u64" "rv64gcv_zba_zbb_zbc_zbs" "rv64gc_zba_zbb" "rv64gc")
        ;;
    ultrarisc/dp1000)
        TARGET_SLUG="ultrarisc-dp1000"
        CPU_MTUNE="generic-ooo"
        MARCH_CANDIDATES=("rva22u64" "rv64gc_zba_zbb_zbs" "rv64gc_zba_zbb" "rv64gc")
        ;;
    tenstorrent/atlantis)
        TARGET_SLUG="tenstorrent-atlantis"
        CPU_MTUNE="tt-ascalon-d8"
        MARCH_CANDIDATES=("rva23u64" "rv64gcv_zba_zbb_zbc_zbs" "rv64gc_zba_zbb" "rv64gc")
        ;;
    *)
        log_fatal "Unsupported RISC-V Device Tree / SoC: '${DT_MODEL}' (pass --board <slug> or --soc <vendor/soc>)"
        ;;
esac

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

BUNDLE_URL="${PG_PREBUILT_DEB_URL:-${RVDK_RELEASE_BASE}/postgresql18-6-io_uring-${TARGET_SLUG}.tar.zst}"
LOCAL_REPO_DIR="/var/lib/rvdk/pgdg-riscv64/debs"
LOCAL_LIST="/etc/apt/sources.list.d/rvdk-local-pgdg.list"

update_local_repo() {
    (
        cd "$LOCAL_REPO_DIR"
        dpkg-scanpackages . /dev/null > Packages 2>/dev/null
        gzip -9cn Packages > Packages.gz
    )
    printf 'deb [trusted=yes lang=none] file://%s ./\n' "$LOCAL_REPO_DIR" > "$LOCAL_LIST"
    if rvdk_apt_has_lists; then
        apt-get update \
            -o Dir::Etc::sourcelist="$LOCAL_LIST" \
            -o Dir::Etc::sourceparts="-" \
            -o APT::Get::List-Cleanup="0" -q
    else
        rvdk_apt_update
    fi
}

# 2. Install PostgreSQL 18.6 (Verified Precompiled Bundle -> Verified PGDG Source Fallback)
rvdk_prog 15 "PG 18.6: checking postgresql-${PG_VERSION} package state..."
PACKAGES_CHANGED="false"
if dpkg -s "postgresql-${PG_VERSION}" >/dev/null 2>&1 && [[ "$FORCE_BUILD" == "false" ]]; then
    log_skip "postgresql-${PG_VERSION} is already installed (pass --force-build to recompile)"
else
    mkdir -p "$LOCAL_REPO_DIR"
    rvdk_prog 20 "PG 18.6: verifying repository & archive prerequisites..."
    rvdk_apt_ensure curl ca-certificates zstd dpkg-dev gnupg lsb-release rsync

    if [[ "$FORCE_BUILD" == "false" ]]; then
        if ! compgen -G "${LOCAL_REPO_DIR}/postgresql-${PG_VERSION}_*.deb" >/dev/null 2>&1; then
            rvdk_prog 35 "PG 18.6: pulling ${TARGET_SLUG} io_uring binary bundle..."
            log_info "Pulling precompiled ${TARGET_SLUG} bundle from ${BUNDLE_URL}..."
            _PG_TMP_ARCHIVE="$(mktemp /tmp/rvdk-pg18-bundle.XXXXXX.tar.zst)"
            if curl -fL --retry 3 "$BUNDLE_URL" -o "$_PG_TMP_ARCHIVE"; then
                EXPECTED_BUNDLE_SHA="$(printf '%s' "$BUNDLE_SHA256" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')"
                if [[ -z "$EXPECTED_BUNDLE_SHA" ]]; then
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
        if [[ "$FORCE_BUILD" == "false" ]]; then
            rvdk_prog 50 "PG 18.6: indexing local PGDG repository..."
            update_local_repo
        fi
    fi

    if [[ "$FORCE_BUILD" == "true" ]]; then
        _PG_BUILD_ACTIVE="true"
        rvdk_prog 25 "PG 18.6: preparing verified PGDG source build (${TARGET_SLUG})..."
        log_info "Executing cold source build (--force-build) for ${TARGET_SLUG}..."

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
        chmod 0644 "$TMP_KEY"
        mv -f "$TMP_KEY" "$PGDG_KEY_PATH"
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
        cat <<EOF > "$PGDG_LIST"
deb-src [signed-by=${PGDG_KEY_PATH}] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main ${PG_VERSION}
EOF
        if [[ "${RVDK_NO_APT_UPDATE:-0}" == "1" ]] && rvdk_apt_has_lists; then
            apt-get update \
                -o Dir::Etc::sourcelist="$PGDG_LIST" \
                -o Dir::Etc::sourceparts="-" \
                -o APT::Get::List-Cleanup="0" -q
        else
            apt-get update -q
            rvdk_apt_mark_updated
        fi
        rvdk_apt_ensure debhelper build-essential liburing-dev libzstd-dev liblz4-dev bc time

        SELECTED_MARCH="rv64gc"
        for cand_march in "${MARCH_CANDIDATES[@]}"; do
            if gcc -march="$cand_march" -E -x c /dev/null >/dev/null 2>&1; then
                SELECTED_MARCH="$cand_march"
                break
            fi
        done

        OPT_FLAGS="-O3 -pipe -march=${SELECTED_MARCH}"
        if gcc -march="${SELECTED_MARCH}" -mcpu="${CPU_MTUNE}" -E -x c /dev/null >/dev/null 2>&1; then
            OPT_FLAGS="${OPT_FLAGS} -mcpu=${CPU_MTUNE} -mtune=${CPU_MTUNE}"
        elif gcc -march="${SELECTED_MARCH}" -mtune="${CPU_MTUNE}" -E -x c /dev/null >/dev/null 2>&1; then
            OPT_FLAGS="${OPT_FLAGS} -mtune=${CPU_MTUNE}"
        fi
        log_info "Selected compiler ISA flags: ${OPT_FLAGS}"

        export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
        export DEB_CFLAGS_APPEND="$OPT_FLAGS"
        export DEB_CXXFLAGS_APPEND="$OPT_FLAGS"

        mkdir -p "$BUILD_DIR" && chmod 775 "$BUILD_DIR" && chown -R _apt:root "$BUILD_DIR"
        if ! dpkg -s postgresql-common-dev >/dev/null 2>&1; then
            rvdk_prog 35 "PG 18.6: compiling postgresql-common..."
            rm -rf "${BUILD_DIR:?}"/*
            (
                cd "$BUILD_DIR"
                apt-get build-dep "${APT_FLAGS[@]}" postgresql-common
                apt-get source --compile postgresql-common
                mv -f ./*.deb "$LOCAL_REPO_DIR/"
            )
            update_local_repo
            apt-get install "${APT_FLAGS[@]}" postgresql-common postgresql-common-dev
        fi

        rvdk_prog 45 "PG 18.6: compiling postgresql-${PG_VERSION} (${CPU_MTUNE} + io_uring)..."
        rm -rf "${BUILD_DIR:?}"/*
        (
            cd "$BUILD_DIR"
            apt-get build-dep "${APT_FLAGS[@]}" "postgresql-${PG_VERSION}"
            apt-get source --compile "postgresql-${PG_VERSION}"
            mv -f ./*.deb "$LOCAL_REPO_DIR/"
        )
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
        printf 'kernel.io_uring_disabled = 0\n' > /etc/sysctl.d/89-rvdk-io-uring.conf
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
if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
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
install -d -o postgres -g postgres "$CONF_DIR"

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
    printf '%s\n' "$WANT_PG_CONF" > "$CONF_FILE"
    chown postgres:postgres "$CONF_FILE"
    chmod 0644 "$CONF_FILE"
    CONF_CHANGED="true"
fi

# Query exact HugePages required by PostgreSQL 18 (+3% headroom) when not explicitly overridden
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin/postgres"
if [[ -n "${KERNEL_HUGEPAGES_2MB:-}" ]]; then
    HUGEPAGES_2MB="$KERNEL_HUGEPAGES_2MB"
elif [[ -x "$PG_BIN" ]]; then
    CALC_HP="$(sudo -u postgres "$PG_BIN" -D "/etc/postgresql/${PG_VERSION}/main" -C shared_memory_size_in_huge_pages 2>/dev/null | tr -dc '0-9' || true)"
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
    printf '%s\n' "$WANT_HP_SYSCTL" > "$HP_SYSCTL"
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
        printf '%s\n' "$WANT_HBA_RULE" >> "$HBA_FILE"
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
    printf "%s\n" "$WANT_PG_QOS" > "$PG_QOS_FILE"
    chmod 0644 "$PG_QOS_FILE"
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

ACTIVE_IO="$(sudo -u postgres psql -tAc 'SHOW io_method;' 2>/dev/null | xargs || echo "$IO_METHOD")"
rvdk_prog 100 "PostgreSQL 18.6 (${ACTIVE_IO}) online"
log_ok "PostgreSQL 18.6 online (listen=${PG_LISTEN}, io_method=${ACTIVE_IO}, shared_buffers=${PG_SHARED_BUFFERS})"
