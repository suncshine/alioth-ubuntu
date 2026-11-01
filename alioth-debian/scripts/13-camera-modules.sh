#!/bin/bash
# Build and deploy the alioth camera kernel modules and PipeWire soft-ISP bits.
#
# imx582 (main camera) and dw9800 (VCM) are not in the Kupfer 7.2.0 kernel, so
# they are built as external modules from files/camera/.  This script works
# both on the running phone (default) and against an offline rootfs (--root),
# which lets 02-rootfs.sh include the camera without a device round-trip.
#
# Build mode:
#   --build     compile from files/camera/*.c against KDIR (default: the
#               installed kernel headers).  Falls back to --prebuilt.
#   --prebuilt  install files/camera/prebuilt/$KVER/*.ko (built on the phone
#               with the exact 7.2.0 kernel; MODVERSIONS is disabled).
#   --auto      (default) try --build, fall back to --prebuilt.
#
# The module build is done in a temporary copy, so the tracked source tree is
# never polluted with .o/.ko files.
#
# Usage:
#   sudo ./13-camera-modules.sh                 # live phone, auto mode
#   sudo ./13-camera-modules.sh --prebuilt
#   ./13-camera-modules.sh --root /path/rootfs --prebuilt
#   KDIR=/path/to/kernel/build sudo ./13-camera-modules.sh --build
#
# This script does not install libcamera packages; 02-rootfs.sh does that.
set -euo pipefail
. "$(dirname "$0")/env.sh"

KVER="${KVER:-7.2.0}"
ROOTFS=""
MODE=auto
LOAD=1
CAPTURE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root)      ROOTFS="$2"; shift 2 ;;
    --build)     MODE=build; shift ;;
    --prebuilt)  MODE=prebuilt; shift ;;
    --auto)      MODE=auto; shift ;;
    --no-load)   LOAD=0; shift ;;
    --capture)   CAPTURE=1; shift ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

SRC="$FILES/camera"
PREBUILT="$SRC/prebuilt/$KVER"
[ -f "$SRC/imx582.c" ] && [ -f "$SRC/dw9800.c" ] || die "camera sources missing in $SRC"
[ -f "$SRC/50-softisp.conf" ] || die "soft-ISP drop-in missing: $SRC/50-softisp.conf"

PREFIX="${ROOTFS%/}"                       # "" for the live system
if [ -z "${KDIR:-}" ]; then
  # Prefer the target's own tree; otherwise fall back to a host tree with the
  # same $KVER (the build host and the phone both run 7.2.0).
  KDIR="$PREFIX/lib/modules/$KVER/build"
  if [ ! -d "$KDIR" ] && [ -d "/lib/modules/$KVER/build" ]; then
    KDIR="/lib/modules/$KVER/build"
  fi
fi

# --- 1. pick/compile the modules -------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fixed build path: the kernel embeds source paths in the module, so a random
# mktemp directory makes otherwise identical builds differ byte-for-byte.
BUILD_DIR="${BUILD_DIR:-$OUT/camera-build/$KVER}"
MODDIR=""

have_prebuilt() { [ -f "$PREBUILT/imx582.ko" ] && [ -f "$PREBUILT/dw9800.ko" ]; }

try_build() {
  [ -d "$KDIR" ] || { log "kernel build tree not found: $KDIR"; return 1; }
  command -v make >/dev/null || { log "make not installed"; return 1; }
  # The Kupfer 7.2.0 kernel was built with GCC 16; Ubuntu's default gcc is 15
  # and cannot parse the kernel headers (counted_by attribute).  Prefer gcc-16
  # unless the caller pins CC explicitly.
  local cc="${CC:-}"
  if [ -z "$cc" ] && command -v gcc-16 >/dev/null; then cc=gcc-16; fi
  log "building modules against $KDIR${cc:+ with CC=$cc} (build dir $BUILD_DIR)"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  cp "$SRC/Makefile" "$SRC/imx582.c" "$SRC/dw9800.c" "$BUILD_DIR/"
  if ! make -C "$KDIR" M="$BUILD_DIR" ${cc:+CC="$cc"} modules >"$TMP/build.log" 2>&1; then
    log "module build failed; last lines:"
    tail -20 "$TMP/build.log" >&2 || true
    return 1
  fi
  [ -f "$BUILD_DIR/imx582.ko" ] && [ -f "$BUILD_DIR/dw9800.ko" ] \
    || { log "build produced no .ko"; return 1; }
  MODDIR="$BUILD_DIR"
  return 0
}

