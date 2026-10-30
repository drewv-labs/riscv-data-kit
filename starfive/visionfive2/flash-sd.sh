#!/bin/zsh
# To flash StarFive Debian on MacOS
VF2IMG=$(echo $VF2IMG)

X="$1"
diskutil unmountDisk "/dev/disk${X}"
sudo dd if="$VF2IMG" of=/dev/rdisk${X} bs=1m status=progress
sync
