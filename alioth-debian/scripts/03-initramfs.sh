#!/bin/bash
# Generate the Debian initramfs for the alioth kernel. RUN INSIDE THE VM.
set -euo pipefail
. "$(dirname "$0")/env.sh"

for d in dev proc sys; do sudo mount --bind "/$d" "$ROOTFS/$d"; done
trap 'for d in dev proc sys; do sudo umount "$ROOTFS/$d" 2>/dev/null || true; done' EXIT

# UFS + ext4 are built into the kernel (=y), so the default MODULES=most is a
# safety net, not a requirement — keeps initramfs well under the 192MB boot_b
# limit. (MODULES=dep is unreliable when building in a chroot: root-device
# detection sees the VM's disk, not the phone's UFS.)
sudo chroot "$ROOTFS" update-initramfs -c -k "$KVER"

# install (not cp): the initrd is root:600, and 04 runs the packer as the
# build user; make it world-readable
sudo install -m644 "$ROOTFS/boot/initrd.img-$KVER" "$INITRD"
echo "OK: initramfs at $INITRD ($(du -h "$INITRD" | cut -f1))"
