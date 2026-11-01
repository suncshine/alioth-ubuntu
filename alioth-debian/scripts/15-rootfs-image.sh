#!/bin/bash
# Create the ext4 rootfs image (and optional sparse/gzip variants) from $ROOTFS.
#
# Uses mke2fs -d, so no loop mount or root is required.  This is the same
# filesystem layout as the original 16 GiB alioth userdata image; the device
# resizes it online after flashing if more space is wanted.
#
# Usage: 15-rootfs-image.sh [--recreate] [--size 16G] [--output IMG]
#                           [--sparse] [--no-sparse] [--gzip] [--fsck]
# Defaults:
#   IMG    out/alioth-debian.img
#   size   16G
#   sparse out/alioth-debian-sparse.img when img2simg is available
#
# This script does NOT flash anything.
set -euo pipefail
. "$(dirname "$0")/env.sh"

IMG="$ROOT_IMG"
SIZE="$ROOT_IMG_SIZE"
SPARSE=1
GZIP=0
FSCK=0
RECREATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --recreate)  RECREATE=1; shift ;;
    --size)      SIZE="$2"; shift 2 ;;
    --output)    IMG="$2"; shift 2 ;;
    --sparse)    SPARSE=1; shift ;;
    --no-sparse) SPARSE=0; shift ;;
    --gzip)      GZIP=1; shift ;;
    --fsck)      FSCK=1; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[ -d "$ROOTFS" ] || die "rootfs not found: $ROOTFS (run 02-rootfs.sh)"
[ -f "$ROOTFS/etc/os-release" ] || die "$ROOTFS does not look like a rootfs"
command -v mke2fs >/dev/null || die "mke2fs missing (apt install e2fsprogs)"
command -v truncate >/dev/null || die "truncate missing"

if [ -e "$IMG" ]; then
  [ "$RECREATE" -eq 1 ] || die "$IMG exists (use --recreate to overwrite)"
  rm -f "$IMG"
fi
mkdir -p "$(dirname "$IMG")"
log "creating $SIZE sparse file $IMG"
truncate -s "$SIZE" "$IMG"

log "populating ext4 from $ROOTFS (mke2fs -d)"
mke2fs -q -F -t ext4 -b 4096 -L alioth -d "$ROOTFS" "$IMG"

if [ "$FSCK" -eq 1 ]; then
  log "e2fsck -fn"
  e2fsck -fn "$IMG" || die "e2fsck found errors"
fi

log "image: $IMG ($(du -h "$IMG" | cut -f1) on disk, $SIZE nominal)"

if [ "$SPARSE" -eq 1 ]; then
  SPARSE_IMG="${IMG%.img}-sparse.img"
  if command -v img2simg >/dev/null 2>&1; then
    log "creating sparse image $SPARSE_IMG"
    img2simg "$IMG" "$SPARSE_IMG"
    log "sparse: $SPARSE_IMG ($(du -h "$SPARSE_IMG" | cut -f1))"
  else
    log "img2simg missing; skipping sparse image (apt install android-sdk-libsparse-utils)"
  fi
fi

if [ "$GZIP" -eq 1 ]; then
  log "gzip -1 $IMG (streaming-ready)"
  gzip -1 -c "$IMG" > "$IMG.gz"
  log "gzip: $IMG.gz ($(du -h "$IMG.gz" | cut -f1))"
fi

echo "OK: $IMG"
echo "Flash: see alioth-debian/README.md (initramfs SSH streaming or fastboot)."
