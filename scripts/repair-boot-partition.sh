#!/usr/bin/env bash
set -euo pipefail

# Repairs the SD boot partition (/boot, /boot/firmware) from an already-installed
# NVMe system, without touching anything on the NVMe. Use this instead of
# re-running nixos-anywhere whenever the SD card or its bootloader generation is
# the only thing broken.
#
# Run on the target Pi itself (e.g. booted from the bootstrap SD) as root:
#   ssh root@<pi-ip> 'bash -s' < scripts/repair-boot-partition.sh

mkdir -p /mb /mb/nix /mb/persist /mb/boot/firmware
mount -o subvol=@root /dev/nvme0n1p1 /mb
mount -o subvol=@nix /dev/nvme0n1p1 /mb/nix
mount -o subvol=@persist /dev/nvme0n1p1 /mb/persist
mount /dev/mmcblk0p2 /mb/boot
mount /dev/mmcblk0p1 /mb/boot/firmware

closure=$(ls /mb/nix/store/ | grep 'nixos-system-rpi5' | head -1)
echo "Installing bootloader for closure: $closure"
nixos-enter --root /mb -- "/nix/store/$closure/bin/switch-to-configuration" boot

sync
umount /mb/boot/firmware /mb/boot /mb/persist /mb/nix /mb

echo "Done. Reboot to land on the repaired generation."
