#!/bin/bash
# Stage kernel artifacts from the prebuilt Kupfer package.
# Runs anywhere (macOS or the Linux VM) — pure tar + copy.
set -euo pipefail
. "$(dirname "$0")/env.sh"

mkdir -p "$OUT/kernel"

[ -f "$KERNEL_PKG" ] || { echo "downloading kernel package..."; curl -L -o "$KERNEL_PKG" "$KERNEL_URL"; }

mkdir -p "$WORK/kernel-pkg"
tar -xf "$KERNEL_PKG" -C "$WORK/kernel-pkg"

cp -v "$WORK/kernel-pkg/boot/Image.gz" "$OUT/kernel/"
cp -v "$WORK/kernel-pkg/boot/dtbs/qcom/sm8250-xiaomi-alioth.dtb" "$OUT/kernel/"
rm -rf "$OUT/kernel/modules"
mkdir -p "$OUT/kernel/modules"
cp -a "$WORK/kernel-pkg/usr/lib/modules/$KVER" "$OUT/kernel/modules/"

echo "OK: kernel artifacts in $OUT/kernel (Image.gz / DTB / modules $KVER)"
