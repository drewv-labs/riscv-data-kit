#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // StarFive VisionFive 2 (JH7110) SD/eMMC Image Flasher
# Path: riscv-data-kit/boards/starfive/vf2/flash-sd.sh
#
# Thin board entrypoint delegating to `lib/flash.sh` using `media.json`.
# ==============================================================================

set -Eeuo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

exec bash "${_REPO_ROOT}/lib/flash.sh" --board "starfive/vf2" --medium "sd" "$@"
