#!/usr/bin/env python3
"""Inject an SSH public key into the rescue initramfs of an alioth boot image.

The released boot image intentionally has no authorized_keys.  This tool
unpacks its Android boot image, adds the key to the zstd (or gzip/xz/lz4)
compressed main initramfs archive, and repacks the boot image.

It only changes the ramdisk; the kernel blob (Image.gz + appended DTB) and
cmdline are preserved byte-for-byte.

Usage:
    inject-initramfs-key.py --boot boot-production-final.img \
        --key ~/.ssh/id_ed25519.pub --output boot-production-rescue.img

Requires zstd (or gzip/xz/lz4 for other initramfs formats) in PATH.
"""
import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bootimg  # noqa: E402

NEWC_MAGICS = (b"070701", b"070702")
CPIO_TRAILER = b"TRAILER!!!"
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
GZIP_MAGIC = b"\x1f\x8b"
XZ_MAGIC = b"\xfd7zXZ\x00"
LZ4_LEGACY_MAGIC = b"\x02\x21\x4c\x18"
LZ4_MAGIC = b"\x04\x22\x4d\x18"


def align4(n):
    return (n + 3) & ~3


def parse_newc(data, start=0):
    """Return (entries, end_offset); entries are dicts with header fields."""
    entries = []
    pos = start
    while True:
        if data[pos:pos + 6] not in NEWC_MAGICS:
            raise ValueError(f"not a newc cpio header at offset {pos}")
        raw = data[pos + 6:pos + 110]
        if len(raw) != 104:
            raise ValueError("truncated cpio header")
        vals = [int(raw[i * 8:(i + 1) * 8], 16) for i in range(13)]
        (ino, mode, uid, gid, nlink, mtime, filesize, devmajor, devminor,
         rdevmajor, rdevminor, namesize, check) = vals
        name_start = pos + 110
        name = data[name_start:name_start + namesize - 1]
        data_start = align4(name_start + namesize)
        file_data = data[data_start:data_start + filesize]
        end = align4(data_start + filesize)
        if len(file_data) != filesize:
            raise ValueError(f"truncated cpio data for {name!r}")
        if name == CPIO_TRAILER:
            return entries, end
        entries.append({
            "ino": ino, "mode": mode, "uid": uid, "gid": gid,
            "nlink": nlink, "mtime": mtime, "filesize": filesize,
            "devmajor": devmajor, "devminor": devminor,
            "rdevmajor": rdevmajor, "rdevminor": rdevminor,
            "check": check, "name": name, "data": file_data,
        })
        pos = end


def emit_newc(entries, extra=None):
    out = bytearray()
    next_ino = max((e["ino"] for e in entries), default=0) + 1
    all_entries = list(entries)
    if extra:
        all_entries.extend(extra)
    for e in all_entries:
        if not e.get("ino"):
            e = dict(e)
            e["ino"] = next_ino
            next_ino += 1
        name = e["name"]
        data = e["data"]
        vals = [
            e["ino"], e.get("mode", 0o100600), e.get("uid", 0),
            e.get("gid", 0), e.get("nlink", 1), e.get("mtime", int(time.time())),
            len(data), e.get("devmajor", 0), e.get("devminor", 0),
            e.get("rdevmajor", 0), e.get("rdevminor", 0), len(name) + 1,
            e.get("check", 0),
        ]
        out += b"070701" + b"".join(f"{v:08x}".encode() for v in vals)
        out += name + b"\0"
        out += b"\0" * (align4(len(out)) - len(out))
        out += data
        out += b"\0" * (align4(len(out)) - len(out))
    # trailer
    vals = [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, len(CPIO_TRAILER) + 1, 0]
    out += b"070701" + b"".join(f"{v:08x}".encode() for v in vals)
    out += CPIO_TRAILER + b"\0"
    out += b"\0" * (align4(len(out)) - len(out))
    return bytes(out)


def find_compressor(data, start):
    """Return (kind, offset) for the first compressed archive at/after start."""
    limit = min(len(data), start + 65536)
    for i in range(start, limit):
        if data[i:i + 4] == ZSTD_MAGIC:
            return "zstd", i
        if data[i:i + 2] == GZIP_MAGIC:
            return "gzip", i
        if data[i:i + 6] == XZ_MAGIC:
            return "xz", i
        if data[i:i + 4] == LZ4_LEGACY_MAGIC:
            return "lz4", i
        if data[i:i + 4] == LZ4_MAGIC:
            return "lz4", i
    return None, None


def tool_for(kind):
    names = {
        "zstd": ["zstd"],
        "gzip": ["gzip"],
        "xz": ["xz"],
        "lz4": ["lz4"],
    }[kind]
    for name in names:
        p = shutil.which(name)
        if p:
            return p
        for prefix in ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"):
            p = os.path.join(prefix, name)
            if os.access(p, os.X_OK):
                return p
    raise SystemExit(f"ERROR: {kind} decompressor/compressor not found in PATH")


