#!/bin/bash
# Add your SSH public key to the rescue initramfs of a released boot image.
#
# The public boot image deliberately contains no authorized_keys.  Run this
# once on your own machine before flashing; it only changes the ramdisk.
#
# Usage:
#   ./17-inject-rescue-key.sh [--boot IMG] [--key KEY.pub] [--output IMG]
#
# Defaults:
#   boot    out/boot-production-final.img
#   key     private/rescue_authorized_keys, then ~/.ssh/id_ed25519.pub,
#           ~/.ssh/id_rsa.pub, ~/.ssh/id_ecdsa.pub
#   output  out/boot-production-rescue.img
#
# This script does NOT flash anything.
set -euo pipefail
. "$(dirname "$0")/env.sh"

BOOT="$OUT/boot-production-final.img"
KEY=""
OUT_IMG="$OUT/boot-production-rescue.img"

while [ $# -gt 0 ]; do
  case "$1" in
    --boot)    BOOT="$2"; shift 2 ;;
    --key)     KEY="$2"; shift 2 ;;
    --output)  OUT_IMG="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$BOOT" ] || die "boot image not found: $BOOT (build it with 16-production-boot-source.sh)"
command -v python3 >/dev/null || die "python3 missing"
if [ -z "$KEY" ]; then
  for k in "$WORK/private/rescue_authorized_keys" \
           "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" \
           "$HOME/.ssh/id_ecdsa.pub"; do
    [ -f "$k" ] && { KEY="$k"; break; }
  done
fi
[ -n "$KEY" ] && [ -f "$KEY" ] || die "no public key found; pass --key ~/.ssh/id_ed25519.pub"

echo "==> boot:   $BOOT"
echo "==> key:    $KEY"
echo "==> output: $OUT_IMG"
python3 "$WORK/tools/inject-initramfs-key.py" \
  --boot "$BOOT" --key "$KEY" --output "$OUT_IMG"
echo "OK: $OUT_IMG"
echo "Flash with: fastboot flash boot_b $OUT_IMG"
