#!/bin/bash
# Reserve the bootloader's continuous-splash framebuffer in the DTB.
#
# Symptom: on every boot the Xiaomi/POCO logo is shown with its upper half
# corrupted until the mainline DPU/DSI driver takes over a few seconds later.
#
# Root cause: ABL keeps the display controller scanning the logo framebuffer
# at 0x9c000000 (the downstream DTS calls it cont_splash_region@9c000000,
# 0x2300000 bytes).  The mainline alioth DTS never reserved that range, so
# Linux treats it as ordinary System RAM and the page allocator / early
# allocations overwrite the logo while ABL is still scanning it.  ABL itself
# reports this when the node is absent:
#     ERROR: Could not get splash memory region node
# The display recovers as soon as the DPU driver reinitialises the panel.
#
# Fix: add the downstream reserved-memory nodes and the aliases ABL looks up,
# without touching the kernel, ramdisk or cmdline.  The region is only
# reserved; none of the mainline drivers use it, and the boot logo stays
# intact until native display takeover.
#
# This is a DTB post-processing step, same as 06/07/09, because the kernel is
# prebuilt.  Long term this belongs in the alioth DTS source.
#
# Usage: 10-splash-mem.sh [base boot.img] [output boot.img]
# Default: out/boot-production.img -> out/boot-production-splash.img
#
# This script does NOT flash anything.
set -euo pipefail
. "$(dirname "$0")/env.sh"

BASE_IMG="${1:-$OUT/boot-production.img}"
OUT_IMG="${2:-$OUT/boot-production-splash.img}"

SPLASH_NODE="/reserved-memory/cont_splash_region@9c000000"
DFPS_NODE="/reserved-memory/dfps_data_region@9e300000"
SPLASH_REG=(0 0x9c000000 0 0x2300000)
DFPS_REG=(0 0x9e300000 0 0x100000)

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

# --- 2. sanity-check the reserved-memory node ------------------------------
CELLS_A="$(fdtget -t x "$TMP/base.dtb" /reserved-memory '#address-cells')"
CELLS_S="$(fdtget -t x "$TMP/base.dtb" /reserved-memory '#size-cells')"
[ "$CELLS_A" = "2" ] && [ "$CELLS_S" = "2" ] \
	|| die "/reserved-memory cells are $CELLS_A/$CELLS_S, expected 2/2"

have_splash=0
have_dfps=0
have_splash_alias=0
have_dfps_alias=0
fdtget -l "$TMP/base.dtb" /reserved-memory | grep -qxF "${SPLASH_NODE##*/}" && have_splash=1
fdtget -l "$TMP/base.dtb" /reserved-memory | grep -qxF "${DFPS_NODE##*/}" && have_dfps=1
fdtget -p "$TMP/base.dtb" /aliases | grep -qxF cont_splash_memory && have_splash_alias=1
fdtget -p "$TMP/base.dtb" /aliases | grep -qxF dfps_data_memory && have_dfps_alias=1

if [ "$have_splash$have_dfps$have_splash_alias$have_dfps_alias" = "1111" ]; then
	# Already built from a DTS that carries the reservation.  Verify it is
	# exactly what we expect, then pass the base image through unchanged.
	[ "$(fdtget -t x "$TMP/base.dtb" "$SPLASH_NODE" reg)" = "0 9c000000 0 2300000" ] \
		|| die "$SPLASH_NODE exists with unexpected reg"
	[ "$(fdtget -t x "$TMP/base.dtb" "$DFPS_NODE" reg)" = "0 9e300000 0 100000" ] \
		|| die "$DFPS_NODE exists with unexpected reg"
	[ "$(fdtget -t s "$TMP/base.dtb" /aliases cont_splash_memory)" = "$SPLASH_NODE" ] \
		|| die "/aliases/cont_splash_memory points elsewhere"
	[ "$(fdtget -t s "$TMP/base.dtb" /aliases dfps_data_memory)" = "$DFPS_NODE" ] \
		|| die "/aliases/dfps_data_memory points elsewhere"
	cp "$BASE_IMG" "$OUT_IMG"
	echo "splash reservation already present in $BASE_IMG; copied unchanged to $OUT_IMG"
	echo "OK: $OUT_IMG"
	exit 0
fi