def decompress(kind, blob):
    tool = tool_for(kind)
    r = subprocess.run([tool, "-d", "-c"], input=blob, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise SystemExit(f"ERROR: {kind} decompression failed: {r.stderr.decode(errors='replace')}")
    return r.stdout


def compress(kind, blob):
    tool = tool_for(kind)
    if kind == "zstd":
        args = [tool, "-19", "-T0", "-c"]
    elif kind == "gzip":
        args = [tool, "-9", "-n", "-c"]
    elif kind == "xz":
        args = [tool, "-9", "-c"]
    else:
        args = [tool, "-9", "-c"]
    r = subprocess.run(args, input=blob, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise SystemExit(f"ERROR: {kind} compression failed: {r.stderr.decode(errors='replace')}")
    return r.stdout


def inject(ramdisk, key_line):
    # 1. Split the early (uncompressed) modules cpio from the main archive.
    early = b""
    main_start = 0
    if ramdisk[:6] in NEWC_MAGICS:
        _, early_end = parse_newc(ramdisk)
        kind, off = find_compressor(ramdisk, early_end)
        if kind is None:
            raise SystemExit("ERROR: unsupported initramfs: no compressed main archive after early cpio")
        early = ramdisk[:off]
        main_start = off
    else:
        kind, off = find_compressor(ramdisk, 0)
        if kind is None:
            raise SystemExit("ERROR: unsupported initramfs: no compressor magic found")
        main_start = off

    main = decompress(kind, ramdisk[main_start:])
    entries, end = parse_newc(main)
    if end > len(main) and main[end:].strip(b"\0"):
        raise SystemExit("ERROR: unexpected trailing data in main initramfs")

    # dropbear-initramfs gives root a random home directory (root-XXXXXXXXXX)
    # and reads authorized_keys from there at boot.  Find that path from the
    # initramfs /etc/passwd instead of guessing.
    root_key = b"root/.ssh/authorized_keys"
    passwd = next((e for e in entries if e["name"] == b"etc/passwd"), None)
    if passwd:
        for line in passwd["data"].decode(errors="replace").splitlines():
            fields = line.split(":")
            if len(fields) >= 7 and fields[0] == "root" and fields[5]:
                home = fields[5].strip("/")
                if home:
                    root_key = (home + "/.ssh/authorized_keys").encode()
                break

    # Replace any key from an older/private build rather than adding beside it.
    entries = [e for e in entries if not e["name"].endswith(b"/authorized_keys")
               and e["name"] != b"authorized_keys"]
    have = {e["name"] for e in entries}
    add = []
    wanted = [root_key, b"etc/dropbear/initramfs/authorized_keys"]
    for name in wanted:
        parts = name.split(b"/")
        for i in range(1, len(parts)):
            d = b"/".join(parts[:i])
            if d not in have and d not in {e["name"] for e in add}:
                add.append({"ino": 0, "mode": 0o040755, "uid": 0, "gid": 0,
                            "nlink": 2, "mtime": int(time.time()), "name": d,
                            "data": b""})
        if name not in {e["name"] for e in add}:
            add.append({"ino": 0, "mode": 0o100600, "uid": 0, "gid": 0,
                        "nlink": 1, "mtime": int(time.time()), "name": name,
                        "data": key_line})
    new_main = emit_newc(entries, add)
    new_ramdisk = early + compress(kind, new_main)

    # Verify the key is present in the rebuilt archive.
    check_main = decompress(kind, new_ramdisk[len(early):])
    check_entries, _ = parse_newc(check_main)
    found = [e for e in check_entries if e["name"] == root_key]
    if not found or found[0]["data"] != key_line:
        raise SystemExit(f"ERROR: key verification failed for {root_key!r}")
    print(f"initramfs key path: /{root_key.decode()}")
    return new_ramdisk


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--boot", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--output", required=True)
    a = ap.parse_args()

    key = open(a.key, "rb").read().strip()
    if not key:
        raise SystemExit("ERROR: key file is empty")
    key += b"\n"
    if not (key.startswith(b"ssh-") or key.startswith(b"ecdsa-") or
            key.startswith(b"sk-")):
        raise SystemExit("ERROR: key file does not look like an SSH public key")

    b = open(a.boot, "rb").read()
    if b[:8] != bootimg.MAGIC:
        raise SystemExit("ERROR: not an Android boot image")
    hv = struct.unpack_from("<I", b, 40)[0]
    if hv != 0:
        raise SystemExit(f"ERROR: only boot header v0 is supported (got v{hv})")
    (ksz, kaddr, rsz, raddr, ssz, saddr, tags, page, _, osver) = \
        struct.unpack_from("<10I", b, 8)
    if page != 4096:
        raise SystemExit(f"ERROR: unexpected page size {page}")
    kernel = b[page:page + ksz]
    roff = (page + ksz + page - 1) // page * page
    ramdisk = b[roff:roff + rsz]
    cmdline = b[64:64 + 512].split(b"\0", 1)[0].decode()
    name = b[48:64].split(b"\0", 1)[0]
    second_off = (roff + rsz + page - 1) // page * page
    second = b[second_off:second_off + ssz]

    new_ramdisk = inject(ramdisk, key)
    out = bootimg.build_v0(
        kernel, new_ramdisk, cmdline, name=name, page_size=page,
        kernel_addr=kaddr, ramdisk_addr=raddr, second_addr=saddr,
        tags_addr=tags, second=second, os_version=osver)

    # The kernel blob and cmdline must survive byte-for-byte.
    out_kernel = out[page:page + ksz]
    out_cmd = out[64:64 + 512].split(b"\0", 1)[0].decode()
    if out_kernel != kernel or out_cmd != cmdline:
        raise SystemExit("ERROR: kernel or cmdline changed during repack")

    with open(a.output, "wb") as f:
        f.write(out)
    print(f"wrote {a.output}: {len(out)} bytes "
          f"(kernel {ksz}, ramdisk {len(new_ramdisk)})")
    print(f"sha256 {hashlib.sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()
