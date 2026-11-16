#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Day-0 Headless Ubuntu Node Bootstrap Wrapper
# Path: riscv-data-kit/os/bootstrap-ubuntu.sh
#
# Thin distro entrypoint delegating to `os/bootstrap-apt.sh --distro ubuntu`.
# ==============================================================================

set -Eeuo pipefail

# @RVDK_WRAPPER_DISTRO: ubuntu
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${_SCRIPT_DIR}/bootstrap-apt.sh" --distro ubuntu "$@"
