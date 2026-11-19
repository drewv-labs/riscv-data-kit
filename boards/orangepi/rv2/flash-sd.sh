#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Orange Pi RV2 (SpacemiT K1 / Ky X1) MicroSD Image Flasher
# Path: riscv-data-kit/boards/orangepi/rv2/flash-sd.sh
#
# Thin board entrypoint delegating to `lib/flash.sh` using `media.json`
# (labels ext4 rootfs `rvdk_sd_root` for deterministic SD-priority boot).
# ==============================================================================

set -Eeuo pipefail

if [[ -z "${BASH_SOURCE[0]:-}" || ! -f "${BASH_SOURCE[0]}" ]]; then
    printf "\033[1;31m[RVDK:FATAL]\033[0m Board media flashers cannot be piped via stdin.\n" >&2
    printf "  Install the host CLI ('curl -fsSL https://rvdk.drewv-labs.dev/install-cli.sh | bash')\n" >&2
    printf "  and run: rvdk flash orangepi/rv2 sd <disk>\n" >&2
    exit 1
fi

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

exec bash "${_REPO_ROOT}/lib/flash.sh" --board "orangepi/rv2" --medium "sd" "$@"
