#!/usr/bin/env python3
"""Android boot image parser (v0-v4). Pure stdlib, runs on macOS/Linux.

Usage: python3 bootimg.py unpack <boot.img> [outdir]
       python3 bootimg.py info <boot.img>
"""
import os
import struct
import sys

MAGIC = b"ANDROID!"
DTB_MAGIC = b"\xd0\x0d\xfe\xed"


def align(x, a):
    return (x + a - 1) // a * a


def parse_v0v1v2(f):
    f.seek(0)
    hdr = f.read(1660)
    (kernel_size, kernel_addr, ramdisk_size, ramdisk_addr, second_size,
     second_addr, tags_addr, page_size, hdr_ver, os_ver) = struct.unpack_from("<10I", hdr, 8)
    name = hdr[48:64]
    cmdline = hdr[64:64 + 512]
    img_id = hdr[576:576 + 32]
    extra_cmdline = hdr[608:608 + 1024]
    h = {
        "header_version": hdr_ver,
        "kernel_size": kernel_size, "kernel_addr": kernel_addr,
        "ramdisk_size": ramdisk_size, "ramdisk_addr": ramdisk_addr,
        "second_size": second_size, "second_addr": second_addr,
        "tags_addr": tags_addr, "page_size": page_size,
        "os_version": os_ver,
        "name": name.rstrip(b"\x00").decode(errors="replace"),
        "cmdline": cmdline.rstrip(b"\x00").decode(errors="replace"),
        "extra_cmdline": extra_cmdline.rstrip(b"\x00").decode(errors="replace"),
    }
    off = page_size
    sections = [("kernel", kernel_size), ("ramdisk", ramdisk_size), ("second", second_size)]
    if hdr_ver >= 1:
        (recovery_dtbo_size,) = struct.unpack_from("<I", hdr, 1632)
        (recovery_dtbo_offset,) = struct.unpack_from("<Q", hdr, 1636)
        (header_size,) = struct.unpack_from("<I", hdr, 1644)
        h["recovery_dtbo_size"] = recovery_dtbo_size
        h["header_size"] = header_size
        if recovery_dtbo_size:
            sections.append(("recovery_dtbo", recovery_dtbo_size))
    if hdr_ver >= 2:
        (dtb_size,) = struct.unpack_from("<I", hdr, 1648)
        (dtb_addr,) = struct.unpack_from("<Q", hdr, 1652)
        h["dtb_size"] = dtb_size
        h["dtb_addr"] = dtb_addr
        if dtb_size:
            sections.append(("dtb", dtb_size))
    return h, sections, off


def parse_v3v4(f):
    f.seek(0)
    hdr = f.read(2116 + 4)
    kernel_size, ramdisk_size, os_ver, header_size = struct.unpack_from("<4I", hdr, 8)
    hdr_ver = struct.unpack_from("<I", hdr, 40)[0]
    cmdline = hdr[44:44 + 1536]
    h = {
        "header_version": hdr_ver,
        "kernel_size": kernel_size,
        "ramdisk_size": ramdisk_size,
        "os_version": os_ver,
        "header_size": header_size,
        "cmdline": cmdline.rstrip(b"\x00").decode(errors="replace"),
        "page_size": 4096,
    }
    page_size = 4096
    off = page_size
    sections = [("kernel", kernel_size), ("ramdisk", ramdisk_size)]
    if hdr_ver == 4:
        (vendor_ramdisk_size,) = struct.unpack_from("<I", hdr, 1584) if len(hdr) > 1588 else (0,)
        # v4 in boot image proper: same as v3 + reserved; GKI boot v4 keeps 2116
        pass
    return h, sections, off


def sniff(blob):
    """Identify content type of a blob."""
    if blob[:4] == DTB_MAGIC:
        return "dtb"
    if blob[:2] == b"\x1f\x8b":
        return "gzip"
    if blob[:4] == b"\x02\x21\x4c\x18":
        return "lz4_legacy"
    if blob[:6] == b"\x04\x22\x4d\x18":
        return "lz4"
    if blob[:2] == b"\x5d\x00\x00":
        return "lzma"
    if blob[:6] == b"\xfd7zXZ":
        return "xz"
    if blob[:4] == b"\x28\xb5\x2f\xfd":
        return "zstd"
    if blob[:3] == b"cpio":
        return "cpio"
    if b"070701" in blob[:64]:
        return "cpio_newc"
    if blob[:4] == b"ANDR":
        return "vendor_boot"
    return "raw"


