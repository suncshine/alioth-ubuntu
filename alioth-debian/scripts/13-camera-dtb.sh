#!/bin/bash
# Prune the camera ports whose sensors have no mainline driver from the DTB.
#
# Why: the alioth DTS describes four camera sensors (IMX582 main, S5K5E9 macro,
# IMX355 ultra-wide, S5K3T2 front).  Only imx582/dw9800 are built (see
# files/camera/), so the CAMSS async notifier waits forever for the other
# three CSIPHY endpoints and the whole camera graph never registers.
#
# The fix is a DTB-only change: delete the three unused CAMSS ports
# (port@0/2/4) and their __symbols__ entries, and remove the dangling
# remote-endpoint links from the unused sensor endpoints.  IMX582 on port@1
# is kept untouched.  Image.gz, ramdisk and cmdline are preserved byte-for-byte,
# exactly like 06/09/10.
#
# This is a DTB post-processing step because the kernel/DTB are prebuilt.
# Long term the same pruning belongs in the alioth DTS source.
#
# Idempotent: if the base DTB is already pruned, the image is passed through
# unchanged.
#
# Usage: 13-camera-dtb.sh [base boot.img] [output boot.img]
# Default: out/boot-production-wifimac.img -> out/boot-production-camera.img
#
# This script does NOT flash anything.
set -euo pipefail
. "$(dirname "$0")/env.sh"

BASE_IMG="${1:-$OUT/boot-production-wifimac.img}"
OUT_IMG="${2:-$OUT/boot-production-camera.img}"

CAMSS_PORTS="/soc@0/camss@ac6a000/ports"
# port@n:csiphy endpoint that only exists for the unused sensors
DROP_PORTS=(0 2 4)
DROP_SYMBOLS=(csiphy0_ep csiphy2_ep csiphy4_ep)
# sensor endpoints whose remote-endpoint pointed at the dropped csiphy nodes
DROP_LINKS=(
  "/soc@0/cci@ac4f000/i2c-bus@1/s5k5e9@2d/port/endpoint"
  "/soc@0/cci@ac50000/i2c-bus@0/imx355@1a/port/endpoint"
  "/soc@0/cci@ac50000/i2c-bus@1/s5k3t2@10/port/endpoint"
)

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$BASE_IMG" ] || die "base boot image not found: $BASE_IMG"
command -v dtc    >/dev/null || die "dtc missing (macOS: brew install dtc; Debian: apt install device-tree-compiler)"
command -v fdtput >/dev/null || die "fdtput missing (see dtc above)"
command -v fdtget >/dev/null || die "fdtget missing (see dtc above)"
command -v python3 >/dev/null || die "python3 missing"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. split base image: kernel blob -> Image.gz + appended DTB -------------
python3 - "$BASE_IMG" "$TMP" <<'PY'
import struct, sys
img, tmp = sys.argv[1], sys.argv[2]
b = open(img, "rb").read()
if b[:8] != b"ANDROID!":
    raise SystemExit("not an Android boot image")
(hdr_ver,) = struct.unpack_from("<I", b, 40)
if hdr_ver != 0:
    raise SystemExit(f"expected boot header v0, got v{hdr_ver}")
(ksz, kaddr, rsz, raddr, ssz, saddr, tags, page, _, _) = struct.unpack_from("<10I", b, 8)
if (page, kaddr, raddr, ssz, saddr, tags) != (4096, 0x8000, 0x1000000, 0, 0, 0x100):
    raise SystemExit("unexpected boot header layout")
cmdline = b[64:64 + 512].split(b"\0", 1)[0].decode()
blob = b[page:page + ksz]
roff = (page + ksz + page - 1) // page * page
rs = b[roff:roff + rsz]
off = blob.rfind(b"\xd0\x0d\xfe\xed")
if off < 0:
    raise SystemExit("no appended DTB in kernel blob")
(tot,) = struct.unpack_from(">I", blob, off + 4)
if off + tot != len(blob):
    raise SystemExit(f"DTB totalsize {tot} does not match blob tail {len(blob) - off}")
