#!/bin/bash
# Assemble the production boot image from an audio/thermal base image.
#
# Pipeline (each step keeps Image.gz, ramdisk and cmdline byte-identical):
#   1. 06-bt-bdaddr.sh   add local-bd-address       (if the base lacks it)
#   2. 09-wifi-mac.sh    add local-mac-address      (if the base lacks it)
#   3. 13-camera-dtb.sh  prune camss port@0/2/4
#   4. 10-splash-mem.sh  reserve the ABL splash framebuffer
#
# The base image is normally out/boot-production-audio.img (thermal kernel +
# audio DTB + BT address).  A base that already carries a step's change is
# accepted and that step is skipped.
#
# The Wi-Fi MAC is device-unique data and is NOT defaulted here.  Provide it
# with --wifi-mac, WIFI_MAC, or a file (default $WORK/private/wifi-mac).
# If the base already has local-mac-address and it differs, the script stops
# instead of silently replacing it.
#
# Usage:
#   14-production-boot.sh [--base IMG] [--wifi-mac MAC] [--bt-bdaddr ADDR]
#                         [--output IMG]
# Default:
#   base   out/boot-production-audio.img
#   output out/boot-production-final.img
#
# This script does NOT flash anything.
set -euo pipefail
. "$(dirname "$0")/env.sh"

BASE_IMG="$OUT/boot-production-audio.img"
OUT_IMG="$OUT/boot-production-final.img"
WIFI_MAC="${WIFI_MAC:-}"
BT_ADDR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base)      BASE_IMG="$2"; shift 2 ;;
    --wifi-mac)  WIFI_MAC="$2"; shift 2 ;;
    --bt-bdaddr) BT_ADDR="$2"; shift 2 ;;
    --output)    OUT_IMG="$2"; shift 2 ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$BASE_IMG" ] || die "base boot image not found: $BASE_IMG"
command -v python3 >/dev/null || die "python3 missing"
command -v dtc >/dev/null || die "dtc missing"
command -v fdtput >/dev/null || die "fdtput missing"
command -v fdtget >/dev/null || die "fdtget missing"

if [ -z "$WIFI_MAC" ] && [ -f "$WORK/private/wifi-mac" ]; then
  WIFI_MAC="$(tr -d '[:space:]' < "$WORK/private/wifi-mac")"
fi
if [ -n "$WIFI_MAC" ] && ! [[ "$WIFI_MAC" =~ ^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$ ]]; then
  die "bad Wi-Fi MAC: $WIFI_MAC"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# DTB inspection helper: split a boot image and print a property from its DTB.
dtb_prop() {  # <boot.img> <node> <prop>
  python3 - "$1" "$TMP/inspect.dtb" <<'PY'
import struct, sys
img, out = sys.argv[1], sys.argv[2]
b = open(img, "rb").read()
ksz, kaddr, rsz, raddr, ssz, saddr, tags, page, hv, _ = struct.unpack_from("<10I", b, 8)
blob = b[page:page + ksz]
off = blob.rfind(b"\xd0\x0d\xfe\xed")
open(out, "wb").write(blob[off:])
PY
  # fdtget -t bx prints "2" rather than "02" on some dtc versions; normalise
  # every byte to two lower-case hex digits before comparing addresses.
  fdtget -t bx "$TMP/inspect.dtb" "$2" "$3" 2>/dev/null \
    | tr ' ' '\n' \
    | while read -r byte; do printf '%02x' "$((0x$byte))"; done
}

BT_NODE="/soc@0/geniqup@9c0000/serial@998000/bluetooth"
WIFI_NODE="/soc@0/pcie@1c00000/pcie@0/wifi@0"

CUR="$(dtb_prop "$BASE_IMG" "$BT_NODE" local-bd-address || true)"
if [ -z "$CUR" ]; then
  [ -n "$BT_ADDR" ] || BT_ADDR="02:12:34:56:78:9A"
  echo "==> base has no local-bd-address; adding $BT_ADDR"
  "$SCRIPTS/06-bt-bdaddr.sh" "$BASE_IMG" "$BT_ADDR" "$TMP/01-bt.img"
  CUR_IMG="$TMP/01-bt.img"
else
  echo "==> base already has local-bd-address [$CUR]"
  [ -z "$BT_ADDR" ] || {
    WANT="$(IFS=:; set -- $BT_ADDR; printf '%s%s%s%s%s%s' "$6" "$5" "$4" "$3" "$2" "$1" | tr 'A-F' 'a-f')"
    [ "$CUR" = "$WANT" ] || die "base local-bd-address [$CUR] != requested $BT_ADDR"
  }
  CUR_IMG="$BASE_IMG"
fi

CUR="$(dtb_prop "$CUR_IMG" "$WIFI_NODE" local-mac-address || true)"
if [ -z "$CUR" ]; then
  [ -n "$WIFI_MAC" ] || die "base has no local-mac-address; pass --wifi-mac or create $WORK/private/wifi-mac"
  echo "==> adding local-mac-address $WIFI_MAC"
  "$SCRIPTS/09-wifi-mac.sh" "$WIFI_MAC" "$CUR_IMG" "$TMP/02-wifi.img"
  CUR_IMG="$TMP/02-wifi.img"
else
  WANT="$(printf '%s' "$WIFI_MAC" | tr -d ':' | tr 'A-F' 'a-f')"
  HAVE="$(printf '%s' "$CUR" | tr 'A-F' 'a-f')"
  echo "==> base already has local-mac-address [$CUR]"
  [ -z "$WANT" ] || [ "$WANT" = "$HAVE" ] || die "base local-mac-address [$CUR] != requested $WIFI_MAC"
fi

echo "==> pruning unused CAMSS ports"
"$SCRIPTS/13-camera-dtb.sh" "$CUR_IMG" "$TMP/03-camera.img"

echo "==> reserving the ABL splash framebuffer"
"$SCRIPTS/10-splash-mem.sh" "$TMP/03-camera.img" "$TMP/04-final.img"

cp "$TMP/04-final.img" "$OUT_IMG"

echo
echo "OK: $OUT_IMG"
python3 - "$BASE_IMG" "$OUT_IMG" <<'PY'
import hashlib, struct, sys
def parts(p):
    b = open(p, "rb").read()
    ksz, kaddr, rsz, raddr, ssz, saddr, tags, page, hv, _ = struct.unpack_from("<10I", b, 8)
    blob = b[page:page + ksz]
    off = blob.rfind(b"\xd0\x0d\xfe\xed")
    roff = (page + ksz + page - 1) // page * page
    cmd = b[64:64 + 512].split(b"\0", 1)[0]
    return {
        "image": hashlib.sha256(b).hexdigest(),
        "image.gz": hashlib.sha256(blob[:off]).hexdigest(),
        "dtb": hashlib.sha256(blob[off:]).hexdigest(),
        "ramdisk": hashlib.sha256(b[roff:roff + rsz]).hexdigest(),
        "cmdline": hashlib.sha256(cmd).hexdigest(),
    }
base, out = parts(sys.argv[1]), parts(sys.argv[2])
for k in ("image.gz", "ramdisk", "cmdline"):
    if base[k] != out[k]:
        raise SystemExit(f"ERROR: {k} changed during production assembly")
print(f"Image.gz {out['image.gz']}")
print(f"DTB      {out['dtb']}")
print(f"ramdisk  {out['ramdisk']}")
print(f"cmdline  {out['cmdline']}")
print(f"image    {out['image']}")
PY
echo "NOT FLASHED. Rollback reference: out/boot-production-camera-splash.img"
