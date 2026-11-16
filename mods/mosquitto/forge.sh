#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: Eclipse Mosquitto MQTT Broker (Loopback + Unix Socket)
# Path: riscv-data-kit/mods/mosquitto/forge.sh
#
# Security & Persistence Defaults:
#   • Binds TCP listener to `127.0.0.1:1883` + `/run/mosquitto/mosquitto.sock` by default
#   • Non-loopback `--bind` requires `--mqtt-user` + `--mqtt-password` OR explicit `--allow-anonymous`
#   • Persists `/run/mosquitto` across reboots via `RuntimeDirectory=mosquitto` drop-in
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

rvdk_log_init "RVDK:MQTT"
rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
rvdk_resolve_caller
rvdk_load_config_env MQTT_PORT MQTT_BIND MQTT_ALLOW_ANONYMOUS MQTT_USER MQTT_PASSWORD MOUNT_POINT

MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_BIND="${MQTT_BIND:-127.0.0.1}"
MQTT_ALLOW_ANONYMOUS="${MQTT_ALLOW_ANONYMOUS:-}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASSWORD="${MQTT_PASSWORD:-}"
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
        --port)                             MQTT_PORT="${2:-1883}"; shift 2 ;;
        --bind)                             MQTT_BIND="${2:-127.0.0.1}"; shift 2 ;;
        --allow-anonymous)                  MQTT_ALLOW_ANONYMOUS="true"; shift ;;
        --mqtt-user)                        MQTT_USER="${2:-}"; shift 2 ;;
        --mqtt-password)                    MQTT_PASSWORD="${2:-}"; shift 2 ;;
        --data-mount)                       DATA_MOUNT="${2:-/mnt/nvme_data}"; shift 2 ;;
        --no-apt-update|--skip-apt-update)  export RVDK_NO_APT_UPDATE="1"; shift ;;
        --noprogbar|--no-progbar)           export RVDK_NO_PROGBAR="1"; shift ;;
        -h|--help)
            cat <<EOF
Usage: sudo rvdk mods/mosquitto [options]

Options:
  --bind <ip>               TCP bind address (default: 127.0.0.1)
  --port <port>             TCP port (default: 1883)
  --mqtt-user <user>        Configure SCRAM/hashed password auth for <user>
  --mqtt-password <pass>    Password for --mqtt-user
  --allow-anonymous         Explicitly permit unauthenticated clients on non-loopback --bind
  --data-mount <path>       Optional NVMe mount root for persistence directory
EOF
            exit 0
            ;;
        *) shift ;;
    esac
done

[[ "$MQTT_PORT" =~ ^[0-9]+$ ]] && (( MQTT_PORT >= 1 && MQTT_PORT <= 65535 )) || log_fatal "Invalid --port '${MQTT_PORT}'."
[[ "$MQTT_BIND" =~ ^[A-Za-z0-9.:_-]+$ ]] || log_fatal "Invalid --bind address '${MQTT_BIND}'."

IS_LOOPBACK="false"
if [[ "$MQTT_BIND" == "127.0.0.1" || "$MQTT_BIND" == "localhost" || "$MQTT_BIND" == "::1" ]]; then
    IS_LOOPBACK="true"
fi

if [[ -n "$MQTT_USER" || -n "$MQTT_PASSWORD" ]]; then
    [[ -n "$MQTT_USER" && -n "$MQTT_PASSWORD" ]] || log_fatal "Both --mqtt-user and --mqtt-password must be provided together."
    [[ "$MQTT_USER" =~ ^[A-Za-z0-9._-]+$ ]] || log_fatal "Invalid --mqtt-user '${MQTT_USER}'."
fi

if [[ "$IS_LOOPBACK" == "false" && -z "$MQTT_USER" && "$MQTT_ALLOW_ANONYMOUS" != "true" ]]; then
    log_fatal "Refusing to expose unauthenticated MQTT broker on '${MQTT_BIND}:${MQTT_PORT}'. Pass --mqtt-user/--mqtt-password or explicit --allow-anonymous."
fi

