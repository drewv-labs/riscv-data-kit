#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // Day-0 Headless SpacemiT Bianbu OS Bootstrap Wrapper
# Path: riscv-data-kit/os/bootstrap-bianbu.sh
#
# Thin distro entrypoint delegating to `os/bootstrap-apt.sh --distro bianbu`.
# ==============================================================================

set -Eeuo pipefail

# @RVDK_WRAPPER_DISTRO: bianbu
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${_SCRIPT_DIR}/bootstrap-apt.sh" --distro bianbu "$@"
