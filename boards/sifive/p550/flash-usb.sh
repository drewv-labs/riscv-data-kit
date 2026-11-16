#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // SiFive HiFive Premier P550 (EIC7700X) Recovery USB Builder
# Path: riscv-data-kit/boards/sifive/p550/flash-usb.sh
#
# Thin board entrypoint delegating to `lib/flash.sh` using `media.json`.
# ==============================================================================

set -Eeuo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

exec bash "${_REPO_ROOT}/lib/flash.sh" --board "sifive/p550" --medium "usb" "$@"
