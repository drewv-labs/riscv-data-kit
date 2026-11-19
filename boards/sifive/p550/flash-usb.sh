#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // SiFive HiFive Premier P550 (EIC7700X) Recovery USB Builder
# Path: riscv-data-kit/boards/sifive/p550/flash-usb.sh
#
# Thin board entrypoint delegating to `lib/flash.sh` using `media.json`.
# ==============================================================================

set -Eeuo pipefail

if [[ -z "${BASH_SOURCE[0]:-}" || ! -f "${BASH_SOURCE[0]}" ]]; then
    printf "\033[1;31m[RVDK:FATAL]\033[0m Board media flashers cannot be piped via stdin.\n" >&2
    printf "  Install the host CLI ('curl -fsSL https://rvdk.drewv-labs.dev/install-cli.sh | bash')\n" >&2
    printf "  and run: rvdk flash sifive/p550 usb <disk>\n" >&2
    exit 1
fi

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_SCRIPT_DIR}/../../.." && pwd)"

exec bash "${_REPO_ROOT}/lib/flash.sh" --board "sifive/p550" --medium "usb" "$@"
