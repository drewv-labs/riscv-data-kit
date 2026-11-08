#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: PostgreSQL 18.6 (riscv64 + io_uring + Sv39 HugePages)
# Path: riscv-data-kit/postgresql/18-6/forge.sh
#
# Usage (Default: Precompiled RVDK Binary Bundle):
#   curl -fsSL https://rvdk.drewv-labs.dev/postgresql/18-6/forge.sh | sudo bash
#
# Usage (Explicit Cold Source Compile with PMU perf stat Telemetry):
#   curl -fsSL https://rvdk.drewv-labs.dev/postgresql/18-6/forge.sh | sudo bash -s -- --force-build
# ==============================================================================
set -Eeuo pipefail

PG_VERSION="18"
FORCE_BUILD="false"
DATA_MOUNT="${MOUNT_POINT:-/mnt/nvme_pgdata}"
LAB_SUBNET="${LAB_SUBNET:-10.0.10.0/24}"
RVDK_RELEASE_BASE="${RVDK_RELEASE_BASE:-https://github.com/drewv-labs/riscv-data-kit/releases/download/rvdk-v1}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-build|--force-rebuild-pg|--compile)
            FORCE_BUILD="true"; shift ;;
        --data-mount)
            DATA_MOUNT="$2"; shift 2 ;;
        --subnet)
            LAB_SUBNET="$2"; shift 2 ;;
        *) shift ;;
    esac
done

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

log_info() { printf "\033[1;36m[RVDK:PG18]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }

# 1. Auto-Detect Silicon Target & Memory Profile
DT_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "unknown")"
case "$DT_MODEL" in
    *"Premier P550"*|*"EIC7700"*)
        TARGET_SLUG="sifive-p550"
        CPU_MTUNE="sifive-p550"
        HUGEPAGES_2MB="${KERNEL_HUGEPAGES_2MB:-4608}"
        PG_SHARED_BUFFERS="${PG_SHARED_BUFFERS:-8GB}"
        PG_EFFECTIVE_CACHE="${PG_EFFECTIVE_CACHE_SIZE:-24GB}"
        PG_MAINT_MEM="${PG_MAINT_WORK_MEM:-2GB}"
        ;;
    *"VisionFive 2"*|*"JH7110"*)
        TARGET_SLUG="starfive-jh7110"
        CPU_MTUNE="sifive-u74"
        HUGEPAGES_2MB="${KERNEL_HUGEPAGES_2MB:-1152}"
        PG_SHARED_BUFFERS="${PG_SHARED_BUFFERS:-2GB}"
        PG_EFFECTIVE_CACHE="${PG_EFFECTIVE_CACHE_SIZE:-6GB}"
        PG_MAINT_MEM="${PG_MAINT_WORK_MEM:-512MB}"
        ;;
    *)
        echo "[FATAL] Unsupported RISC-V Device Tree: ${DT_MODEL}" >&2
        exit 1
        ;;
esac

BUNDLE_URL="${PG_PREBUILT_DEB_URL:-${RVDK_RELEASE_BASE}/postgresql18-6-io_uring-${TARGET_SLUG}.tar.zst}"
LOCAL_REPO_DIR="/opt/drewv-pgdg-riscv64/debs"
BUILD_DIR="/opt/drewv-pgdg-riscv64/build"
LOCAL_LIST="/etc/apt/sources.list.d/drewv-local-pgdg.list"

update_local_repo() {
    (cd "$LOCAL_REPO_DIR" && dpkg-scanpackages . /dev/null > Packages 2>/dev/null)
    echo "deb [trusted=yes] file://${LOCAL_REPO_DIR} ./" > "$LOCAL_LIST"
    apt-get update -o Acquire::GzipIndexes=false -q
}

# 2. Install PostgreSQL 18.6 (Default: RVDK Precompiled Bundle | Optional: --force-build)
if dpkg -s "postgresql-${PG_VERSION}" >/dev/null 2>&1 && [[ "$FORCE_BUILD" == "false" ]]; then
    log_skip "postgresql-${PG_VERSION} is already installed (pass --force-build to recompile)"