open(tmp + "/Image.gz", "wb").write(blob[:off])
open(tmp + "/base.dtb", "wb").write(blob[off:])
open(tmp + "/ramdisk", "wb").write(rs)
open(tmp + "/cmdline", "w").write(cmdline)
print(f"base: Image.gz {off} B + DTB {tot} B, ramdisk {rsz} B")
PY

# --- 2. classify the base: already pruned, untouched, or half-edited --------
PORTS="$(fdtget -l "$TMP/base.dtb" "$CAMSS_PORTS")" || die "CAMSS ports node missing: $CAMSS_PORTS"
SYMS="$(fdtget -p "$TMP/base.dtb" /__symbols__)" || die "DTB has no __symbols__; ABL would reject it"

have_ports=0
for p in "${DROP_PORTS[@]}"; do
  printf '%s\n' "$PORTS" | grep -qxF "port@$p" && have_ports=$((have_ports + 1))
done
have_syms=0
for s in "${DROP_SYMBOLS[@]}"; do
  printf '%s\n' "$SYMS" | grep -qxF "$s" && have_syms=$((have_syms + 1))
done
have_links=0
for n in "${DROP_LINKS[@]}"; do
  fdtget -p "$TMP/base.dtb" "$n" 2>/dev/null | grep -qxF remote-endpoint && have_links=$((have_links + 1))
done

if [ "$have_ports$have_syms$have_links" = "000" ]; then
  cp "$BASE_IMG" "$OUT_IMG"
  echo "camera ports already pruned in $BASE_IMG; copied unchanged to $OUT_IMG"
  echo "OK: $OUT_IMG"
  exit 0
fi
[ "$have_ports" -eq 3 ] && [ "$have_syms" -eq 3 ] && [ "$have_links" -eq 3 ] \
  || die "base DTB is half-pruned (ports=$have_ports/3 symbols=$have_syms/3 links=$have_links/3)"

# --- 3. delete the three unused CSIPHY ports, links and symbols -------------
cp "$TMP/base.dtb" "$TMP/camera.dtb"
for n in "${DROP_LINKS[@]}"; do
  fdtput -d "$TMP/camera.dtb" "$n" remote-endpoint \
    || die "fdtput -d failed for $n"
done
for p in "${DROP_PORTS[@]}"; do
  fdtput -r "$TMP/camera.dtb" "$CAMSS_PORTS/port@$p" \
    || die "fdtput -r failed for $CAMSS_PORTS/port@$p"
done
for s in "${DROP_SYMBOLS[@]}"; do
  fdtput -d "$TMP/camera.dtb" /__symbols__ "$s" \
    || die "fdtput -d failed for /__symbols__/$s"
done

# --- 4. read-back checks ----------------------------------------------------
LEFT_PORTS="$(fdtget -l "$TMP/camera.dtb" "$CAMSS_PORTS")" || die "CAMSS ports node disappeared"
for p in "${DROP_PORTS[@]}"; do
  printf '%s\n' "$LEFT_PORTS" | grep -qxF "port@$p" && die "port@$p still present"
done
for n in "${DROP_LINKS[@]}"; do
  if fdtget -p "$TMP/camera.dtb" "$n" 2>/dev/null | grep -qxF remote-endpoint; then
    die "remote-endpoint still present on $n"
  fi
done
LEFT_SYMS="$(fdtget -p "$TMP/camera.dtb" /__symbols__)" || die "DTB lost __symbols__"
BASE_SYM_COUNT="$(printf '%s\n' "$SYMS" | wc -l | tr -d ' ')"
NEW_SYM_COUNT="$(printf '%s\n' "$LEFT_SYMS" | wc -l | tr -d ' ')"
[ "$NEW_SYM_COUNT" -gt 0 ] && [ "$((BASE_SYM_COUNT - NEW_SYM_COUNT))" -eq 3 ] \
  || die "__symbols__ count changed by $((BASE_SYM_COUNT - NEW_SYM_COUNT)), expected 3"
for s in csiphy0_ep csiphy2_ep csiphy4_ep; do
  printf '%s\n' "$LEFT_SYMS" | grep -qxF "$s" && die "$s still present in __symbols__"
