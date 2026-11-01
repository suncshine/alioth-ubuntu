#!/bin/bash
# Build a production boot image from the tracked DTS + kernel config artifact.
#
# Unlike 14-production-boot.sh (which replays the post-processing chain from an
# already-built audio image), this script starts from:
#   * KERNEL_IMG  the locally rebuilt 7.2.0 Image.gz (DEVFREQ_THERMAL=y)
#   * the tracked files/audio/sm8250-xiaomi-alioth-audio.dts DTB, compiled here
#   * INITRD      out/initrd.img produced by 03-initramfs.sh
# then adds the Wi-Fi MAC and the camera-port pruning.
#
# The DTB from the tracked DTS already carries local-bd-address and the splash
# reserved-memory nodes, so 06/10 become no-ops in the downstream chain.  The
# resulting image is functionally identical to boot-production-camera-splash.img;
# DTB node/property ordering can differ (source order vs fdtput insertion order),
# so the SHA256 is not expected to match that historical artifact.
#
# Usage:
#   KSRC=/root/kernel-build/linux ./16-production-boot-source.sh
#   KERNEL_IMG=/path/Image.gz AUDIO_DTB=/path/audio.dtb \
#     WIFI_MAC=aa:bb:cc:dd:ee:ff ./16-production-boot-source.sh
#
# Env:
#   KERNEL_IMG  default out/kernel/Image.gz.thermal, then the phone's
#               /root/kernel-build/linux/arch/arm64/boot/Image.gz
#   AUDIO_DTB   default out/kernel/audio.dtb; built with 07-audio-dtb.sh
#               (DTB_ONLY=1) when missing
#   KSRC        kernel source tree for the DTS preprocessor
#   CPP         preprocessor override (default clang/gcc/cc)
#   INITRD_IMG  initramfs to embed; default out/initrd.img (03-initramfs.sh)
#   WIFI_MAC    device Wi-Fi MAC; default read from private/wifi-mac by 14
#   OUT_IMG     default out/boot-production-final.img
#
# This script does NOT flash anything.
set -euo pipefail
. "$(dirname "$0")/env.sh"

KERNEL_IMG="${KERNEL_IMG:-$OUT/kernel/Image.gz.thermal}"
AUDIO_DTB="${AUDIO_DTB:-$OUT/kernel/audio.dtb}"
INITRD_IMG="${INITRD_IMG:-$INITRD}"
OUT_IMG="${OUT_IMG:-$OUT/boot-production-final.img}"
KSRC="${KSRC:-/tmp/alioth-kernel-check/src}"
if [ ! -d "$KSRC/include/dt-bindings" ] && [ -d "$WORK/kernel-src/include/dt-bindings" ]; then
  KSRC="$WORK/kernel-src"
fi
EXPECTED_KERNEL_SHA="54b4b14a4c533fd6b4cd18c66eb8b0093ce44f9817296ab1239b6ac9748b8292"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

[ -f "$KERNEL_IMG" ] || KERNEL_IMG=/root/kernel-build/linux/arch/arm64/boot/Image.gz
[ -f "$KERNEL_IMG" ] || die "kernel Image.gz not found (set KERNEL_IMG)"
[ -f "$INITRD_IMG" ] || die "initramfs not found: $INITRD_IMG (run 03-initramfs.sh)"
command -v python3 >/dev/null || die "python3 missing"
command -v dtc >/dev/null || die "dtc missing"
command -v fdtget >/dev/null || die "fdtget missing"

KSHA="$(sha256sum "$KERNEL_IMG" | cut -d' ' -f1)"
if [ "$KSHA" != "$EXPECTED_KERNEL_SHA" ]; then
  [ "${ALLOW_OTHER_KERNEL:-0}" = 1 ] \
    || die "unexpected kernel sha256 $KSHA (expected $EXPECTED_KERNEL_SHA; set ALLOW_OTHER_KERNEL=1 to accept)"
  warn "using kernel with non-standard sha256: $KSHA"
fi
log "kernel: $KERNEL_IMG ($KSHA)"

# --- 1. DTB from the tracked DTS (or a prebuilt one) ------------------------
if [ ! -f "$AUDIO_DTB" ]; then
  [ -d "$KSRC/include/dt-bindings" ] \
    || die "AUDIO_DTB missing and KSRC not found (set KSRC or AUDIO_DTB)"
  log "building DTB from files/audio/sm8250-xiaomi-alioth-audio.dts"
  DTB_ONLY=1 DTB_OUT="$AUDIO_DTB" KSRC="$KSRC" ${CPP:+CPP="$CPP"} \
    "$SCRIPTS/07-audio-dtb.sh"
fi
[ -f "$AUDIO_DTB" ] || die "audio DTB not found: $AUDIO_DTB"

fdtget -p "$AUDIO_DTB" /__symbols__ >/dev/null 2>&1 \
  || die "DTB has no __symbols__ — ABL will reject the image"
BT_HEX="$(fdtget -t bx "$AUDIO_DTB" /soc@0/geniqup@9c0000/serial@998000/bluetooth local-bd-address 2>/dev/null \
  | tr ' ' '\n' | while read -r b; do printf '%02x' "$((0x$b))"; done)"
[ "$BT_HEX" = "9a7856341202" ] || die "DTB lost local-bd-address (got '$BT_HEX')"
[ "$(fdtget -t x "$AUDIO_DTB" /reserved-memory/cont_splash_region@9c000000 reg)" = "0 9c000000 0 2300000" ] \
  || die "DTB is missing the cont_splash reserved-memory node"
[ "$(fdtget -t x "$AUDIO_DTB" /reserved-memory/dfps_data_region@9e300000 reg)" = "0 9e300000 0 100000" ] \
  || die "DTB is missing the dfps_data reserved-memory node"
log "DTB: $AUDIO_DTB ($(sha256sum "$AUDIO_DTB" | cut -d' ' -f1))"

# --- 2. pack the base boot image -------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat "$KERNEL_IMG" "$AUDIO_DTB" > "$TMP/Image.gz-dtb"
python3 "$WORK/tools/bootimg.py" pack \
  --kernel "$TMP/Image.gz-dtb" \
  --ramdisk "$INITRD_IMG" \
  --cmdline "$CMDLINE" \
  --output "$TMP/base.img"
log "base image: $(stat -c%s "$TMP/base.img" 2>/dev/null || stat -f%z "$TMP/base.img") B"

# --- 3. Wi-Fi MAC + camera pruning (splash/BT already in the DTS) ----------
ARGS=(--base "$TMP/base.img" --output "$OUT_IMG")
[ -n "${WIFI_MAC:-}" ] && ARGS+=(--wifi-mac "$WIFI_MAC")
"$SCRIPTS/14-production-boot.sh" "${ARGS[@]}"

echo
echo "OK: $OUT_IMG"
echo "source-built DTB ordering differs from the fdtput-built production image;"
echo "the kernel/ramdisk/cmdline and all DT properties are the same."
echo "Flash only after a cold-boot test; keep out/boot-production-camera-splash.img as rollback."
