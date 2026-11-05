#!/bin/zsh
# ==============================================================================
# DREW-V Labs // StarFive VisionFive 2 (JH7110) macOS SD/eMMC Image Flasher
# Path: riscv-data-kit/starfive/visionfive2/flash-sd.sh
# Description: Unmounts target removable media via diskutil and writes an
#              uncompressed StarFive JH7110 Debian image directly to the macOS
#              raw character device (/dev/rdiskX) with synchronous buffer flush.
#
# Environment:
#   VF2IMG  Path to uncompressed StarFive VisionFive 2 OS image (.img)
#
# Arguments:
#   $1      Numeric macOS disk identifier X for /dev/diskX & /dev/rdiskX
#           (verify target index via `diskutil list` prior to execution)
#
# Usage:
#   diskutil list
#   export VF2IMG="/path/to/starfive-jh7110-VF2-SD.img"
#   ./starfive/visionfive2/flash-sd.sh 4
# ==============================================================================

VF2IMG=$(echo $VF2IMG)

X="$1"
diskutil unmountDisk "/dev/disk${X}"
sudo dd if="$VF2IMG" of=/dev/rdisk${X} bs=1m status=progress
sync
