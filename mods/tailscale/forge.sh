#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: Tailscale Mesh VPN & Tailscale SSH (riscv64 Native)
# Path: riscv-data-kit/mods/tailscale/forge.sh
#
# Description:
#   Pulls and SHA-256 verifies official first-party static riscv64 releases from
#   pkgs.tailscale.com, caches them in /var/cache/rvdk/tailscale, auto-detects
#   kernel CONFIG_TUN (falling back to userspace networking on stripped vendor
#   kernels), and converges tailscaled with trap-guarded secret/temp cleanup.
#
# Usage:
#   sudo rvdk mods/tailscale [--up] [--ssh] [--qr] [--authkey <tskey-...>]
#   sudo rvdk mods/tailscale [--advertise-routes 192.168.1.0/24] [--exit-node]
#   sudo rvdk mods/tailscale [--userspace | --kernel-tun] [--track stable|unstable]
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

# @RVDK_INLINE_LIBS: common apt progbar
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:TAILSCALE]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
        rvdk_sanitize_locale() { export LANG="C.UTF-8" LC_ALL="C.UTF-8"; }
        rvdk_resolve_caller() { REAL_USER="${SUDO_USER:-root}"; REAL_GRP="root"; }
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
if [[ -z "${_RVDK_PROGBAR_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/progbar.sh" ]]; then
        # shellcheck source=lib/progbar.sh
        source "${_REPO_ROOT}/lib/progbar.sh"
    else
        rvdk_prog_init() { :; }
        rvdk_prog()      { :; }
    fi
fi

rvdk_log_init "RVDK:TAILSCALE"

