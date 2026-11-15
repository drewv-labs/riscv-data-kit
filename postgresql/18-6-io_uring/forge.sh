#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: PostgreSQL 18.6 io_uring (riscv64 + io_uring + Sv39 HugePages)
# Path: riscv-data-kit/postgresql/18-6-io_uring/forge.sh
#
# Usage (Default: Precompiled RVDK Binary Bundle with automatic source fallback):
#   curl -fsSL https://rvdk.drewv-labs.dev/postgresql/18-6-io_uring/forge.sh | sudo bash
#
# Usage (Explicit Cold Source Compile):
#   curl -fsSL https://rvdk.drewv-labs.dev/postgresql/18-6-io_uring/forge.sh | sudo bash -s -- --force-build [--no-apt-update] [--noprogbar]
# ==============================================================================
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    else
        echo "[RVDK:FATAL] Pipe into 'sudo bash': curl -fsSL ... | sudo bash" >&2
        exit 1
    fi
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6 2>/dev/null || eval echo "~${REAL_USER}")"
[[ -z "$REAL_HOME" ]] && REAL_HOME="/root"
ENV_FILE="${RVDK_ENV_FILE:-${REAL_HOME}/.rvdk/config.env}"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

PG_VERSION="18"
FORCE_BUILD="false"
DATA_MOUNT="${MOUNT_POINT:-/mnt/nvme_pgdata}"
LAB_SUBNET="${LAB_SUBNET:-10.0.10.0/24}"
RVDK_RELEASE_BASE="${RVDK_RELEASE_BASE:-https://github.com/drewv-labs/riscv-data-kit/releases/download/rvdk-v1}"
CLI_SOC=""
CLI_BOARD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-build|--force-rebuild-pg|--compile)
            FORCE_BUILD="true"; shift ;;
        --data-mount)
            DATA_MOUNT="$2"; shift 2 ;;
        --subnet)
            LAB_SUBNET="$2"; shift 2 ;;
        --soc)
            CLI_SOC="${2:-}"; shift 2 ;;
        --board)
            CLI_BOARD="${2:-}"; shift 2 ;;
        --no-apt-update|--skip-apt-update)
            export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)
            export RVDK_NO_PROGBAR="1"; shift ;;
        *) shift ;;
    esac
done

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_REPO_ROOT=""
[[ -n "$_SCRIPT_DIR" ]] && _REPO_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"

if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/kit.sh" ]]; then
    # shellcheck disable=SC1091
    source "${_REPO_ROOT}/lib/kit.sh"
    _KIT_ARGS=()
    [[ -n "$CLI_SOC" ]] && _KIT_ARGS+=("--soc" "$CLI_SOC")
    [[ -n "$CLI_BOARD" ]] && _KIT_ARGS+=("--board" "$CLI_BOARD")
    rvdk_kit_resolve ${_KIT_ARGS[@]+"${_KIT_ARGS[@]}"}
fi

