#!/bin/bash
# Replace Image.gz in an existing boot image with a newly built kernel,
# keeping the DTB (local-bd-address, __symbols__), ramdisk and cmdline intact.
#
# Why: the GPU thermal fix is a kernel config change (CONFIG_DEVFREQ_THERMAL=y).
# The device tree already has the GPU cooling-cells and cooling-maps; rebuilding
# the DTB would risk dropping the Bluetooth local-bd-address fix, so we only
# swap Image.gz inside the running boot image.
#
# Usage: 08-gpu-thermal.sh <new Image.gz> [base boot.img] [output boot.img]
# Default base: out/boot-production-bt.img
# Default out:  out/boot-production-thermal.img
set -euo pipefail
. "$(dirname "$0")/env.sh"

NEW_IMAGE="${1:?usage: 08-gpu-thermal.sh <new Image.gz> [base boot.img] [output boot.img]}"
BASE_IMG="${2:-$OUT/boot-production-bt.img}"
OUT_IMG="${3:-$OUT/boot-production-thermal.img}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$NEW_IMAGE" ] || die "new Image.gz not found: $NEW_IMAGE"
[ -f "$BASE_IMG" ] || die "base boot image not found: $BASE_IMG"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. split base image: kernel blob -> Image.gz + appended DTB ------------
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
ks = page
blob = b[ks:ks + ksz]
rs = b[(ks + ksz + page - 1) // page * page:][:rsz]
off = blob.rfind(b"\xd0\x0d\xfe\xed")
if off < 0:
    raise SystemExit("no appended DTB in kernel blob")
(tot,) = struct.unpack_from(">I", blob, off + 4)
if off + tot != len(blob):
    raise SystemExit(f"DTB totalsize {tot} does not match blob tail {len(blob) - off}")
open(tmp + "/base-Image.gz", "wb").write(blob[:off])
open(tmp + "/base.dtb", "wb").write(blob[off:])
open(tmp + "/ramdisk", "wb").write(rs)
open(tmp + "/cmdline", "w").write(cmdline)
print(f"base: Image.gz {off} B + DTB {tot} B, ramdisk {rsz} B")
PY

# --- 2. the DTB must still carry __symbols__ (ABL overlay requirement) ------
strings "$TMP/base.dtb" | grep __symbols__ >/dev/null \
  || die "base DTB has no __symbols__; ABL will reject the image"

# --- 3. new kernel + unchanged DTB ------------------------------------------
cat "$NEW_IMAGE" "$TMP/base.dtb" > "$TMP/Image.gz-dtb"

python3 "$WORK/tools/bootimg.py" pack \
  --kernel "$TMP/Image.gz-dtb" \
  --ramdisk "$TMP/ramdisk" \
  --cmdline "$(cat "$TMP/cmdline")" \
  --output "$TMP/out.img"

# --- 4. verify the packed image ---------------------------------------------
python3 - "$TMP/out.img" "$TMP" "$NEW_IMAGE" <<'PY'
import hashlib, struct, sys
img, tmp, new_image = sys.argv[1], sys.argv[2], sys.argv[3]
b = open(img, "rb").read()
(ksz, kaddr, rs, raddr, ss, sa, tags, page, hv, _) = struct.unpack_from("<10I", b, 8)
assert b[:8] == b"ANDROID!"
assert (hv, page, kaddr, raddr, ss, sa, tags) == (0, 4096, 0x8000, 0x1000000, 0, 0, 0x100)
blob = b[page:page + ksz]
ramdisk = b[(page + ksz + page - 1) // page * page:][:rs]
want_blob = open(tmp + "/Image.gz-dtb", "rb").read()
want_ramdisk = open(tmp + "/ramdisk", "rb").read()
assert blob == want_blob, "kernel blob mismatch"
assert ramdisk == want_ramdisk, "ramdisk mismatch"
cmd = b[64:64 + 512].split(b"\0", 1)[0].decode()
assert cmd == open(tmp + "/cmdline").read(), "cmdline mismatch"
print(f"packed: {len(b)} B, kernel {ksz}, ramdisk {rs}")
print(f"kernel sha256 {hashlib.sha256(open(new_image,'rb').read()).hexdigest()}")
print(f"image  sha256 {hashlib.sha256(b).hexdigest()}")
PY

cp "$TMP/out.img" "$OUT_IMG"
echo "OK: $OUT_IMG"
echo "NOT FLASHED. Flash to boot_b only after the cold-boot candidate is verified."