usage() {
    cat <<'EOF'
Usage: sudo rvdk mods/tailscale [options]

Options:
  --up                         Run `tailscale up` after daemon convergence
  --ssh                        Enable Tailscale SSH (`--ssh`)
  --qr                         Display QR login code during `tailscale up`
  --authkey <tskey-...>        Authenticate non-interactively (prefer --authkey-file or TS_AUTHKEY env)
  --authkey-file <path>        Read Tailscale authkey from file (avoids argv exposure)
  --advertise-routes <CIDRs>   Comma-separated IPv4/IPv6 subnet routes to advertise
  --exit-node                  Advertise node as a Tailnet exit node
  --accept-routes              Accept subnet routes advertised by peers
  --hostname <name>            Custom RFC-1123 Tailnet node hostname
  --operator <user>            Grant non-root POSIX user Tailscale operator control
  --kernel-tun | --userspace   Force kernel /dev/net/tun or userspace networking
  --track <stable|unstable>    Tailscale release track (default: stable)
  --port <1..65535>            UDP WireGuard port (default: 41641)
  --force                      Reinstall binaries even if version matches
  --no-apt-update              Skip redundant apt-get update calls
  --noprogbar                  Disable persistent bottom progress bar
  -h, --help                   Show this help message and exit
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

_TS_TMP_EXTRACT=""
_TS_TMP_TGZ=""
_TS_KEY_FILE=""
_rvdk_ts_cleanup() {
    if [[ "${_RVDK_CLEANUP_RUNNING:-0}" != "1" ]]; then
        declare -F _rvdk_cleanup_tmpfiles >/dev/null 2>&1 && _rvdk_cleanup_tmpfiles || true
    fi
    [[ -n "$_TS_KEY_FILE" ]] && rm -f "$_TS_KEY_FILE" 2>/dev/null || true
    [[ -n "$_TS_TMP_TGZ" ]] && rm -f "$_TS_TMP_TGZ" 2>/dev/null || true
    [[ -n "$_TS_TMP_EXTRACT" && -d "$_TS_TMP_EXTRACT" ]] && rm -rf "$_TS_TMP_EXTRACT" 2>/dev/null || true
}
if declare -F rvdk_register_cleanup >/dev/null 2>&1; then
    rvdk_register_cleanup _rvdk_ts_cleanup
elif [[ -z "$(trap -p EXIT 2>/dev/null || true)" ]]; then
    trap '_rvdk_ts_cleanup' EXIT
    trap '_rvdk_ts_cleanup; trap - EXIT INT; kill -INT $$' INT
    trap '_rvdk_ts_cleanup; trap - EXIT TERM; kill -TERM $$' TERM
fi

TRACK="${TAILSCALE_TRACK:-stable}"
TS_PORT="${TAILSCALE_PORT:-41641}"
REQUESTED_TUN="auto"          # auto | kernel | userspace
FORCE_REINSTALL="false"
WANT_UP="false"
TS_AUTHKEY_VAL="${TS_AUTHKEY:-${TAILSCALE_AUTHKEY:-}}"
TS_AUTHKEY_FILE="${TS_AUTHKEY_FILE:-${TAILSCALE_AUTHKEY_FILE:-}}"
TS_SSH="false"
TS_QR="false"
TS_ACCEPT_ROUTES="false"
TS_EXIT_NODE="false"
TS_ADVERTISE_ROUTES=""
TS_HOSTNAME=""
TS_OPERATOR=""

_require_arg() {
    [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."
    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --track)                        _require_arg "$1" "${2:-}"; TRACK="$2"; shift 2 ;;
        --unstable)                     TRACK="unstable"; shift ;;
        --port)                         _require_arg "$1" "${2:-}"; TS_PORT="$2"; shift 2 ;;
        --auto)                         REQUESTED_TUN="auto"; shift ;;
        --kernel-tun|--kernel)          REQUESTED_TUN="kernel"; shift ;;
        --userspace|--userspace-net)    REQUESTED_TUN="userspace"; shift ;;
        --force|--upgrade|--reinstall)  FORCE_REINSTALL="true"; shift ;;
        --up|--login)                   WANT_UP="true"; shift ;;
        --authkey|--auth-key)           _require_arg "$1" "${2:-}"; TS_AUTHKEY_VAL="$2"; WANT_UP="true"; shift 2 ;;
        --authkey-file|--auth-key-file) _require_arg "$1" "${2:-}"; TS_AUTHKEY_FILE="$2"; WANT_UP="true"; shift 2 ;;
        --ssh)                          TS_SSH="true"; WANT_UP="true"; shift ;;
        --qr)                           TS_QR="true"; WANT_UP="true"; shift ;;
        --accept-routes)                TS_ACCEPT_ROUTES="true"; WANT_UP="true"; shift ;;
        --advertise-routes|--routes)    _require_arg "$1" "${2:-}"; TS_ADVERTISE_ROUTES="$2"; WANT_UP="true"; shift 2 ;;
        --exit-node|--advertise-exit-node)
                                        TS_EXIT_NODE="true"; WANT_UP="true"; shift ;;
        --hostname)                     _require_arg "$1" "${2:-}"; TS_HOSTNAME="$2"; shift 2 ;;
        --operator)                     _require_arg "$1" "${2:-}"; TS_OPERATOR="$2"; WANT_UP="true"; shift 2 ;;
        --no-apt-update|--skip-apt-update)
                                        export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)       export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)                      usage; exit 0 ;;
        *)                              log_fatal "Unknown argument: $1 (try --help)" ;;
    esac
done

if [[ -n "$TS_AUTHKEY_FILE" ]]; then
    [[ -L "$TS_AUTHKEY_FILE" ]] && log_fatal "--authkey-file '${TS_AUTHKEY_FILE}' must not be a symlink."
    [[ -f "$TS_AUTHKEY_FILE" && -r "$TS_AUTHKEY_FILE" ]] || log_fatal "Cannot read --authkey-file '${TS_AUTHKEY_FILE}'."
    TS_AUTHKEY_VAL="$(tr -d '\r\n' < "$TS_AUTHKEY_FILE")"
    TS_AUTHKEY_VAL="${TS_AUTHKEY_VAL#"${TS_AUTHKEY_VAL%%[![:space:]]*}"}"
    TS_AUTHKEY_VAL="${TS_AUTHKEY_VAL%"${TS_AUTHKEY_VAL##*[![:space:]]}"}"
    [[ -n "$TS_AUTHKEY_VAL" ]] || log_fatal "--authkey-file '${TS_AUTHKEY_FILE}' is empty."
fi

[[ -n "$TS_AUTHKEY_VAL" ]] && WANT_UP="true"

case "$TRACK" in
    stable|unstable) ;;
    *) log_fatal "Unknown Tailscale track '${TRACK}' (expected: stable | unstable)" ;;
esac
if [[ ! "$TS_PORT" =~ ^[0-9]+$ ]] || (( TS_PORT < 1 || TS_PORT > 65535 )); then
    log_fatal "Invalid --port '${TS_PORT}'."