[ "$have_splash$have_dfps$have_splash_alias$have_dfps_alias" = "0000" ] \
	|| die "base DTB has only part of the splash reservation (splash=$have_splash dfps=$have_dfps aliases=$have_splash_alias/$have_dfps_alias)"

# --- 3. add the reserved regions and the aliases ABL looks up --------------
cp "$TMP/base.dtb" "$TMP/splash.dtb"
fdtput -c "$TMP/splash.dtb" "$SPLASH_NODE" "$DFPS_NODE" \
	|| die "fdtput -c failed (no space in DTB?)"
fdtput -t x "$TMP/splash.dtb" "$SPLASH_NODE" reg "${SPLASH_REG[@]}"
fdtput -t s "$TMP/splash.dtb" "$SPLASH_NODE" label cont_splash_region
fdtput -t x "$TMP/splash.dtb" "$DFPS_NODE" reg "${DFPS_REG[@]}"
fdtput -t s "$TMP/splash.dtb" "$DFPS_NODE" label dfps_data_region
fdtput -t s "$TMP/splash.dtb" /aliases cont_splash_memory "$SPLASH_NODE"
fdtput -t s "$TMP/splash.dtb" /aliases dfps_data_memory "$DFPS_NODE"

# --- 4. read-back checks ----------------------------------------------------
[ "$(fdtget -t x "$TMP/splash.dtb" "$SPLASH_NODE" reg)" = "0 9c000000 0 2300000" ] \
	|| die "cont_splash reg read-back mismatch"
[ "$(fdtget -t x "$TMP/splash.dtb" "$DFPS_NODE" reg)" = "0 9e300000 0 100000" ] \
	|| die "dfps reg read-back mismatch"
[ "$(fdtget -t s "$TMP/splash.dtb" "$SPLASH_NODE" label)" = "cont_splash_region" ] \
	|| die "cont_splash label read-back mismatch"
[ "$(fdtget -t s "$TMP/splash.dtb" "$DFPS_NODE" label)" = "dfps_data_region" ] \
	|| die "dfps label read-back mismatch"
[ "$(fdtget -t s "$TMP/splash.dtb" /aliases cont_splash_memory)" = "$SPLASH_NODE" ] \
	|| die "cont_splash_memory alias read-back mismatch"
[ "$(fdtget -t s "$TMP/splash.dtb" /aliases dfps_data_memory)" = "$DFPS_NODE" ] \
	|| die "dfps_data_memory alias read-back mismatch"

BASE_SYMS="$(fdtget -p "$TMP/base.dtb" /__symbols__ | wc -l | tr -d ' ')"
NEW_SYMS="$(fdtget -p "$TMP/splash.dtb" /__symbols__ | wc -l | tr -d ' ')"
[ "$BASE_SYMS" -gt 0 ] && [ "$BASE_SYMS" -eq "$NEW_SYMS" ] \
	|| die "__symbols__ count changed ($BASE_SYMS -> $NEW_SYMS); ABL would reject the image"

# The additions must not rewrite anything else.  fdtput only appends nodes and
# properties, so decompiled DTS lines from the base must all still be present.
dtc -I dtb -O dts -o "$TMP/base.dts" "$TMP/base.dtb" 2>/dev/null
dtc -I dtb -O dts -o "$TMP/splash.dts" "$TMP/splash.dtb" 2>/dev/null
REMOVED="$(diff <(sed 's/^[[:space:]]*//' "$TMP/base.dts") \
                <(sed 's/^[[:space:]]*//' "$TMP/splash.dts") \
           | grep -c '^< ' || true)"
if [ "$REMOVED" -ne 0 ]; then
	echo "unexpected DTB diff:" >&2
	diff -u "$TMP/base.dts" "$TMP/splash.dts" >&2 || true
	die "DTB edit removed or changed $REMOVED existing lines"
fi

# --- 5. repack with the exact same kernel/ramdisk/cmdline -------------------
cat "$TMP/Image.gz" "$TMP/splash.dtb" > "$TMP/Image.gz-dtb"
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
print(f"image sha256 {hashlib.sha256(b).hexdigest()}")
PY

cp "$TMP/out.img" "$OUT_IMG"
echo "OK: $OUT_IMG"
echo "reserved: $SPLASH_NODE ${SPLASH_REG[*]} + $DFPS_NODE ${DFPS_REG[*]}"
echo "NOT FLASHED. Candidate for boot_b; verify the logo on the next cold boot."
