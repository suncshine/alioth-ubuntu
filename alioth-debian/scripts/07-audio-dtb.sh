#!/bin/bash
# Build the alioth audio DTB and pack a boot image WITHOUT rebuilding the kernel.
#
# The audio DTS is files/audio/sm8250-xiaomi-alioth-audio.dts: the exact Kupfer
# alioth DTS plus the WCD938x codec / SoundWire / TX-macro capture path and the
# BlueZ local-bd-address.  It is preprocessed with the kernel source tree and
# compiled with dtc, then the appended DTB of an existing boot image is
# replaced.  Image.gz, ramdisk, cmdline, addresses and the boot header are
# preserved byte-for-byte.
#
# Usage: 07-audio-dtb.sh [base boot.img] [output boot.img]
# Default: out/boot-production-thermal.img -> out/boot-production-audio.img
#
# Env: KSRC  kernel source tree used for #include resolution.
#            default: /tmp/alioth-kernel-check/src, then $WORK/kernel-src.
#      CPP   preprocessor (default: clang if present, else gcc/cc)
#      AUDIO_DTB  use this prebuilt DTB instead of compiling the DTS
#            (e.g. build/alioth-audio.dtb built with dtc by hand).
#
# This script does NOT flash anything.
set -euo pipefail
. "$(dirname "$0")/env.sh"

BASE_IMG="${1:-$OUT/boot-production-thermal.img}"
OUT_IMG="${2:-$OUT/boot-production-audio.img}"
AUDIO_DIR="$WORK/files/audio"
DTS="$AUDIO_DIR/sm8250-xiaomi-alioth-audio.dts"
KSRC="${KSRC:-/tmp/alioth-kernel-check/src}"
[ -d "$KSRC/include/dt-bindings" ] || KSRC="$WORK/kernel-src"

die() { echo "ERROR: $*" >&2; exit 1; }

if [ -z "${AUDIO_DTB:-}" ] && [ ! -d "$KSRC/include/dt-bindings" ]; then
	die "kernel source not found: set KSRC (needs include/dt-bindings and arch/arm64/boot/dts/qcom/sm8250.dtsi) or pass AUDIO_DTB"
fi

[ -f "$BASE_IMG" ] || die "base boot image not found: $BASE_IMG"
[ -f "$DTS" ]      || die "audio DTS not found: $DTS"
command -v dtc >/dev/null || die "dtc missing (macOS: brew install dtc; Debian: apt install device-tree-compiler)"
command -v fdtget >/dev/null || die "fdtget missing (see dtc above)"
command -v python3 >/dev/null || die "python3 missing"

if [ -z "${AUDIO_DTB:-}" ]; then
	CPP="${CPP:-$(command -v clang || command -v gcc || command -v cc || true)}"
	[ -n "$CPP" ] || die "no C preprocessor found (set CPP)"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. build the audio DTB (or use a prebuilt one) -------------------------
if [ -n "${AUDIO_DTB:-}" ]; then
	[ -f "$AUDIO_DTB" ] || die "AUDIO_DTB not found: $AUDIO_DTB"
	cp "$AUDIO_DTB" "$TMP/audio.dtb"
	echo "using prebuilt audio DTB: $AUDIO_DTB"
else
	"$CPP" -E -P -nostdinc \
		-I "$KSRC/scripts/dtc/include-prefixes" \
		-I "$KSRC/include" \
		-I "$KSRC/arch/arm64/boot/dts" \
		-I "$KSRC/arch/arm64/boot/dts/qcom" \
		-undef -D__DTS__ -x assembler-with-cpp \
		"$DTS" -o "$TMP/audio.pre.dts"
	dtc -q -@ -I dts -O dtb -o "$TMP/audio.dtb" "$TMP/audio.pre.dts"
fi

strings "$TMP/audio.dtb" | grep __symbols__ >/dev/null \
	|| die "audio DTB has no __symbols__ — ABL will reject the overlay"
BT_HEX="$(fdtget -t bx "$TMP/audio.dtb" /soc@0/geniqup@9c0000/serial@998000/bluetooth local-bd-address 2>/dev/null \
	| tr ' ' '\n' | while read -r b; do printf '%02x' "0x$b"; done)"
[ "$BT_HEX" = "9a7856341202" ] \
	|| die "audio DTB lost the Bluetooth local-bd-address (got '$BT_HEX')"
echo "audio DTB: $(stat -f%z "$TMP/audio.dtb" 2>/dev/null || stat -c%s "$TMP/audio.dtb") B"