fi
if [[ -n "$TS_HOSTNAME" ]] && ! rvdk_validate_hostname "$TS_HOSTNAME"; then
    log_fatal "Invalid --hostname '${TS_HOSTNAME}'."
fi
if [[ -n "$TS_OPERATOR" ]] && ! rvdk_validate_username "$TS_OPERATOR"; then
    log_fatal "Invalid --operator username '${TS_OPERATOR}'."
fi
if [[ -n "$TS_ADVERTISE_ROUTES" ]]; then
    IFS=',' read -r -a _route_items <<< "$TS_ADVERTISE_ROUTES"
    for _r in "${_route_items[@]}"; do
        if [[ "$_r" == *:* ]]; then
            [[ "$_r" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]] || log_fatal "Invalid IPv6 route CIDR '${_r}'."
        else
            rvdk_validate_cidr "$_r" || log_fatal "Invalid IPv4 route CIDR '${_r}'."
        fi
    done
fi

rvdk_prog_init "Tailscale: checking architecture & prerequisites..."

UNAME_M="$(uname -m)"
case "$UNAME_M" in
    riscv64)        TARBALL_ARCH="riscv64" ;;
    x86_64|amd64)   TARBALL_ARCH="amd64" ;;
    aarch64|arm64)  TARBALL_ARCH="arm64" ;;
    armv7l|armv6l)  TARBALL_ARCH="arm" ;;
    *)              log_fatal "Unsupported CPU architecture for Tailscale: ${UNAME_M}" ;;
esac

# 1. Ensure curl, jq, ca-certificates, iproute2, and ethtool are present
NEED_PKGS=()
for cmd_pkg in "curl:curl" "jq:jq" "ip:iproute2" "ethtool:ethtool"; do
    cmd_name="${cmd_pkg%%:*}"
    pkg_name="${cmd_pkg##*:}"
    if ! command -v "$cmd_name" >/dev/null 2>&1; then
        NEED_PKGS+=("$pkg_name")
    fi
done
if [[ ! -d /etc/ssl/certs ]]; then
    NEED_PKGS+=("ca-certificates")
