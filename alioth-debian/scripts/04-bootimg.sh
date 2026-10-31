#!/bin/bash
# Produce the flashable images: ext4 rootfs + Android boot image. RUN IN THE VM.
set -euo pipefail
. "$(dirname "$0")/env.sh"

# boot kernel blob = Image.gz with DTB appended (same layout as the Kupfer
# reference image — verified by byte-identical round-trip, see tools/bootimg.py)
cat "$OUT/kernel/Image.gz" "$OUT/kernel/sm8250-xiaomi-alioth.dtb" > "$OUT/Image.gz-dtb"

# ABL overlays dtbo/hypervisor nodes onto this DTB and silently refuses images
# without __symbols__ (fastboot says OKAY, kernel never starts).  Kupfer builds
# its DTB with DTC_FLAGS="-@"; the shipped DTB has been checked for the marker.
# NOTE: do not use `grep -q` here — it exits early, strings gets SIGPIPE and
# `set -o pipefail` turns a successful match into a failure.
if ! strings "$OUT/kernel/sm8250-xiaomi-alioth.dtb" | grep __symbols__ >/dev/null; then
  echo "ERROR: DTB has no __symbols__ — ABL will reject the overlay. Rebuild dtbs with DTC_FLAGS=-@." >&2
  exit 1
fi

# rootfs ext4 image (4096-byte blocks: UFS presents 4K logical sectors)
if [ ! -f "$ROOT_IMG" ]; then
  truncate -s "$ROOT_IMG_SIZE" "$ROOT_IMG"
  sudo mkfs.ext4 -F -b 4096 -L alioth "$ROOT_IMG"
fi
sudo mkdir -p "$MNT"
sudo mount -o loop "$ROOT_IMG" "$MNT"
sudo rsync -aHAX --delete "$ROOTFS"/ "$MNT"/
sudo umount "$MNT"

# android boot image, header v0 (matches reference exactly)
pack_boot() {  # <cmdline> <output>
  python3 "$WORK/tools/bootimg.py" pack \
    --kernel "$OUT/Image.gz-dtb" \
    --ramdisk "$INITRD" \
    --cmdline "$1" \
    --output "$2"
}
pack_boot "$CMDLINE" "$BOOT_IMG"
# RAM-only debug image: same kernel/initramfs, stays in the initramfs shell
pack_boot "$CMDLINE_DEBUG" "$BOOT_IMG_DEBUG"

# sparse image for fastboot
command -v img2simg >/dev/null || { echo "img2simg missing: sudo apt install android-sdk-libsparse-utils"; exit 1; }
img2simg "$ROOT_IMG" "$ROOT_IMG_SPARSE"

echo "OK: $BOOT_IMG + $BOOT_IMG_DEBUG + $ROOT_IMG_SPARSE ready (scripts/05-flash.sh on macOS)"
