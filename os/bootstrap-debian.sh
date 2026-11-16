#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Day-0 Headless Debian Node Bootstrap Wrapper
# Path: riscv-data-kit/os/bootstrap-debian.sh
#
# Thin distro entrypoint delegating to `os/bootstrap-apt.sh --distro debian`.
# ==============================================================================

set -Eeuo pipefail

# @RVDK_WRAPPER_DISTRO: debian
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${_SCRIPT_DIR}/bootstrap-apt.sh" --distro debian "$@"