done
# IMX582 must keep its port and symbol.
printf '%s\n' "$LEFT_PORTS" | grep -qxF "port@1" || die "port@1 (IMX582) disappeared"
printf '%s\n' "$LEFT_SYMS" | grep -qxF "csiphy1_ep" || die "csiphy1_ep symbol disappeared"

# CAMSS port@1 / csiphy1_ep / the imx582 link must survive untouched.
fdtget -t x "$TMP/camera.dtb" /soc@0/camss@ac6a000/ports/port@1/endpoint remote-endpoint >/dev/null \
  || die "port@1 lost its remote-endpoint"
fdtget -t x "$TMP/camera.dtb" /soc@0/cci@ac4f000/i2c-bus@0/imx582@10/port/endpoint remote-endpoint >/dev/null \
  || die "imx582 lost its remote-endpoint"
[ "$(fdtget -t s "$TMP/camera.dtb" /__symbols__ csiphy1_ep)" = "/soc@0/camss@ac6a000/ports/port@1/endpoint" ] \
  || die "csiphy1_ep symbol changed"

# fdtput only deletes: the new DTS must be a strict subset of the old one.
dtc -I dtb -O dts -o "$TMP/old.dts" "$TMP/base.dtb" 2>/dev/null
dtc -I dtb -O dts -o "$TMP/new.dts" "$TMP/camera.dtb" 2>/dev/null
ADDED="$(diff <(sed 's/^[[:space:]]*//' "$TMP/old.dts") \
              <(sed 's/^[[:space:]]*//' "$TMP/new.dts") \
         | grep -c '^> ' || true)"
REMOVED="$(diff <(sed 's/^[[:space:]]*//' "$TMP/old.dts") \
                <(sed 's/^[[:space:]]*//' "$TMP/new.dts") \
           | grep -c '^< ' || true)"
[ "$ADDED" -eq 0 ] || die "DTB edit added $ADDED unexpected lines"
[ "$REMOVED" -gt 0 ] || die "DTB edit removed nothing"

# --- 5. repack with the exact same kernel/ramdisk/cmdline -------------------
cat "$TMP/Image.gz" "$TMP/camera.dtb" > "$TMP/Image.gz-dtb"
python3 "$WORK/tools/bootimg.py" pack \
  --kernel "$TMP/Image.gz-dtb" \
  --ramdisk "$TMP/ramdisk" \
  --cmdline "$(cat "$TMP/cmdline")" \
  --output "$TMP/out.img"

# --- 6. verify the packed image --------------------------------------------
python3 - "$TMP/out.img" "$TMP" <<'PY'
import hashlib, struct, sys
img, tmp = sys.argv[1], sys.argv[2]
b = open(img, "rb").read()
ks, kaddr, rs, raddr, ss, sa, tags, page, hv, _ = struct.unpack_from("<10I", b, 8)
assert b[:8] == b"ANDROID!" and b[8:12] == struct.pack("<I", ks)
assert (hv, page, kaddr, raddr, ss, sa, tags) == (0, 4096, 0x8000, 0x1000000, 0, 0, 0x100)
blob = b[page:page + ks]
ramdisk = b[(page + ks + page - 1) // page * page:][:rs]
want_blob = open(tmp + "/Image.gz-dtb", "rb").read()
want_ramdisk = open(tmp + "/ramdisk", "rb").read()
assert blob == want_blob, "kernel blob mismatch"
assert ramdisk == want_ramdisk, "ramdisk mismatch"
cmd = b[64:64 + 512].split(b"\0", 1)[0].decode()
assert cmd == open(tmp + "/cmdline").read(), "cmdline mismatch"
print(f"packed: {len(b)} B, kernel {ks}, ramdisk {rs}")
print(f"dtb sha256 {hashlib.sha256(open(tmp + '/camera.dtb','rb').read()).hexdigest()}")
print(f"image sha256 {hashlib.sha256(b).hexdigest()}")
PY

cp "$TMP/out.img" "$OUT_IMG"
echo "OK: $OUT_IMG"
echo "pruned: camss port@0/2/4 + csiphy0/2/4_ep; IMX582 port@1 kept"
echo "NOT FLASHED. Candidate for boot_b; verify camera on the next boot."
