#!/bin/bash
# Inject a Bluetooth public address into the DTB embedded in a boot image.
#
# Why: the QCA6390 NVM in this device ships with the factory default
# BD address 00:00:00:00:5A:AD.  btqca.c compares the address reported by the
# controller with the one in the NVM file and, when they match, sets
# HCI_QUIRK_USE_BDADDR_PROPERTY.  net/bluetooth/hci_sync.c then reads
# /soc@0/geniqup@9c0000/serial@998000/bluetooth/local-bd-address and calls
# qca_set_bdaddr().  The stock DTB has no such property, so hci0 stays
# HCI_UNCONFIGURED and BlueZ hides it from READ_INDEX_LIST.
#
# The DT binding wants the address least-significant-byte first, i.e. the
# reverse of the printed form: 02:12:34:56:78:9A -> [9a 78 56 34 12 02].
#
# Everything else in the base image (Image.gz, ramdisk, cmdline, the
# dr_mode="peripheral" USB override) is carried over unchanged.
#
# Usage: 06-bt-bdaddr.sh [base boot.img] [printed bdaddr] [output boot.img]
# Default: out/boot-production.img  02:12:34:56:78:9A  out/boot-production-bt.img
set -euo pipefail
. "$(dirname "$0")/env.sh"

BASE_IMG="${1:-$OUT/boot-production.img}"
BDADDR="${2:-02:12:34:56:78:9A}"
OUT_IMG="${3:-$OUT/boot-production-bt.img}"

BT_NODE="/soc@0/geniqup@9c0000/serial@998000/bluetooth"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$BASE_IMG" ] || die "base boot image not found: $BASE_IMG"
command -v dtc    >/dev/null || die "dtc missing (macOS: brew install dtc; Debian: apt install device-tree-compiler)"
command -v fdtput >/dev/null || die "fdtput missing (see dtc above)"
[[ "$BDADDR" =~ ^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$ ]] || die "bad BD address: $BDADDR"

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
ks = page
blob = b[ks:ks + ksz]
rs = b[(ks + ksz + page - 1) // page * page:][:rsz]
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
print(f"base: Image.gz {off} B + DTB {tot} B, ramdisk {rsz} B, cmdline {cmdline!r}")
PY

# --- 2. printed address -> DT little-endian byte order ----------------------
IFS=: read -r o0 o1 o2 o3 o4 o5 <<<"$BDADDR"
DT_BYTES=(0x$o5 0x$o4 0x$o3 0x$o2 0x$o1 0x$o0)
for v in "${DT_BYTES[@]}"; do
  [ "$((v))" -ge 0 ] && [ "$((v))" -le 255 ] || die "bad octet in $BDADDR"
done
[ "$(( ${DT_BYTES[0]} | ${DT_BYTES[1]} | ${DT_BYTES[2]} | ${DT_BYTES[3]} | ${DT_BYTES[4]} | ${DT_BYTES[5]} ))" -ne 0 ] \
  || die "all-zero address is ignored by the kernel"
DT_TXT="$(for v in "${DT_BYTES[@]}"; do printf '%02x ' "$v"; done)"
DT_TXT="${DT_TXT% }"

# --- 3. edit the DTB in place and verify only the one property changed ------
cp "$TMP/base.dtb" "$TMP/bt.dtb"
fdtput -t bx "$TMP/bt.dtb" "$BT_NODE" local-bd-address "${DT_BYTES[@]}" \
  || die "fdtput failed (node $BT_NODE or no space in DTB)"

GOT="$(fdtget -t bx "$TMP/bt.dtb" "$BT_NODE" local-bd-address)" || die "fdtget read-back failed"
read -r -a GOT_BYTES <<<"$GOT"
for i in 0 1 2 3 4 5; do
  got_dec="$(printf '%d' "0x${GOT_BYTES[i]}")"
  dt_dec="$(printf '%d' "${DT_BYTES[i]}")"
  [ "$got_dec" -eq "$dt_dec" ] || die "read-back mismatch: got '$GOT'"
done

dtc -I dtb -O dts -o "$TMP/base.dts" "$TMP/base.dtb" 2>/dev/null
dtc -I dtb -O dts -o "$TMP/bt.dts" "$TMP/bt.dtb" 2>/dev/null
DIFF="$(diff <(sed 's/^[[:space:]]*//' "$TMP/base.dts") <(sed 's/^[[:space:]]*//' "$TMP/bt.dts") || true)"
ADDED="$(printf '%s\n' "$DIFF" | grep -c '^> ' || true)"
REMOVED="$(printf '%s\n' "$DIFF" | grep -c '^< ' || true)"
EXPECT="> local-bd-address = [$DT_TXT];"
if [ "$ADDED" -ne 1 ] || [ "$REMOVED" -ne 0 ] || ! printf '%s\n' "$DIFF" | grep -qxF "$EXPECT"; then
  echo "unexpected DTB diff:" >&2
  printf '%s\n' "$DIFF" >&2
  die "DTB edit changed more than $EXPECT"
fi

BASE_SYMS="$(fdtget -p "$TMP/base.dtb" /__symbols__ | wc -l | tr -d ' ')"
BT_SYMS="$(fdtget -p "$TMP/bt.dtb" /__symbols__ | wc -l | tr -d ' ')"
[ "$BT_SYMS" -gt 0 ] && [ "$BASE_SYMS" -eq "$BT_SYMS" ] \
  || die "DTB __symbols__ missing or changed ($BASE_SYMS -> $BT_SYMS); ABL would reject the image"

# --- 4. repack with the exact same kernel/ramdisk/cmdline -------------------
cat "$TMP/Image.gz" "$TMP/bt.dtb" > "$TMP/Image.gz-dtb"
python3 "$WORK/tools/bootimg.py" pack \
  --kernel "$TMP/Image.gz-dtb" \
  --ramdisk "$TMP/ramdisk" \
  --cmdline "$(cat "$TMP/cmdline")" \
  --output "$TMP/out.img"

# --- 5. verify the packed image ---------------------------------------------
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
echo "OK: $OUT_IMG  (local-bd-address $BDADDR -> [$DT_TXT] on $BT_NODE)"
echo "NOT FLASHED. Candidate for boot_b; verify with the next cold-boot test."
