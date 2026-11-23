#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: Eclipse Mosquitto MQTT Broker (Loopback + Unix Socket)
# Path: riscv-data-kit/mods/mosquitto/forge.sh
#
# Security & Persistence Defaults:
#   • Binds TCP listener to `127.0.0.1:1883` + `/run/mosquitto/mosquitto.sock` by default
#   • Restricts `/run/mosquitto` runtime socket directory to `0750` (`mosquitto:mosquitto`)
#   • Non-loopback `--bind` requires `--mqtt-user` + `--mqtt-password`/`--mqtt-password-file`
#     OR explicit `--allow-anonymous`
#   • Generates PBKDF2-SHA512 Mosquitto hashes without exposing credentials on `argv`
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
if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    if [[ -n "$_REPO_ROOT" && -f "${_REPO_ROOT}/lib/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_REPO_ROOT}/lib/common.sh"
    else
        log_info()  { printf "\033[1;36m[RVDK:MQTT]\033[0m %s\n" "$1"; }
        log_ok()    { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
        log_skip()  { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
        log_warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
        log_fatal() { printf "\033[1;31m[RVDK:FATAL]\033[0m %s\n" "$1" >&2; exit 1; }
        rvdk_log_init() { :; }
        rvdk_require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || log_fatal "Root privileges required."; }
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

rvdk_log_init "RVDK:MQTT"

usage() {
    cat <<'EOF'
Usage: sudo rvdk mods/mosquitto [options]

Options:
  --bind <ip>                 TCP bind address (default: 127.0.0.1)
  --port <port>               TCP port (default: 1883)
  --mqtt-user <user>          Configure PBKDF2-SHA512 password auth for <user>
  --mqtt-password <pass>      Password for --mqtt-user (prefer --mqtt-password-file or MQTT_PASSWORD env)
  --mqtt-password-file <path> Read password for --mqtt-user from file (avoids argv exposure)
  --allow-anonymous           Explicitly permit unauthenticated clients on non-loopback --bind
  --data-mount <path>         Optional NVMe mount root for persistence directory
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
rvdk_resolve_caller
rvdk_load_config_env MQTT_PORT MQTT_BIND MQTT_ALLOW_ANONYMOUS MQTT_USER MQTT_PASSWORD MQTT_PASSWORD_FILE MOUNT_POINT

MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_BIND="${MQTT_BIND:-127.0.0.1}"
MQTT_ALLOW_ANONYMOUS="${MQTT_ALLOW_ANONYMOUS:-}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASSWORD="${MQTT_PASSWORD:-}"
MQTT_PASSWORD_FILE="${MQTT_PASSWORD_FILE:-}"
EXPLICIT_DATA_MOUNT=""

_require_arg() {
    [[ -z "${2:-}" || "${2:-}" == -* ]] && log_fatal "Option '$1' requires an argument."
    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)                             _require_arg "$1" "${2:-}"; MQTT_PORT="$2"; shift 2 ;;
        --bind)                             _require_arg "$1" "${2:-}"; MQTT_BIND="$2"; shift 2 ;;
        --allow-anonymous)                  MQTT_ALLOW_ANONYMOUS="true"; shift ;;
        --mqtt-user)                        _require_arg "$1" "${2:-}"; MQTT_USER="$2"; shift 2 ;;
        --mqtt-password)                    [[ -z "${2:-}" ]] && log_fatal "Option '$1' requires an argument."; MQTT_PASSWORD="$2"; shift 2 ;;
        --mqtt-password-file)               _require_arg "$1" "${2:-}"; MQTT_PASSWORD_FILE="$2"; shift 2 ;;
        --data-mount)                       _require_arg "$1" "${2:-}"; EXPLICIT_DATA_MOUNT="$2"; shift 2 ;;
        --no-apt-update|--skip-apt-update)  export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)           export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)                          usage; exit 0 ;;
        *)                                  log_fatal "Unknown argument: $1 (try --help)" ;;
    esac
