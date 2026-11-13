#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: Tailscale Mesh VPN & Tailscale SSH (riscv64 Native)
# Path: riscv-data-kit/mods/tailscale/forge.sh
#
# Description:
#   Tailscale's Debian/Ubuntu APT repos do not publish riscv64 .deb packages or
#   Debian sid/Bianbu suites. This module pulls and SHA-256 verifies official
#   first-party static riscv64 releases from pkgs.tailscale.com, caches them in
#   ~/.rvdk/cache/tailscale, auto-detects kernel CONFIG_TUN (falling back to
#   userspace networking on stripped vendor kernels), and converges tailscaled.
#
# Usage:
#   sudo rvdk mods/tailscale [--up] [--ssh] [--qr] [--authkey <tskey-...>] [--no-apt-update] [--noprogbar]
#   sudo rvdk mods/tailscale [--advertise-routes 10.0.10.0/24] [--exit-node]
#   sudo rvdk mods/tailscale [--userspace | --kernel-tun] [--track stable|unstable]
#   curl -fsSL https://rvdk.drewv-labs.dev/mods/tailscale/forge.sh | sudo bash
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

# Sanitize SSH-forwarded LC_* (e.g. ZedBook / macOS SendEnv)
if { locale -a 2>/dev/null || true; } | grep -qiE '^en_US\.utf-?8$'; then
    export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
elif { locale -a 2>/dev/null || true; } | grep -qiE '^C\.utf-?8$'; then
    export LANG="C.UTF-8" LC_ALL="C.UTF-8"
else
    export LANG="C" LC_ALL="C"
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || echo root)}"
REAL_GRP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
REAL_HOME="$(getent passwd "${REAL_USER}" 2>/dev/null | cut -d: -f6 || eval echo "~${REAL_USER}")"
[[ -z "$REAL_HOME" || "$REAL_HOME" == "~"* ]] && REAL_HOME="/root"

TRACK="${TAILSCALE_TRACK:-stable}"
TS_PORT="${TAILSCALE_PORT:-41641}"
REQUESTED_TUN="auto"          # auto | kernel | userspace
FORCE_REINSTALL="false"
WANT_UP="false"
TS_AUTHKEY_VAL="${TS_AUTHKEY:-${TAILSCALE_AUTHKEY:-}}"
TS_SSH="false"
TS_QR="false"
TS_ACCEPT_ROUTES="false"
TS_EXIT_NODE="false"
TS_ADVERTISE_ROUTES=""
TS_HOSTNAME=""
TS_OPERATOR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --track)                        TRACK="${2:-stable}"; shift 2 ;;
        --unstable)                     TRACK="unstable"; shift ;;
        --port)                         TS_PORT="${2:-41641}"; shift 2 ;;
        --auto)                         REQUESTED_TUN="auto"; shift ;;
        --kernel-tun|--kernel)          REQUESTED_TUN="kernel"; shift ;;
        --userspace|--userspace-net)    REQUESTED_TUN="userspace"; shift ;;
        --force|--upgrade|--reinstall)  FORCE_REINSTALL="true"; shift ;;
        --up|--login)                   WANT_UP="true"; shift ;;
        --authkey|--auth-key)           TS_AUTHKEY_VAL="${2:-}"; WANT_UP="true"; shift 2 ;;
        --ssh)                          TS_SSH="true"; WANT_UP="true"; shift ;;
        --qr)                           TS_QR="true"; WANT_UP="true"; shift ;;
        --accept-routes)                TS_ACCEPT_ROUTES="true"; WANT_UP="true"; shift ;;
        --advertise-routes|--routes)    TS_ADVERTISE_ROUTES="${2:-}"; WANT_UP="true"; shift 2 ;;
        --exit-node|--advertise-exit-node)
                                        TS_EXIT_NODE="true"; WANT_UP="true"; shift ;;
        --hostname)                     TS_HOSTNAME="${2:-}"; shift 2 ;;
        --operator)                     TS_OPERATOR="${2:-}"; WANT_UP="true"; shift 2 ;;
        --no-apt-update|--skip-apt-update)
                                        export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)       export RVDK_NO_PROGBAR="1"; shift ;;
        *)                              shift ;;
    esac
done

[[ -n "$TS_AUTHKEY_VAL" ]] && WANT_UP="true"