# --- 2. split the base image: Image.gz + appended DTB + ramdisk + cmdline ---
python3 - "$BASE_IMG" "$TMP" <<'PY'
import struct, sys
img, tmp = sys.argv[1], sys.argv[2]
b = open(img, "rb").read()
if b[:8] != b"ANDROID!":
    raise SystemExit("not an Android boot image")
(hv,) = struct.unpack_from("<I", b, 40)
if hv != 0:
    raise SystemExit(f"expected boot header v0, got v{hv}")
(ksz, kaddr, rsz, raddr, ssz, saddr, tags, page, _, _) = struct.unpack_from("<10I", b, 8)
if (page, kaddr, raddr, ssz, saddr, tags) != (4096, 0x8000, 0x1000000, 0, 0, 0x100):
    raise SystemExit("unexpected boot header layout")
cmdline = b[64:64 + 512].split(b"\0", 1)[0].decode()
blob = b[page:page + ksz]
roff = (page + ksz + page - 1) // page * page
rs = b[roff:roff + rsz]
off = blob.rfind(b"\xd0\x0d\xfe\xed")
if off < 0:
    raise SystemExit("no appended DTB in the base kernel blob")
(tot,) = struct.unpack_from(">I", blob, off + 4)
if off + tot != len(blob):
    raise SystemExit(f"base DTB totalsize {tot} does not match blob tail {len(blob) - off}")
open(tmp + "/Image.gz", "wb").write(blob[:off])
open(tmp + "/base.dtb", "wb").write(blob[off:])
open(tmp + "/ramdisk", "wb").write(rs)
open(tmp + "/cmdline", "w").write(cmdline)
print(f"base: Image.gz {off} B + DTB {tot} B, ramdisk {rsz} B")
PY

# The audio DTS is built from the same source tree as the base image, and the
# only boot-image-local edit made since is the Bluetooth local-bd-address,
# which the audio DTS also carries.  Anything else in the base DTB would be
# lost by this replacement, so make that explicit for the operator.
if [ -n "$(fdtget -t bx "$TMP/base.dtb" /soc@0/geniqup@9c0000/serial@998000/bluetooth local-bd-address 2>/dev/null)" ]; then
	echo "base DTB carries local-bd-address; audio DTB re-adds the same value"
else
	echo "NOTE: base DTB has no local-bd-address; audio DTB adds 02:12:34:56:78:9A"
fi

# --- 3. repack with the same kernel/ramdisk/cmdline ------------------------
cat "$TMP/Image.gz" "$TMP/audio.dtb" > "$TMP/Image.gz-dtb"
python3 "$WORK/tools/bootimg.py" pack \
	--kernel "$TMP/Image.gz-dtb" \
	--ramdisk "$TMP/ramdisk" \
	--cmdline "$(cat "$TMP/cmdline")" \
	--output "$TMP/out.img"

# --- 4. verify the packed image --------------------------------------------
python3 - "$TMP/out.img" "$TMP" <<'PY'
import hashlib, struct, sys
img, tmp = sys.argv[1], sys.argv[2]
b = open(img, "rb").read()
ks, kaddr, rs, raddr, ss, sa, tags, page, hv, _ = struct.unpack_from("<10I", b, 8)
assert b[:8] == b"ANDROID!" and b[8:12] == struct.pack("<I", ks)
assert (hv, page, kaddr, raddr, ss, sa, tags) == (0, 4096, 0x8000, 0x1000000, 0, 0, 0x100)
blob = b[page:page + ks]
roff = (page + ks + page - 1) // page * page
ramdisk = b[roff:roff + rs]
want_blob = open(tmp + "/Image.gz-dtb", "rb").read()
assert blob == want_blob, "kernel blob mismatch"
assert ramdisk == open(tmp + "/ramdisk", "rb").read(), "ramdisk mismatch"
cmd = b[64:64 + 512].split(b"\0", 1)[0].decode()
assert cmd == open(tmp + "/cmdline").read(), "cmdline mismatch"
# appended DTB must be exactly ours, with symbols and BT address
off = blob.rfind(b"\xd0\x0d\xfe\xed")
assert blob[off:] == open(tmp + "/audio.dtb", "rb").read(), "appended DTB mismatch"
print(f"packed: {len(b)} B, kernel {ks}, ramdisk {rs}")
print(f"image sha256 {hashlib.sha256(b).hexdigest()}")
PY

cp "$TMP/out.img" "$OUT_IMG"
echo "OK: $OUT_IMG"
echo "NOT FLASHED. Test with: fastboot boot $OUT_IMG"