def build_v0(kernel, ramdisk, cmdline, name=b"", page_size=4096,
             kernel_addr=0x8000, ramdisk_addr=0x1000000,
             second_addr=0xf00000, tags_addr=0x100,
             second=b"", os_version=0):
    """Build a v0 Android boot image. Header is 1632 bytes, page-aligned."""
    import hashlib
    sha = hashlib.sha1()
    sha.update(kernel)
    sha.update(struct.pack("<I", len(kernel)))
    sha.update(ramdisk)
    sha.update(struct.pack("<I", len(ramdisk)))
    sha.update(second)
    sha.update(struct.pack("<I", len(second)))
    img_id = sha.digest()[:32].ljust(32, b"\x00")

    cmd = cmdline.encode()[:512]
    extra = b""  # v0: everything fits in 512 unless longer
    hdr = bytearray(1632)
    hdr[0:8] = MAGIC
    struct.pack_into("<10I", hdr, 8,
                     len(kernel), kernel_addr,
                     len(ramdisk), ramdisk_addr,
                     len(second), second_addr,
                     tags_addr, page_size, 0, os_version)
    hdr[48:64] = name[:16].ljust(16, b"\x00")
    if len(cmd) <= 512:
        hdr[64:64 + len(cmd)] = cmd
    else:
        hdr[64:64 + 512] = cmd[:512]
        extra = cmd[512:1536]
    hdr[576:608] = img_id
    hdr[608:608 + len(extra)] = extra

    out = bytearray()
    out += hdr
    out += bytes(page_size - len(hdr) % page_size if len(hdr) % page_size else 0)
    out += kernel
    if len(kernel) % page_size:
        out += bytes(page_size - len(kernel) % page_size)
    out += ramdisk
    if len(ramdisk) % page_size:
        out += bytes(page_size - len(ramdisk) % page_size)
    if second:
        out += second
        if len(second) % page_size:
            out += bytes(page_size - len(second) % page_size)
    return bytes(out)


def cmd_pack(args):
    import argparse
    p = argparse.ArgumentParser(prog="bootimg.py pack")
    p.add_argument("--kernel", required=True)
    p.add_argument("--ramdisk", required=True)
    p.add_argument("--cmdline", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--page-size", type=lambda x: int(x, 0), default=4096)
    p.add_argument("--kernel-addr", type=lambda x: int(x, 0), default=0x8000)
    p.add_argument("--ramdisk-addr", type=lambda x: int(x, 0), default=0x1000000)
    p.add_argument("--second-addr", type=lambda x: int(x, 0), default=0x0)
    p.add_argument("--tags-addr", type=lambda x: int(x, 0), default=0x100)
    a = p.parse_args(args)
    kernel = open(a.kernel, "rb").read()
    ramdisk = open(a.ramdisk, "rb").read()
    img = build_v0(kernel, ramdisk, a.cmdline, page_size=a.page_size,
                   kernel_addr=a.kernel_addr, ramdisk_addr=a.ramdisk_addr,
                   second_addr=a.second_addr, tags_addr=a.tags_addr)
    with open(a.output, "wb") as o:
        o.write(img)
    print(f"wrote {a.output}: {len(img)} bytes "
          f"(kernel {len(kernel)}, ramdisk {len(ramdisk)})")


def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "pack":
        cmd_pack(argv[1:])
        return
    if len(argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd, path = sys.argv[1], sys.argv[2]
    outdir = sys.argv[3] if len(sys.argv) > 3 else "boot-unpacked"
    f = open(path, "rb")
    magic = f.read(8)
    if magic != MAGIC:
        print("not an Android boot image (magic=%r)" % magic)
        sys.exit(1)
    hdr_ver = struct.unpack_from("<I", f.read(0), 0)[0] if False else None
    # peek header_version at offset 40
    f.seek(40)
    hdr_ver = struct.unpack("<I", f.read(4))[0]
    if hdr_ver >= 3:
        h, sections, off = parse_v3v4(f)
    else:
        h, sections, off = parse_v0v1v2(f)

    print("== Android boot image ==")
    for k in ("header_version", "page_size", "kernel_size", "kernel_addr",
              "ramdisk_size", "ramdisk_addr", "second_size", "second_addr",
              "tags_addr", "dtb_size", "dtb_addr", "recovery_dtbo_size",
              "header_size", "os_version"):
        if k in h and (h[k] or k in ("header_version", "page_size")):
            print(f"  {k:20s} = {h[k]}")
    print(f"  name                 = {h['name']!r}")
    print(f"  cmdline              = {h['cmdline']!r}")
    if h.get("extra_cmdline"):
        print(f"  extra_cmdline        = {h['extra_cmdline']!r}")

    if cmd == "info":
        return

    os.makedirs(outdir, exist_ok=True)
    f.seek(0)
    for name, size in sections:
        if not size:
            continue
        f.seek(off)
        blob = f.read(size)
        kind = sniff(blob)
        ext = {"gzip": "img.gz", "raw": "img", "dtb": "dtb",
               "cpio": "cpio", "cpio_newc": "cpio", "xz": "xz",
               "lz4_legacy": "lz4", "lz4": "lz4", "zstd": "zst"}.get(kind, "bin")
        # detect appended DTB inside kernel blob
        note = ""
        if kind == "gzip":
            idx = blob.find(DTB_MAGIC, 0x1000)
            if idx > 0:
                note = f" (+appended dtb at 0x{idx:x})"
        out = os.path.join(outdir, f"{name}.{ext}")
        with open(out, "wb") as o:
            o.write(blob)
        print(f"  wrote {out:40s} {size:>9} bytes  [{kind}]{note}")
        off = align(off + size, h["page_size"])


if __name__ == "__main__":
    main()