rvdk_prog_init "Mosquitto MQTT: verifying packages..."
rvdk_prog 25 "Mosquitto MQTT: verifying mosquitto & clients..."
rvdk_apt_ensure mosquitto mosquitto-clients

rvdk_prog 55 "Mosquitto MQTT: staging persistence, runtime dir & auth..."
if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    MOSQ_DATA="${DATA_MOUNT}/mosquitto"
else
    MOSQ_DATA="/var/lib/mosquitto"
fi

install -d -m 0750 -o mosquitto -g mosquitto "$MOSQ_DATA"
install -d -m 0755 -o mosquitto -g mosquitto /run/mosquitto

# Persist /run/mosquitto across reboots via systemd RuntimeDirectory
MOSQ_DROPIN_DIR="/etc/systemd/system/mosquitto.service.d"
MOSQ_DROPIN_FILE="${MOSQ_DROPIN_DIR}/90-rvdk-runtime.conf"
WANT_DROPIN="[Service]
RuntimeDirectory=mosquitto
RuntimeDirectoryMode=0755"

DROPIN_CHANGED="false"
install -d -m 0755 "$MOSQ_DROPIN_DIR"
if ! printf '%s\n' "$WANT_DROPIN" | cmp -s - "$MOSQ_DROPIN_FILE" 2>/dev/null; then
    printf '%s\n' "$WANT_DROPIN" > "$MOSQ_DROPIN_FILE"
    chmod 0644 "$MOSQ_DROPIN_FILE"
    systemctl daemon-reload
    DROPIN_CHANGED="true"
fi

if [[ -f /etc/mosquitto/mosquitto.conf ]]; then
    sed -i -E 's/^[[:space:]]*(persistence(_location)?[[:space:]]+)/# \1/' /etc/mosquitto/mosquitto.conf
fi

PASSWD_FILE="/etc/mosquitto/passwd"
AUTH_CHANGED="false"
if [[ -n "$MQTT_USER" ]]; then
    TMP_PASS="$(mktemp)"
    chmod 0640 "$TMP_PASS"
    mosquitto_passwd -b -c "$TMP_PASS" "$MQTT_USER" "$MQTT_PASSWORD" >/dev/null
    chown root:mosquitto "$TMP_PASS"
    mv -f "$TMP_PASS" "$PASSWD_FILE"
    AUTH_CHANGED="true"
    AUTH_LINES="allow_anonymous false
password_file ${PASSWD_FILE}"
else
    AUTH_LINES="allow_anonymous true"
fi

MOSQ_CONF="/etc/mosquitto/conf.d/99-rvdk-broker.conf"
WANT_MOSQ_CONF="# DREW-V Labs // RVDK Mosquitto Telemetry Broker
listener ${MQTT_PORT} ${MQTT_BIND}

# Local Unix Domain Socket for zero-TCP-overhead local IPC pub/sub
listener 0 /run/mosquitto/mosquitto.sock

${AUTH_LINES}
persistence true
persistence_location ${MOSQ_DATA}/
max_queued_messages 10000
set_tcp_nodelay true
"

rvdk_prog 85 "Mosquitto MQTT: converging listener ${MQTT_BIND}:${MQTT_PORT} + Unix socket..."
if [[ "$DROPIN_CHANGED" == "true" || "$AUTH_CHANGED" == "true" || ! -f "$MOSQ_CONF" ]] || ! printf '%s' "$WANT_MOSQ_CONF" | cmp -s - "$MOSQ_CONF" 2>/dev/null; then
    printf "%s" "$WANT_MOSQ_CONF" > "$MOSQ_CONF"
    chmod 0644 "$MOSQ_CONF"
    systemctl enable --now mosquitto
    systemctl restart mosquitto
    log_ok "Converged Mosquitto MQTT on ${MQTT_BIND}:${MQTT_PORT} & /run/mosquitto/mosquitto.sock (Storage: ${MOSQ_DATA})"
else
    systemctl enable --now mosquitto 2>/dev/null || true
    log_skip "Mosquitto MQTT already converged on ${MQTT_BIND}:${MQTT_PORT} (${MOSQ_CONF})"
fi

rvdk_prog 100 "Mosquitto MQTT broker converged (${MQTT_BIND}:${MQTT_PORT})"