case "$TRACK" in
    stable|unstable) ;;
    *)
        echo "[RVDK:FATAL] Unknown Tailscale track '${TRACK}' (expected: stable | unstable)" >&2
        exit 1
        ;;
esac

_SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

_PROGBAR_CANDIDATE="${RVDK_PROGBAR_LIB:-}"
[[ -z "$_PROGBAR_CANDIDATE" && -n "$_SCRIPT_DIR" && -f "${_SCRIPT_DIR}/../../lib/progbar.sh" ]] && _PROGBAR_CANDIDATE="${_SCRIPT_DIR}/../../lib/progbar.sh"
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
[[ -z "$_APT_CANDIDATE" && -n "$_SCRIPT_DIR" && -f "${_SCRIPT_DIR}/../../lib/apt.sh" ]] && _APT_CANDIDATE="${_SCRIPT_DIR}/../../lib/apt.sh"
if [[ -n "$_APT_CANDIDATE" && -f "$_APT_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    source "$_APT_CANDIDATE"
else
    rvdk_apt_ensure() {
        local m=() p
        for p in "$@"; do dpkg-query -W -f='${Status}\n' "$p" 2>/dev/null | grep -qx "install ok installed" || m+=("$p"); done
        [[ ${#m[@]} -eq 0 ]] && return 0
        if [[ "${RVDK_NO_APT_UPDATE:-0}" != "1" ]] || ! compgen -G "/var/lib/apt/lists/*Packages*" >/dev/null 2>&1; then
            apt-get -o Acquire::Check-Valid-Until=false update -q || apt-get update -q
            export RVDK_NO_APT_UPDATE="1"
            [[ -n "${RVDK_APT_STAMP_FILE:-}" ]] && touch "$RVDK_APT_STAMP_FILE" 2>/dev/null || true
        fi
        apt-get install "${APT_FLAGS[@]}" "${m[@]}"
    }
fi

rvdk_prog_init "Tailscale: checking architecture & prerequisites..."

log_info()  { printf "\033[1;36m[RVDK:TAILSCALE]\033[0m %s\n" "$1"; }
log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }

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
META_JSON="$(curl -fsSL --retry 3 "$META_URL")" || log_fatal "Failed to query ${META_URL}"

TS_VERSION="$(jq -r '.TarballsVersion // .Version // empty' <<< "$META_JSON")"
TGZ_NAME="$(jq -r ".Tarballs.\"${TARBALL_ARCH}\" // empty" <<< "$META_JSON")"
[[ -z "$TS_VERSION" || -z "$TGZ_NAME" ]] && log_fatal "No ${TARBALL_ARCH} tarball advertised in ${META_URL}"

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
    CACHE_DIR="${REAL_HOME}/.rvdk/cache/tailscale"
    install -d -m 0755 -o "$REAL_USER" -g "$REAL_GRP" "${REAL_HOME}/.rvdk" "${REAL_HOME}/.rvdk/cache" "$CACHE_DIR"
    CACHED_TGZ="${CACHE_DIR}/${TGZ_NAME}"

    rvdk_prog 30 "Tailscale: fetching SHA-256 digest for ${TGZ_NAME}..."
    EXPECTED_SHA="$(curl -fsSL --retry 3 "$SHA_URL" | awk '{print $1}' | tr -dc '0-9a-fA-F' | tr '[:upper:]' '[:lower:]')"
    [[ ${#EXPECTED_SHA} -ne 64 ]] && log_fatal "Invalid SHA-256 digest returned from ${SHA_URL}"

    NEED_DOWNLOAD="true"
    if [[ -f "$CACHED_TGZ" ]]; then
        ACTUAL_CACHED_SHA="$(sha256sum "$CACHED_TGZ" | awk '{print $1}')"
        if [[ "$ACTUAL_CACHED_SHA" == "$EXPECTED_SHA" ]]; then
            NEED_DOWNLOAD="false"
            log_skip "Using verified RVDK cache artifact: ${CACHED_TGZ}"
        fi
    fi

    if [[ "$NEED_DOWNLOAD" == "true" ]]; then
        rvdk_prog 42 "Tailscale: downloading ${TGZ_NAME} (${TARBALL_ARCH})..."
        log_info "Downloading ${TGZ_URL}..."
        TMP_TGZ="${CACHED_TGZ}.tmp.$$"
        curl -fL --retry 3 -o "$TMP_TGZ" "$TGZ_URL"
        ACTUAL_SHA="$(sha256sum "$TMP_TGZ" | awk '{print $1}')"
        if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
            rm -f "$TMP_TGZ"
            log_fatal "SHA-256 mismatch for ${TGZ_NAME}: expected ${EXPECTED_SHA}, got ${ACTUAL_SHA}"
        fi
        mv -f "$TMP_TGZ" "$CACHED_TGZ"
        chown "${REAL_USER}:${REAL_GRP}" "$CACHED_TGZ"
        log_ok "Verified SHA-256 (${EXPECTED_SHA:0:16}...) -> ${CACHED_TGZ}"
    fi

    rvdk_prog 60 "Tailscale: installing ${TS_VERSION} binaries & systemd units..."
    TMP_EXTRACT="$(mktemp -d)"
    tar -xzf "$CACHED_TGZ" -C "$TMP_EXTRACT"
    PKG_DIR="$(find "$TMP_EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    if [[ -z "$PKG_DIR" || ! -f "${PKG_DIR}/tailscale" || ! -f "${PKG_DIR}/tailscaled" ]]; then
        rm -rf "$TMP_EXTRACT"
        log_fatal "Unexpected archive layout inside ${CACHED_TGZ}"
    fi

    install -d -m 0755 /usr/bin /usr/sbin /etc/systemd/system /etc/default
    install -m 0755 "${PKG_DIR}/tailscale" /usr/bin/tailscale
    install -m 0755 "${PKG_DIR}/tailscaled" /usr/sbin/tailscaled
    for unit_name in tailscaled.service tailscale-online.target tailscale-wait-online.service; do
        if [[ -f "${PKG_DIR}/systemd/${unit_name}" ]]; then
            install -m 0644 "${PKG_DIR}/systemd/${unit_name}" "/etc/systemd/system/${unit_name}"
        fi
    done
    rm -rf "$TMP_EXTRACT"
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
    printf '%s' "$WANT_DEFAULTS" > "$DEFAULTS_FILE"
    chmod 0644 "$DEFAULTS_FILE"
    DEFAULTS_CHANGED="true"
fi

# Enable IPv4/IPv6 forwarding if subnet routing or exit-node is requested
if [[ -n "$TS_ADVERTISE_ROUTES" || "$TS_EXIT_NODE" == "true" ]]; then
    FWD_SYSCTL="/etc/sysctl.d/90-rvdk-tailscale-forwarding.conf"
    cat << 'EOF' > "$FWD_SYSCTL"
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p "$FWD_SYSCTL" >/dev/null 2>&1 || true
    log_ok "Enabled IPv4/IPv6 packet forwarding (${FWD_SYSCTL})"
fi

# Best-effort UDP GRO forwarding optimization on primary egress NIC (Linux 6.2+)
PRIMARY_NIC="$(ip -o route show to default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)"
if [[ -n "$PRIMARY_NIC" ]] && command -v ethtool >/dev/null 2>&1; then
    ethtool -K "$PRIMARY_NIC" rx-udp-gro-forwarding on rx-gro-list off >/dev/null 2>&1 || true
fi

# 4. Converge tailscaled.service
rvdk_prog 85 "Tailscale: converging tailscaled.service (${TUN_MODE})..."
systemctl daemon-reload
systemctl enable tailscaled.service >/dev/null 2>&1 || true

if [[ "$BINARIES_CHANGED" == "true" || "$DEFAULTS_CHANGED" == "true" ]] || ! systemctl is-active --quiet tailscaled.service; then
    systemctl restart tailscaled.service
else
    systemctl start tailscaled.service
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
        KEY_FILE="/run/tailscale/.rvdk-authkey.$$"
        (
            umask 077
            printf '%s' "$TS_AUTHKEY_VAL" > "$KEY_FILE"
        )
        /usr/bin/tailscale up --auth-key="file:${KEY_FILE}" ${UP_ARGS[@]+"${UP_ARGS[@]}"} || {
            rm -f "$KEY_FILE"
            log_fatal "tailscale up with authkey failed"
        }
        rm -f "$KEY_FILE"
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