fi
if [[ ${#NEED_PKGS[@]} -gt 0 ]] && command -v apt-get >/dev/null 2>&1; then
    rvdk_prog 10 "Tailscale: installing ${NEED_PKGS[*]}..."
    rvdk_apt_ensure "${NEED_PKGS[@]}"
fi

# 2. Query Latest Official Tailscale Release Metadata
rvdk_prog 20 "Tailscale: querying ${TRACK} ${TARBALL_ARCH} release metadata..."
META_URL="https://pkgs.tailscale.com/${TRACK}/?mode=json&os=linux"
META_JSON="$(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$META_URL")" || log_fatal "Failed to query ${META_URL}"

TS_VERSION="$(jq -r '.TarballsVersion // .Version // empty' <<< "$META_JSON")"
TGZ_NAME="$(jq -r ".Tarballs.\"${TARBALL_ARCH}\" // empty" <<< "$META_JSON")"
[[ -z "$TS_VERSION" || -z "$TGZ_NAME" ]] && log_fatal "No ${TARBALL_ARCH} tarball advertised in ${META_URL}"
if [[ "$TGZ_NAME" == */* || "$TGZ_NAME" == *..* || ! "$TGZ_NAME" =~ ^tailscale_[0-9A-Za-z._-]+_(riscv64|amd64|arm64|arm)\.tgz$ ]]; then
    log_fatal "Invalid Tailscale tarball filename '${TGZ_NAME}' advertised by ${META_URL}"
fi

TGZ_URL="https://pkgs.tailscale.com/${TRACK}/${TGZ_NAME}"
SHA_URL="${TGZ_URL}.sha256"

INSTALLED_VER=""
if [[ -x /usr/bin/tailscale ]]; then
    INSTALLED_VER="$(/usr/bin/tailscale version 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
fi

BINARIES_CHANGED="false"
if [[ "$INSTALLED_VER" == "$TS_VERSION" && -x /usr/sbin/tailscaled && -f /etc/systemd/system/tailscaled.service && "$FORCE_REINSTALL" == "false" ]]; then
    log_skip "Tailscale ${TS_VERSION} (${TARBALL_ARCH}) binaries already installed"
else
    BASE_CACHE_DIR="${RVDK_CACHE_DIR:-/var/cache/rvdk}"
    CACHE_DIR="${BASE_CACHE_DIR}/tailscale"
    mkdir -p "$CACHE_DIR"
    chmod 0755 "$BASE_CACHE_DIR" "$CACHE_DIR" 2>/dev/null || true
    CACHED_TGZ="${CACHE_DIR}/${TGZ_NAME}"

    rvdk_prog 30 "Tailscale: fetching SHA-256 digest for ${TGZ_NAME}..."
    EXPECTED_SHA="$(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$SHA_URL" | awk '{print $1}' | tr -dc '0-9a-fA-F' | tr '[:upper:]' '[:lower:]')"
    [[ ${#EXPECTED_SHA} -ne 64 ]] && log_fatal "Invalid SHA-256 digest returned from ${SHA_URL}"

    NEED_DOWNLOAD="true"
    if [[ -f "$CACHED_TGZ" ]]; then
        ACTUAL_CACHED_SHA="$(rvdk_sha256_file "$CACHED_TGZ")"
        if [[ "$ACTUAL_CACHED_SHA" == "$EXPECTED_SHA" ]]; then
            NEED_DOWNLOAD="false"
            log_skip "Using verified RVDK cache artifact: ${CACHED_TGZ}"
        fi
    fi

    if [[ "$NEED_DOWNLOAD" == "true" ]]; then
        rvdk_prog 42 "Tailscale: downloading ${TGZ_NAME} (${TARBALL_ARCH})..."
        log_info "Downloading ${TGZ_URL}..."
        _TS_TMP_TGZ="${CACHED_TGZ}.tmp.$$"
        curl --proto '=https' --tlsv1.2 -fL --retry 3 -o "$_TS_TMP_TGZ" "$TGZ_URL"
        ACTUAL_SHA="$(rvdk_sha256_file "$_TS_TMP_TGZ")"
        if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
            rm -f "$_TS_TMP_TGZ"
            _TS_TMP_TGZ=""
            log_fatal "SHA-256 mismatch for ${TGZ_NAME}: expected ${EXPECTED_SHA}, got ${ACTUAL_SHA}"
        fi
        mv -f "$_TS_TMP_TGZ" "$CACHED_TGZ"
        _TS_TMP_TGZ=""
        chown 0:0 "$CACHED_TGZ" 2>/dev/null || true
        chmod 0644 "$CACHED_TGZ"
        log_ok "Verified SHA-256 (${EXPECTED_SHA:0:16}...) -> ${CACHED_TGZ}"
    fi

    rvdk_prog 60 "Tailscale: installing ${TS_VERSION} binaries & systemd units..."
    _TS_TMP_EXTRACT="$(mktemp -d)"
    tar --no-same-owner --no-same-permissions -xzf "$CACHED_TGZ" -C "$_TS_TMP_EXTRACT"
    PKG_DIR="$(find "$_TS_TMP_EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    if [[ -z "$PKG_DIR" || -L "$PKG_DIR" || ! -d "$PKG_DIR" || ! -f "${PKG_DIR}/tailscale" || -L "${PKG_DIR}/tailscale" || ! -f "${PKG_DIR}/tailscaled" || -L "${PKG_DIR}/tailscaled" || -L "${PKG_DIR}/systemd" ]]; then
        log_fatal "Unexpected or symlinked archive layout inside ${CACHED_TGZ}"
    fi

    install -d -m 0755 /usr/bin /usr/sbin /etc/systemd/system /etc/default
    install -m 0755 -o root -g root "${PKG_DIR}/tailscale" /usr/bin/tailscale
    install -m 0755 -o root -g root "${PKG_DIR}/tailscaled" /usr/sbin/tailscaled
    for unit_name in tailscaled.service tailscale-online.target tailscale-wait-online.service; do
        if [[ -L "${PKG_DIR}/systemd/${unit_name}" ]]; then
            log_fatal "Refusing symlinked systemd unit inside ${CACHED_TGZ}: ${unit_name}"
        fi
        if [[ -f "${PKG_DIR}/systemd/${unit_name}" ]]; then
            install -m 0644 -o root -g root "${PKG_DIR}/systemd/${unit_name}" "/etc/systemd/system/${unit_name}"
        fi
    done
    rm -rf "$_TS_TMP_EXTRACT"
    _TS_TMP_EXTRACT=""
    BINARIES_CHANGED="true"
    log_ok "Installed Tailscale ${TS_VERSION} (${TARBALL_ARCH}) to /usr/bin/tailscale & /usr/sbin/tailscaled"
fi

# 3. Kernel CONFIG_TUN Probe & Automatic Userspace Networking Fallback
rvdk_prog 72 "Tailscale: probing kernel TUN & network offloads..."
ensure_tun_device() {
    modprobe tun 2>/dev/null || true
    if [[ ! -c /dev/net/tun ]] && grep -qw tun /proc/misc 2>/dev/null; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null || true
        chmod 0666 /dev/net/tun 2>/dev/null || true
    fi
    [[ -c /dev/net/tun ]]
}

case "$REQUESTED_TUN" in
    kernel)
        if ! ensure_tun_device; then
            log_fatal "Kernel $(uname -r) lacks CONFIG_TUN (/dev/net/tun unavailable); cannot satisfy --kernel-tun."
        fi
        TUN_MODE="kernel-tun"
        WANT_FLAGS=""
        ;;
    userspace)
        TUN_MODE="userspace-networking"
        WANT_FLAGS="--tun=userspace-networking"
        ;;
    auto)
        if ensure_tun_device; then
            TUN_MODE="kernel-tun"
            WANT_FLAGS=""
        else
            TUN_MODE="userspace-networking"
            WANT_FLAGS="--tun=userspace-networking"
            log_warn "Kernel $(uname -r) lacks CONFIG_TUN; falling back to --tun=userspace-networking"
        fi
        ;;
esac

DEFAULTS_FILE="/etc/default/tailscaled"
WANT_DEFAULTS="# Managed by RVDK (mods/tailscale/forge.sh)
PORT=\"${TS_PORT}\"
FLAGS=\"${WANT_FLAGS}\"
"
DEFAULTS_CHANGED="false"
if ! printf '%s' "$WANT_DEFAULTS" | cmp -s - "$DEFAULTS_FILE" 2>/dev/null; then
    printf '%s' "$WANT_DEFAULTS" | rvdk_atomic_write "$DEFAULTS_FILE" 0644
    DEFAULTS_CHANGED="true"
fi

if [[ -n "$TS_ADVERTISE_ROUTES" || "$TS_EXIT_NODE" == "true" ]]; then
    FWD_SYSCTL="/etc/sysctl.d/90-rvdk-tailscale-forwarding.conf"
    WANT_FWD="net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1"
    if ! printf '%s\n' "$WANT_FWD" | cmp -s - "$FWD_SYSCTL" 2>/dev/null; then
        printf '%s\n' "$WANT_FWD" | rvdk_atomic_write "$FWD_SYSCTL" 0644
        sysctl -p "$FWD_SYSCTL" >/dev/null 2>&1 || true
        log_ok "Enabled IPv4/IPv6 packet forwarding (${FWD_SYSCTL})"
    fi
fi

PRIMARY_NIC="$(ip -o route show to default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)"
if [[ -n "$PRIMARY_NIC" ]] && command -v ethtool >/dev/null 2>&1; then
    ethtool -K "$PRIMARY_NIC" rx-udp-gro-forwarding on rx-gro-list off >/dev/null 2>&1 || true
fi

GRO_UNIT="rvdk-tailscale-gro.service"
GRO_UNIT_FILE="/etc/systemd/system/${GRO_UNIT}"
IP_BIN="$(command -v ip 2>/dev/null || echo ip)"
ETHTOOL_BIN="$(command -v ethtool 2>/dev/null || echo ethtool)"
WANT_GRO_UNIT="# Managed by RVDK (mods/tailscale/forge.sh)
[Unit]
Description=RVDK Tailscale UDP GRO Forwarding Optimization
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'set -- \$(${IP_BIN} -o route show to default 2>/dev/null); while [ \$# -gt 1 ]; do if [ \"\$1\" = \"dev\" ]; then ${ETHTOOL_BIN} -K \"\$2\" rx-udp-gro-forwarding on rx-gro-list off >/dev/null 2>&1 || true; break; fi; shift; done'

[Install]
WantedBy=multi-user.target"

GRO_CHANGED="false"
install -d -m 0755 /etc/systemd/system
if ! printf '%s\n' "$WANT_GRO_UNIT" | cmp -s - "$GRO_UNIT_FILE" 2>/dev/null; then
    printf '%s\n' "$WANT_GRO_UNIT" | rvdk_atomic_write "$GRO_UNIT_FILE" 0644
    systemctl daemon-reload
    GRO_CHANGED="true"
fi
if ! systemctl is-enabled --quiet "$GRO_UNIT" 2>/dev/null; then
    systemctl enable "$GRO_UNIT" >/dev/null 2>&1 || true
    GRO_CHANGED="true"
fi
if [[ "$GRO_CHANGED" == "true" ]]; then
    log_ok "Converged persistent Tailscale GRO offload service (${GRO_UNIT_FILE})"
else
    log_skip "${GRO_UNIT} already converged and enabled"
fi

# 4. Converge tailscaled.service
rvdk_prog 85 "Tailscale: converging tailscaled.service (${TUN_MODE})..."
if [[ "$BINARIES_CHANGED" == "true" ]]; then
    systemctl daemon-reload
fi
systemctl enable tailscaled.service >/dev/null 2>&1 || true

if [[ "$BINARIES_CHANGED" == "true" || "$DEFAULTS_CHANGED" == "true" ]] || ! systemctl is-active --quiet tailscaled.service; then
    systemctl restart tailscaled.service
else
    log_skip "tailscaled.service already active and converged (${TUN_MODE})"
fi

for (( w=0; w<15; w++ )); do
    [[ -S /run/tailscale/tailscaled.sock ]] && break
    sleep 0.4
done

if ! systemctl is-active --quiet tailscaled.service; then
    journalctl -u tailscaled.service -n 25 --no-pager >&2 || true
    log_fatal "tailscaled.service failed to become active"
fi

# 5. Optional Tailnet Enrollment / Flag Application (`tailscale up`)
UP_ARGS=()
[[ "$TS_SSH" == "true" ]]               && UP_ARGS+=("--ssh")
[[ "$TS_QR" == "true" ]]                && UP_ARGS+=("--qr")
[[ "$TS_ACCEPT_ROUTES" == "true" ]]     && UP_ARGS+=("--accept-routes")
[[ -n "$TS_ADVERTISE_ROUTES" ]]         && UP_ARGS+=("--advertise-routes=${TS_ADVERTISE_ROUTES}")
[[ "$TS_EXIT_NODE" == "true" ]]         && UP_ARGS+=("--advertise-exit-node")
[[ -n "$TS_HOSTNAME" ]]                 && UP_ARGS+=("--hostname=${TS_HOSTNAME}")
[[ -n "$TS_OPERATOR" ]]                 && UP_ARGS+=("--operator=${TS_OPERATOR}")

if [[ "$WANT_UP" == "true" ]]; then
    rvdk_prog 92 "Tailscale: running tailscale up..."
    if [[ -n "$TS_AUTHKEY_VAL" ]]; then
        install -d -m 0755 /run/tailscale
        _TS_KEY_FILE="/run/tailscale/.rvdk-authkey.$$"
        (
            umask 077
            printf '%s' "$TS_AUTHKEY_VAL" > "$_TS_KEY_FILE"
        )
        if ! /usr/bin/tailscale up --auth-key="file:${_TS_KEY_FILE}" ${UP_ARGS[@]+"${UP_ARGS[@]}"}; then
            rm -f "$_TS_KEY_FILE"
            _TS_KEY_FILE=""
            log_fatal "tailscale up with authkey failed"
        fi
        rm -f "$_TS_KEY_FILE"
        _TS_KEY_FILE=""
    else
        /usr/bin/tailscale up ${UP_ARGS[@]+"${UP_ARGS[@]}"}
    fi
fi

BACKEND_STATE="$(/usr/bin/tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"' || echo "Unknown")"
TS_IPV4="$(/usr/bin/tailscale ip -4 2>/dev/null | head -n1 || true)"

rvdk_prog 100 "Tailscale ${TS_VERSION} converged (${BACKEND_STATE})"
if [[ "$BACKEND_STATE" == "Running" ]]; then
    log_ok "Tailscale ${TS_VERSION} connected: ${TS_IPV4:-online} (mode: ${TUN_MODE})"
else
    log_ok "Tailscale ${TS_VERSION} daemon active (mode: ${TUN_MODE} | state: ${BACKEND_STATE}) — run 'sudo tailscale up --ssh' to authenticate"
fi
