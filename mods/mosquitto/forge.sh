#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Module: Eclipse Mosquitto MQTT Broker (:1883 + Unix Socket)
# Path: riscv-data-kit/mods/mosquitto/forge.sh
#
# Usage:
#   sudo rvdk mods/mosquitto [--port 1883] [--data-mount /mnt/nvme_pgdata] [--noprogbar]
#   curl -fsSL https://rvdk.drewv-labs.dev/mods/mosquitto/forge.sh | sudo bash
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

NODE_ENV="${BRAKERRAK_NODE_ENV:-${REAL_HOME}/.brakerrak/node.env}"
# shellcheck disable=SC1090
[[ -f "$NODE_ENV" ]] && source "$NODE_ENV"

MQTT_PORT="${MQTT_PORT:-1883}"
DATA_MOUNT="${MOUNT_POINT:-/mnt/nvme_pgdata}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)       MQTT_PORT="${2:-1883}"; shift 2 ;;
        --data-mount) DATA_MOUNT="${2:-/mnt/nvme_pgdata}"; shift 2 ;;
        --noprogbar|--no-progbar) export RVDK_NO_PROGBAR="1"; shift ;;
        *) shift ;;
    esac
done

_PROGBAR_CANDIDATE="${RVDK_PROGBAR_LIB:-}"
if [[ -z "$_PROGBAR_CANDIDATE" && -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -f "${_SCRIPT_DIR}/../../lib/progbar.sh" ]] && _PROGBAR_CANDIDATE="${_SCRIPT_DIR}/../../lib/progbar.sh"
fi
if [[ -n "$_PROGBAR_CANDIDATE" && -f "$_PROGBAR_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    source "$_PROGBAR_CANDIDATE"
else
    rvdk_prog_init() { :; }
    rvdk_prog()      { :; }
fi

rvdk_prog_init "Mosquitto MQTT: installing packages..."

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

log_info() { printf "\033[1;36m[RVDK:MQTT]\033[0m %s\n" "$1"; }
log_ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$1"; }
log_skip() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }

rvdk_prog 25 "Mosquitto MQTT: installing mosquitto & clients..."
apt-get update -q
apt-get install "${APT_FLAGS[@]}" mosquitto mosquitto-clients

rvdk_prog 60 "Mosquitto MQTT: staging persistence & socket directories..."
if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    MOSQ_DATA="${DATA_MOUNT}/mosquitto"
else
    MOSQ_DATA="/var/lib/mosquitto"
fi

install -d -m 0750 -o mosquitto -g mosquitto "$MOSQ_DATA" /run/mosquitto

# Mosquitto 2.x disallows duplicate persistence/persistence_location directives.
# Debian package default /etc/mosquitto/mosquitto.conf ships with:
#   persistence true
#   persistence_location /var/lib/mosquitto/
# Comment them out from the root config so drop-ins in conf.d/ take precedence cleanly.
if [[ -f /etc/mosquitto/mosquitto.conf ]]; then
    sed -i -E 's/^[[:space:]]*(persistence(_location)?[[:space:]]+)/# \1/' /etc/mosquitto/mosquitto.conf
fi

MOSQ_CONF="/etc/mosquitto/conf.d/99-rvdk-broker.conf"
WANT_MOSQ_CONF="# DREW-V Labs // RVDK Mosquitto Telemetry Broker
listener ${MQTT_PORT} 0.0.0.0
socket_domain ipv4

# Local Unix Domain Socket for zero-TCP-overhead local Pigeoneer/PigeonCoop pub/sub
listener 0 /run/mosquitto/mosquitto.sock

allow_anonymous true
persistence true
persistence_location ${MOSQ_DATA}/
max_queued_messages 10000
set_tcp_nodelay true
"

rvdk_prog 85 "Mosquitto MQTT: converging listener :${MQTT_PORT} + Unix socket..."
if [[ ! -f "$MOSQ_CONF" ]] || [[ "$(cat "$MOSQ_CONF")" != "$WANT_MOSQ_CONF" ]]; then
    printf "%s" "$WANT_MOSQ_CONF" > "$MOSQ_CONF"
    systemctl enable --now mosquitto
    systemctl restart mosquitto
    log_ok "Converged Mosquitto MQTT on :${MQTT_PORT} & /run/mosquitto/mosquitto.sock (Storage: ${MOSQ_DATA})"
else
    systemctl enable --now mosquitto 2>/dev/null || true
    log_skip "Mosquitto MQTT already converged on :${MQTT_PORT} (${MOSQ_CONF})"
fi

rvdk_prog 100 "Mosquitto MQTT broker converged (:${MQTT_PORT})"