else
    mkdir -p "$LOCAL_REPO_DIR"
    apt-get update -q
    apt-get install "${APT_FLAGS[@]}" curl ca-certificates zstd dpkg-dev gnupg lsb-release rsync

    if [[ "$FORCE_BUILD" == "false" ]]; then
        if ! ls "${LOCAL_REPO_DIR}"/postgresql-${PG_VERSION}_*.deb >/dev/null 2>&1; then
            log_info "Pulling precompiled ${TARGET_SLUG} bundle from ${BUNDLE_URL}..."
            curl -fL --retry 3 "$BUNDLE_URL" | tar -I zstd -xf - -C "$LOCAL_REPO_DIR"
            rm -f "${LOCAL_REPO_DIR}"/*-dbgsym_*.deb
            log_ok "Extracted precompiled PostgreSQL 18.6 bundle to ${LOCAL_REPO_DIR}"
        fi
        update_local_repo
    else
        log_info "Executing cold source build (--force-build) for ${TARGET_SLUG}..."
        install -d /usr/share/postgresql-common/pgdg
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
        CODENAME="$(lsb_release -cs 2>/dev/null || echo sid)"
        [[ "$CODENAME" =~ ^(forky|trixie|bookworm|n/a|)$ ]] && CODENAME="sid"
        cat <<EOF > /etc/apt/sources.list.d/pgdg.list
deb-src [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main ${PG_VERSION}
EOF
        apt-get update -q
        apt-get install "${APT_FLAGS[@]}" debhelper build-essential liburing-dev libzstd-dev liblz4-dev bc time

        OPT_FLAGS="-O3 -pipe -march=rv64gc_zba_zbb"
        if gcc -march=rv64gc_zba_zbb -mcpu="${CPU_MTUNE}" -E -x c /dev/null >/dev/null 2>&1; then
            OPT_FLAGS="${OPT_FLAGS} -mcpu=${CPU_MTUNE} -mtune=${CPU_MTUNE}"
        fi
        export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
        export DEB_CFLAGS_APPEND="$OPT_FLAGS"
        export DEB_CXXFLAGS_APPEND="$OPT_FLAGS"

        mkdir -p "$BUILD_DIR" && chmod 775 "$BUILD_DIR" && chown -R _apt:root "$BUILD_DIR"
        if ! dpkg -s postgresql-common-dev >/dev/null 2>&1; then
            rm -rf "${BUILD_DIR:?}"/* && cd "$BUILD_DIR"
            apt-get build-dep "${APT_FLAGS[@]}" postgresql-common
            apt-get source --compile postgresql-common
            mv -f ./*.deb "$LOCAL_REPO_DIR/" && update_local_repo
            apt-get install "${APT_FLAGS[@]}" postgresql-common postgresql-common-dev
        fi

        rm -rf "${BUILD_DIR:?}"/* && cd "$BUILD_DIR"
        apt-get build-dep "${APT_FLAGS[@]}" "postgresql-${PG_VERSION}"
        apt-get source --compile "postgresql-${PG_VERSION}"
        mv -f ./*.deb "$LOCAL_REPO_DIR/"
        rm -f "${LOCAL_REPO_DIR}"/*-dbgsym_*.deb
        update_local_repo
    fi

    apt-get install "${APT_FLAGS[@]}" "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"
    log_ok "Installed PostgreSQL ${PG_VERSION} (${TARGET_SLUG})"
fi

# 3. Configure Sv39 2MB HugePages & Relocate Cluster (if NVMe mount is present)
PG_GID="$(getent group postgres | cut -d: -f3)"
cat <<EOF > /etc/sysctl.d/90-rvdk-pg18-hugepages.conf
vm.nr_hugepages = ${HUGEPAGES_2MB}
vm.hugetlb_shm_group = ${PG_GID}
EOF
sysctl -p /etc/sysctl.d/90-rvdk-pg18-hugepages.conf >/dev/null 2>&1 || true

if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    TARGET_PGDATA="${DATA_MOUNT}/postgresql/${PG_VERSION}/main"
    if [[ ! -f "${TARGET_PGDATA}/PG_VERSION" ]]; then
        systemctl stop postgresql
        install -d -m 0700 -o postgres -g postgres "$TARGET_PGDATA"
        rsync -a "/var/lib/postgresql/${PG_VERSION}/main/" "${TARGET_PGDATA}/"
        log_ok "Migrated PostgreSQL cluster to ${TARGET_PGDATA}"
    fi
else
    TARGET_PGDATA="/var/lib/postgresql/${PG_VERSION}/main"
fi

# 4. Write Drop-In Tuning Config & Restart
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
log_ok "PostgreSQL 18.6 online (io_method=$(sudo -u postgres psql -tAc 'SHOW io_method;'), shared_buffers=${PG_SHARED_BUFFERS})"
