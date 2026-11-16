#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // ESWIN EIC7700X (SiFive P550 — P550 & Milk-V Megrez) Debian/RockOS BSP
# Path: riscv-data-kit/bsp/eswin/eic7700x/bootstrap-debian.sh
# ==============================================================================
set -Eeuo pipefail
# @RVDK_WRAPPER_FILE: bsp/eswin/eic7700x/bootstrap-ubuntu.sh
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${_DIR}/bootstrap-ubuntu.sh" "$@"