done

if [[ -n "$MQTT_PASSWORD_FILE" ]]; then
    [[ -r "$MQTT_PASSWORD_FILE" ]] || log_fatal "Cannot read --mqtt-password-file '${MQTT_PASSWORD_FILE}'."
    MQTT_PASSWORD="$(tr -d '\r\n' < "$MQTT_PASSWORD_FILE")"
fi

DATA_MOUNT="$(rvdk_resolve_data_mount "$EXPLICIT_DATA_MOUNT")"

[[ "$MQTT_PORT" =~ ^[0-9]+$ ]] && (( MQTT_PORT >= 1 && MQTT_PORT <= 65535 )) || log_fatal "Invalid --port '${MQTT_PORT}'."
[[ "$MQTT_BIND" =~ ^[A-Za-z0-9.:_-]+$ ]] || log_fatal "Invalid --bind address '${MQTT_BIND}'."

IS_LOOPBACK="false"
if [[ "$MQTT_BIND" == "127.0.0.1" || "$MQTT_BIND" == "localhost" || "$MQTT_BIND" == "::1" ]]; then
    IS_LOOPBACK="true"
fi

if [[ -n "$MQTT_USER" || -n "$MQTT_PASSWORD" ]]; then
    [[ -n "$MQTT_USER" && -n "$MQTT_PASSWORD" ]] || log_fatal "Both --mqtt-user and --mqtt-password/--mqtt-password-file must be provided together."
    [[ "$MQTT_USER" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --mqtt-user '${MQTT_USER}'."
fi

if [[ "$IS_LOOPBACK" == "false" && -z "$MQTT_USER" && "$MQTT_ALLOW_ANONYMOUS" != "true" ]]; then
    log_fatal "Refusing to expose unauthenticated MQTT broker on '${MQTT_BIND}:${MQTT_PORT}'. Pass --mqtt-user/--mqtt-password-file or explicit --allow-anonymous."
fi

rvdk_prog_init "Mosquitto MQTT: verifying packages..."
rvdk_prog 25 "Mosquitto MQTT: verifying mosquitto & clients..."
MOSQ_PKGS=(mosquitto mosquitto-clients)
if [[ -n "$MQTT_USER" ]] && ! command -v python3 >/dev/null 2>&1; then
    MOSQ_PKGS+=(python3-minimal)
fi
rvdk_apt_ensure "${MOSQ_PKGS[@]}"

rvdk_prog 55 "Mosquitto MQTT: staging persistence, runtime dir & auth..."
if [[ -n "$DATA_MOUNT" ]] && mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    MOSQ_DATA="${DATA_MOUNT}/mosquitto"
else
    MOSQ_DATA="/var/lib/mosquitto"
fi

id -u mosquitto >/dev/null 2>&1 || log_fatal "System user 'mosquitto' is missing after package installation."
MOSQ_USER="mosquitto"

# Grant non-root operator group access to restricted 0750 /run/mosquitto socket directory
SOCK_GROUP="mosquitto"
if [[ -n "${REAL_USER:-}" && "$REAL_USER" != "root" ]] && id -u "$REAL_USER" >/dev/null 2>&1 && getent group mosquitto >/dev/null 2>&1; then
    if ! id -nG "$REAL_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "mosquitto"; then
        usermod -aG mosquitto "$REAL_USER" 2>/dev/null || true
    fi
elif [[ -n "${REAL_GRP:-}" && "$REAL_GRP" != "root" ]] && getent group "$REAL_GRP" >/dev/null 2>&1; then
    SOCK_GROUP="$REAL_GRP"
fi

install -d -m 0750 -o "$MOSQ_USER" -g mosquitto "$MOSQ_DATA"
install -d -m 0750 -o "$MOSQ_USER" -g "$SOCK_GROUP" /var/log/mosquitto
install -d -m 0750 -o "$MOSQ_USER" -g "$SOCK_GROUP" /run/mosquitto

# Persist /run/mosquitto & /var/log/mosquitto across reboots with restricted 0750 mode.
# Explicitly set User=mosquitto and clear legacy root-only ExecStartPre= hooks (Ubuntu 24.04
# omits User= in /usr/lib/systemd/system/mosquitto.service, which otherwise causes systemd's
# RuntimeDirectory= setup to chown /run/mosquitto to root:mosquitto 0750 right before ExecStart
# and trigger EACCES on /run/mosquitto/mosquitto.sock after drop_privileges()).
MOSQ_DROPIN_DIR="/etc/systemd/system/mosquitto.service.d"
MOSQ_DROPIN_FILE="${MOSQ_DROPIN_DIR}/90-rvdk-runtime.conf"
WANT_DROPIN="[Service]
User=${MOSQ_USER}
Group=${SOCK_GROUP}
SupplementaryGroups=mosquitto
RuntimeDirectory=mosquitto
RuntimeDirectoryMode=0750
LogsDirectory=mosquitto
LogsDirectoryMode=0750
ExecStartPre="
if (( MQTT_PORT < 1024 )); then
    WANT_DROPIN="${WANT_DROPIN}
AmbientCapabilities=CAP_NET_BIND_SERVICE"
fi

DROPIN_CHANGED="false"
install -d -m 0755 "$MOSQ_DROPIN_DIR"
if ! printf '%s\n' "$WANT_DROPIN" | cmp -s - "$MOSQ_DROPIN_FILE" 2>/dev/null; then
    printf '%s\n' "$WANT_DROPIN" | rvdk_atomic_write "$MOSQ_DROPIN_FILE" 0644
    systemctl daemon-reload
    DROPIN_CHANGED="true"
fi

if [[ -f /etc/mosquitto/mosquitto.conf ]] && grep -Eq '^[[:space:]]*persistence(_location)?[[:space:]]+' /etc/mosquitto/mosquitto.conf 2>/dev/null; then
    sed -E 's/^[[:space:]]*(persistence(_location)?[[:space:]]+)/# \1/' /etc/mosquitto/mosquitto.conf \
        | rvdk_atomic_write /etc/mosquitto/mosquitto.conf 0644
fi

PASSWD_FILE="/etc/mosquitto/passwd"
AUTH_CHANGED="false"
if [[ -n "$MQTT_USER" ]]; then
    # Generate/verify Mosquitto PBKDF2-SHA512 ($7$101$<salt>$<dk>) reading password via env (zero argv exposure)
    WANT_PASSWD_LINE="$(
        _RVDK_MQTT_PW="$MQTT_PASSWORD" python3 - "$PASSWD_FILE" "$MQTT_USER" <<'PY'
import base64, hashlib, hmac, os, secrets, sys

pw_file, user = sys.argv[1], sys.argv[2]
pw = os.environ["_RVDK_MQTT_PW"].encode("utf-8")
iters = 101
salt = None
prev_line = None

if os.path.isfile(pw_file):
    try:
        with open(pw_file, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if line.startswith(user + ":$7$"):
                    parts = line.split("$")
                    if len(parts) == 5:
                        cand_iters = int(parts[2])
                        cand_salt = base64.b64decode(parts[3])
                        cand_dk = base64.b64decode(parts[4])
                        chk = hashlib.pbkdf2_hmac("sha512", pw, cand_salt, cand_iters, 64)
                        if hmac.compare_digest(chk, cand_dk):
                            prev_line = line
                    break
    except Exception:
        pass

if prev_line is not None:
    print(prev_line)
else:
    salt = secrets.token_bytes(12)
    dk = hashlib.pbkdf2_hmac("sha512", pw, salt, iters, 64)
    print(f"{user}:$7${iters}${base64.b64encode(salt).decode()}${base64.b64encode(dk).decode()}")
PY
    )"
    if [[ ! -f "$PASSWD_FILE" ]] || ! printf '%s\n' "$WANT_PASSWD_LINE" | cmp -s - "$PASSWD_FILE" 2>/dev/null; then
        printf '%s\n' "$WANT_PASSWD_LINE" | rvdk_atomic_write "$PASSWD_FILE" 0640 root:mosquitto
        AUTH_CHANGED="true"
    fi
    AUTH_LINES="allow_anonymous false
password_file ${PASSWD_FILE}"
else
    AUTH_LINES="allow_anonymous true"
fi

MOSQ_CONF="/etc/mosquitto/conf.d/99-rvdk-broker.conf"
WANT_MOSQ_CONF="# DREW-V Labs // RVDK Mosquitto Telemetry Broker
per_listener_settings false
listener ${MQTT_PORT} ${MQTT_BIND}

# Local Unix Domain Socket (restricted via 0750 /run/mosquitto + broker auth policy)
listener 0 /run/mosquitto/mosquitto.sock

${AUTH_LINES}
persistence true
persistence_location ${MOSQ_DATA}/
max_queued_messages 10000
set_tcp_nodelay true
"

_activate_mosquitto() {
    local action="$1"
    systemctl enable mosquitto.service >/dev/null 2>&1 || systemctl enable mosquitto >/dev/null 2>&1 || true
    systemctl reset-failed mosquitto.service 2>/dev/null || true
    if ! systemctl "$action" mosquitto.service; then
        if [[ -r /var/log/mosquitto/mosquitto.log ]]; then
            tail -n 25 /var/log/mosquitto/mosquitto.log >&2 || true
        fi
        journalctl -u mosquitto.service -n 25 --no-pager >&2 || true
        log_fatal "mosquitto.service failed during '${action}' (${MQTT_BIND}:${MQTT_PORT})."
    fi
    local _i
    for (( _i=0; _i<20; _i++ )); do
        if systemctl is-active --quiet mosquitto.service && [[ -S /run/mosquitto/mosquitto.sock ]]; then
            return 0
        fi
        sleep 0.1
    done
    if ! systemctl is-active --quiet mosquitto.service; then
        if [[ -r /var/log/mosquitto/mosquitto.log ]]; then
            tail -n 25 /var/log/mosquitto/mosquitto.log >&2 || true
        fi
        journalctl -u mosquitto.service -n 25 --no-pager >&2 || true
        log_fatal "mosquitto.service failed to stay active (${MQTT_BIND}:${MQTT_PORT})."
    fi
}

rvdk_prog 85 "Mosquitto MQTT: converging listener ${MQTT_BIND}:${MQTT_PORT} + Unix socket..."
if [[ "$DROPIN_CHANGED" == "true" || "$AUTH_CHANGED" == "true" || ! -f "$MOSQ_CONF" ]] || ! printf '%s' "$WANT_MOSQ_CONF" | cmp -s - "$MOSQ_CONF" 2>/dev/null; then
    printf "%s" "$WANT_MOSQ_CONF" | rvdk_atomic_write "$MOSQ_CONF" 0644
    _activate_mosquitto restart
    log_ok "Converged Mosquitto MQTT on ${MQTT_BIND}:${MQTT_PORT} & /run/mosquitto/mosquitto.sock (Storage: ${MOSQ_DATA})"
elif ! systemctl is-active --quiet mosquitto.service || [[ ! -S /run/mosquitto/mosquitto.sock ]]; then
    _activate_mosquitto restart
    log_ok "Started Mosquitto MQTT on ${MQTT_BIND}:${MQTT_PORT} & /run/mosquitto/mosquitto.sock (Storage: ${MOSQ_DATA})"
else
    systemctl enable mosquitto.service >/dev/null 2>&1 || systemctl enable mosquitto >/dev/null 2>&1 || true
    log_skip "Mosquitto MQTT already converged on ${MQTT_BIND}:${MQTT_PORT} (${MOSQ_CONF})"
fi

rvdk_prog 100 "Mosquitto MQTT broker converged (${MQTT_BIND}:${MQTT_PORT})"