use_prebuilt() {
  have_prebuilt || die "no prebuilt modules for $KVER in $PREBUILT (run --build on the phone)"
  log "using prebuilt modules from $PREBUILT"
  MODDIR="$PREBUILT"
}

case "$MODE" in
  build)    try_build || die "cannot build camera modules (KDIR=$KDIR)" ;;
  prebuilt) use_prebuilt ;;
  auto)     try_build || use_prebuilt ;;
esac

for m in imx582 dw9800; do
  [ -f "$MODDIR/$m.ko" ] || die "missing $m.ko"
  VER="$(modinfo -F vermagic "$MODDIR/$m.ko" 2>/dev/null | awk '{print $1}')"
  [ "$VER" = "$KVER" ] || die "$m.ko vermagic '$VER' != $KVER"
  log "$m.ko vermagic $VER, sha256 $(sha256sum "$MODDIR/$m.ko" | cut -d' ' -f1)"
done

# --- 2. install modules, autoload config and soft-ISP drop-ins -------------
log "installing into ${ROOTFS:-/}"
install -d "$PREFIX/lib/modules/$KVER/extra"
install -m644 "$MODDIR/imx582.ko" "$MODDIR/dw9800.ko" "$PREFIX/lib/modules/$KVER/extra/"
install -d "$PREFIX/etc/modules-load.d"
printf 'imx582\ndw9800\n' > "$PREFIX/etc/modules-load.d/camera.conf"
install -d "$PREFIX/etc/systemd/user/pipewire.service.d" \
           "$PREFIX/etc/systemd/user/wireplumber.service.d"
install -m644 "$SRC/50-softisp.conf" "$PREFIX/etc/systemd/user/pipewire.service.d/50-softisp.conf"
install -m644 "$SRC/50-softisp.conf" "$PREFIX/etc/systemd/user/wireplumber.service.d/50-softisp.conf"

if [ -n "$ROOTFS" ]; then
  command -v depmod >/dev/null || die "depmod missing (install kmod on the build host)"
  depmod -b "$ROOTFS" "$KVER"
  log "rootfs ready: modules + modules-load.d/camera.conf + soft-ISP drop-ins"
  log "first boot will load imx582/dw9800 automatically"
  exit 0
fi

depmod -a "$KVER"
if [ "$LOAD" -eq 1 ]; then
  modprobe imx582 || die "modprobe imx582 failed"
  modprobe dw9800 || die "modprobe dw9800 failed"
  log "loaded: $(lsmod | awk '$1=="imx582"||$1=="dw9800"{printf "%s ",$1}')"
fi

# --- 3. optional live verification ----------------------------------------
for p in libcamera-tools libcamera-ipa libcamera-v4l2 libspa-0.2-libcamera; do
  dpkg -s "$p" >/dev/null 2>&1 || log "WARN: package $p is not installed"
done
if command -v cam >/dev/null; then
  echo "== cam -l =="
  timeout 20 cam -l 2>&1 | sed -n '1,12p' || true
fi
if [ "$CAPTURE" -eq 1 ]; then
  echo "== 1-frame capture =="
  FRAME="$OUT/camera-test-frame.bin"
  timeout 30 cam -c 1 --capture=1 --file="$FRAME" 2>&1 | tail -4 || true
  [ -s "$FRAME" ] && log "frame: $FRAME ($(stat -c%s "$FRAME" 2>/dev/null || stat -f%z "$FRAME") B)"
fi
log "done"
