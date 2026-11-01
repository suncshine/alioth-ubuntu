#!/bin/bash
# Generate the Debian initramfs for the alioth kernel. RUN INSIDE THE VM.
set -euo pipefail
. "$(dirname "$0")/env.sh"
die() { echo "ERROR: $*" >&2; exit 1; }

for d in dev proc sys; do sudo mount --bind "/$d" "$ROOTFS/$d"; done
trap 'for d in dev proc sys; do sudo umount "$ROOTFS/$d" 2>/dev/null || true; done' EXIT

# MODULES=dep cannot determine the root device inside a chroot (mkinitramfs
# fails with "failed to determine device for /"), so keep MODULES=most.
# MODULES=most also puts qcom_q6v5_pas.ko in the initramfs; the
# remoteproc-fw hook (installed by 02-rootfs.sh) adds adsp/slpi/cdsp.mbn so an
# early probe cannot fail with -ENOENT and leave the DSPs offline.  The rootfs
# still loads qcom_q6v5_pas explicitly after switch_root.
[ -f "$ROOTFS/etc/initramfs-tools/hooks/remoteproc-fw" ] \
  || die "remoteproc firmware hook missing (run 02-rootfs.sh first)"
sudo sed -i 's/^MODULES=.*/MODULES=most/' "$ROOTFS/etc/initramfs-tools/initramfs.conf"
sudo chroot "$ROOTFS" update-initramfs -c -k "$KVER"

# Verify the DSP firmware made it into the initrd.  lsinitramfs understands
# gzip/zstd/uncompressed cpio; if the build host lacks it, the hook is still
# installed and update-initramfs reported success.
INITRD_SRC="$ROOTFS/boot/initrd.img-$KVER"
if command -v lsinitramfs >/dev/null 2>&1; then
  LIST="$(mktemp)"
  lsinitramfs "$INITRD_SRC" > "$LIST"
  grep -q 'lib/firmware/qcom/sm8250/xiaomi/alioth/adsp.mbn' "$LIST" \
    || die "adsp.mbn missing from the initramfs"
  grep -q 'lib/firmware/qcom/sm8250/xiaomi/alioth/slpi.mbn' "$LIST" \
    || die "slpi.mbn missing from the initramfs"
  rm -f "$LIST"
else
  echo "WARN: lsinitramfs not available; skipping initrd firmware check"
fi

# install (not cp): the initrd is root:600, and 04 runs the packer as the
# build user; make it world-readable
sudo install -m644 "$INITRD_SRC" "$INITRD"
echo "OK: initramfs at $INITRD ($(du -h "$INITRD" | cut -f1))"