_PROGBAR_CANDIDATE="${RVDK_PROGBAR_LIB:-}"
[[ -z "$_PROGBAR_CANDIDATE" && -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]] && _PROGBAR_CANDIDATE="${_REPO_ROOT}/lib/progbar.sh"
if [[ -n "$_PROGBAR_CANDIDATE" && -f "$_PROGBAR_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    source "$_PROGBAR_CANDIDATE"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

_APT_CANDIDATE="${RVDK_APT_LIB:-}"
[[ -z "$_APT_CANDIDATE" && -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/apt.sh" ]] && _APT_CANDIDATE="${_REPO_ROOT}/lib/apt.sh"
if [[ -n "$_APT_CANDIDATE" && -f "$_APT_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    source "$_APT_CANDIDATE"
else
    rvdk_apt_has_lists() { compgen -G "/var/lib/apt/lists/*Packages*" >/dev/null 2>&1; }
    rvdk_apt_mark_updated() {
        export RVDK_NO_APT_UPDATE="1"
        [[ -n "${RVDK_APT_STAMP_FILE:-}" ]] && touch "$RVDK_APT_STAMP_FILE" 2>/dev/null || true
    }
    rvdk_apt_update() {
        if [[ "${RVDK_NO_APT_UPDATE:-0}" == "1" ]] && rvdk_apt_has_lists; then return 0; fi
        apt-get -o Acquire::Check-Valid-Until=false update -q || apt-get update -q
        rvdk_apt_mark_updated
    }
    rvdk_apt_ensure() {
        local m=() p
        for p in "$@"; do dpkg-query -W -f='${Status}\n' "$p" 2>/dev/null | grep -qx "install ok installed" || m+=("$p"); done
        [[ ${#m[@]} -eq 0 ]] && return 0
        rvdk_apt_update
        apt-get install "${APT_FLAGS[@]}" "${m[@]}"
    }
fi

rvdk_prog_init "PG 18.6: detecting RISC-V silicon profile..."

log_info() { printf "\033[1;36m[RVDK:PG18]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }

# 1. Resolve Silicon Target, ISA Flags & RAM-Aware Sv39 HugePages Profile
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
        # Freedom U740 U74 cores implement pure RV64GC (no Zba/Zbb)
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
        echo "[RVDK:FATAL] Unsupported RISC-V Device Tree / SoC: '${DT_MODEL}' (pass --board <slug> or --soc <vendor/soc>)" >&2
        exit 1
        ;;
esac

# Size default Sv39 2MB HugePages & shared_buffers from physical RAM (preserving exact
# 32GB P550 [8GB/4608] and 8GB VF2 [2GB/1152] profiles while protecting 2GB/4GB & 64GB nodes)
MEM_KB="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 8388608)"
MEM_GIB=$(( (MEM_KB + 524288) / 1048576 ))
if (( MEM_GIB >= 48 )); then
    _DEF_HP=9216; _DEF_SB="16GB"; _DEF_EC="48GB"; _DEF_MM="2GB"
elif (( MEM_GIB >= 24 )); then
    _DEF_HP=4608; _DEF_SB="8GB";  _DEF_EC="24GB"; _DEF_MM="2GB"
elif (( MEM_GIB >= 12 )); then
    _DEF_HP=2304; _DEF_SB="4GB";  _DEF_EC="12GB"; _DEF_MM="1GB"
elif (( MEM_GIB >= 6 )); then
    _DEF_HP=1152; _DEF_SB="2GB";  _DEF_EC="6GB";  _DEF_MM="512MB"
elif (( MEM_GIB >= 3 )); then
    _DEF_HP=576;  _DEF_SB="1GB";  _DEF_EC="3GB";  _DEF_MM="256MB"
else
    _DEF_HP=256;  _DEF_SB="512MB"; _DEF_EC="1536MB"; _DEF_MM="128MB"
fi

HUGEPAGES_2MB="${KERNEL_HUGEPAGES_2MB:-$_DEF_HP}"
PG_SHARED_BUFFERS="${PG_SHARED_BUFFERS:-$_DEF_SB}"
PG_EFFECTIVE_CACHE="${PG_EFFECTIVE_CACHE_SIZE:-$_DEF_EC}"
PG_MAINT_MEM="${PG_MAINT_WORK_MEM:-$_DEF_MM}"

BUNDLE_URL="${PG_PREBUILT_DEB_URL:-${RVDK_RELEASE_BASE}/postgresql18-6-io_uring-${TARGET_SLUG}.tar.zst}"
LOCAL_REPO_DIR="/opt/drewv-pgdg-riscv64/debs"
BUILD_DIR="/opt/drewv-pgdg-riscv64/build"
LOCAL_LIST="/etc/apt/sources.list.d/drewv-local-pgdg.list"

# Normalize any existing local PGDG list/index so future `apt update` runs never emit
# repeated `Ign: file:/opt/drewv-pgdg-riscv64/debs ... Translation-en` probes.
if [[ -f "${LOCAL_REPO_DIR}/Packages" && ! -f "${LOCAL_REPO_DIR}/Packages.gz" ]]; then
    gzip -9cn "${LOCAL_REPO_DIR}/Packages" > "${LOCAL_REPO_DIR}/Packages.gz" 2>/dev/null || true
fi
if [[ -f "$LOCAL_LIST" ]] && ! grep -q "lang=none" "$LOCAL_LIST" 2>/dev/null; then
    echo "deb [trusted=yes lang=none] file://${LOCAL_REPO_DIR} ./" > "$LOCAL_LIST"
fi

update_local_repo() {
    (
        cd "$LOCAL_REPO_DIR"
        dpkg-scanpackages . /dev/null > Packages 2>/dev/null
        gzip -9cn Packages > Packages.gz
    )
    echo "deb [trusted=yes lang=none] file://${LOCAL_REPO_DIR} ./" > "$LOCAL_LIST"
    if rvdk_apt_has_lists; then
        # Index only the local .deb repo without re-fetching upstream mirrors
        apt-get update \
            -o Dir::Etc::sourcelist="$LOCAL_LIST" \
            -o Dir::Etc::sourceparts="-" \
            -o APT::Get::List-Cleanup="0" -q
    else
        rvdk_apt_update
    fi
}

# 2. Install PostgreSQL 18.6 (Default: RVDK Precompiled Bundle | Fallback/Explicit: --force-build)
rvdk_prog 15 "PG 18.6: checking postgresql-${PG_VERSION} package state..."
if dpkg -s "postgresql-${PG_VERSION}" >/dev/null 2>&1 && [[ "$FORCE_BUILD" == "false" ]]; then
    log_skip "postgresql-${PG_VERSION} is already installed (pass --force-build to recompile)"
else
    mkdir -p "$LOCAL_REPO_DIR"
    rvdk_prog 20 "PG 18.6: verifying repository & archive prerequisites..."
    rvdk_apt_ensure curl ca-certificates zstd dpkg-dev gnupg lsb-release rsync

    if [[ "$FORCE_BUILD" == "false" ]]; then
        if ! ls "${LOCAL_REPO_DIR}"/postgresql-${PG_VERSION}_*.deb >/dev/null 2>&1; then
            rvdk_prog 35 "PG 18.6: pulling ${TARGET_SLUG} io_uring binary bundle..."
            log_info "Pulling precompiled ${TARGET_SLUG} bundle from ${BUNDLE_URL}..."
            if curl -fL --retry 3 "$BUNDLE_URL" | tar -I zstd -xf - -C "$LOCAL_REPO_DIR"; then
                rm -f "${LOCAL_REPO_DIR}"/*-dbgsym_*.deb
                log_ok "Extracted precompiled PostgreSQL 18.6 bundle to ${LOCAL_REPO_DIR}"
            else
                log_warn "No prebuilt bundle at ${BUNDLE_URL} yet; falling back to on-device source compile (--force-build)..."
                FORCE_BUILD="true"
            fi
        fi
        if [[ "$FORCE_BUILD" == "false" ]]; then
            rvdk_prog 50 "PG 18.6: indexing local PGDG repository..."
            update_local_repo
        fi
    fi

    if [[ "$FORCE_BUILD" == "true" ]]; then
        rvdk_prog 25 "PG 18.6: preparing cold source build (${TARGET_SLUG})..."
        log_info "Executing cold source build (--force-build) for ${TARGET_SLUG}..."
        install -d /usr/share/postgresql-common/pgdg
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
        CODENAME="$(lsb_release -cs 2>/dev/null || (. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}") || echo sid)"
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
deb-src [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main ${PG_VERSION}
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
            rm -rf "${BUILD_DIR:?}"/* && cd "$BUILD_DIR"
            apt-get build-dep "${APT_FLAGS[@]}" postgresql-common
            apt-get source --compile postgresql-common
            mv -f ./*.deb "$LOCAL_REPO_DIR/" && update_local_repo
            apt-get install "${APT_FLAGS[@]}" postgresql-common postgresql-common-dev
        fi

        rvdk_prog 45 "PG 18.6: compiling postgresql-${PG_VERSION} (${CPU_MTUNE} + io_uring)..."
        rm -rf "${BUILD_DIR:?}"/* && cd "$BUILD_DIR"
        apt-get build-dep "${APT_FLAGS[@]}" "postgresql-${PG_VERSION}"
        apt-get source --compile "postgresql-${PG_VERSION}"
        mv -f ./*.deb "$LOCAL_REPO_DIR/"
        rm -f "${LOCAL_REPO_DIR}"/*-dbgsym_*.deb
        update_local_repo
    fi

    rvdk_prog 60 "PG 18.6: installing postgresql-${PG_VERSION} packages..."
    rvdk_apt_update
    apt-get install "${APT_FLAGS[@]}" "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"
    log_ok "Installed PostgreSQL ${PG_VERSION} (${TARGET_SLUG})"
fi

# 3. Configure Sv39 2MB HugePages & Relocate Cluster (if NVMe mount is present)
rvdk_prog 75 "PG 18.6: reserving Sv39 2MB HugePages (${HUGEPAGES_2MB}) & PGDATA..."
PG_GID="$(getent group postgres | cut -d: -f3)"
cat <<EOF > /etc/sysctl.d/90-rvdk-pg18-hugepages.conf
vm.nr_hugepages = ${HUGEPAGES_2MB}
vm.hugetlb_shm_group = ${PG_GID}
EOF
sysctl -p /etc/sysctl.d/90-rvdk-pg18-hugepages.conf >/dev/null 2>&1 || true

if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    TARGET_PGDATA="${DATA_MOUNT}/postgresql/${PG_VERSION}/main"
    if [[ ! -f "${TARGET_PGDATA}/PG_VERSION" ]]; then
        rvdk_prog 82 "PG 18.6: migrating PGDATA cluster to ${TARGET_PGDATA}..."
        systemctl stop postgresql
        install -d -m 0700 -o postgres -g postgres "$TARGET_PGDATA"
        rsync -a "/var/lib/postgresql/${PG_VERSION}/main/" "${TARGET_PGDATA}/"
        log_ok "Migrated PostgreSQL cluster to ${TARGET_PGDATA}"
    fi
else
    TARGET_PGDATA="/var/lib/postgresql/${PG_VERSION}/main"
fi

# 4. Write Drop-In Tuning Config & Restart
rvdk_prog 90 "PG 18.6: applying io_uring tuning & restarting cluster..."
CONF_DIR="/etc/postgresql/${PG_VERSION}/main/conf.d"
install -d -o postgres -g postgres "$CONF_DIR"
cat <<EOF > "${CONF_DIR}/99-rvdk-${TARGET_SLUG}.conf"
data_directory = '${TARGET_PGDATA}'
listen_addresses = '*'
shared_buffers = ${PG_SHARED_BUFFERS}
huge_pages = try
effective_cache_size = ${PG_EFFECTIVE_CACHE}
work_mem = 64MB
maintenance_work_mem = ${PG_MAINT_MEM}
jit = off
max_worker_processes = $(nproc)
max_parallel_workers = $(nproc)
max_parallel_workers_per_gather = $(( $(nproc) > 1 ? $(nproc) - 1 : 0 ))
io_method = io_uring
random_page_cost = 1.1
effective_io_concurrency = 200
wal_compression = zstd
wal_buffers = 64MB
min_wal_size = 2GB
max_wal_size = 16GB
checkpoint_completion_target = 0.9
EOF
chown postgres:postgres "${CONF_DIR}/99-rvdk-${TARGET_SLUG}.conf"

HBA_FILE="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
if [[ -f "$HBA_FILE" ]] && ! grep -q "$LAB_SUBNET" "$HBA_FILE"; then
    echo "host    all             all             ${LAB_SUBNET}            scram-sha-256" >> "$HBA_FILE"
fi

systemctl enable --now postgresql
systemctl restart postgresql
rvdk_prog 100 "PostgreSQL 18.6 (io_uring) online"
log_ok "PostgreSQL 18.6 online (io_method=$(sudo -u postgres psql -tAc 'SHOW io_method;'), shared_buffers=${PG_SHARED_BUFFERS})"
