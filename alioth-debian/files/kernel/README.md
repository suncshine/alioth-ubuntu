# Kernel artifact and configuration (7.2.0)

The production boot images use a **locally rebuilt 7.2.0 kernel** with
`CONFIG_DEVFREQ_THERMAL=y`; the Kupfer prebuilt `Image.gz` lacks it, so the
GPU devfreq cooling device never registers.

## Tracked here

- `config-7.2.0-alioth` — the exact `.config` used for the rebuilt kernel.
  SHA256 `1a36587425c2fc4dea29059e2c694509bbf4952bd7c3af10e36950eaff4422cf`.
- `config.fragment` — the only intentional build-time addition
  (`CONFIG_DEVFREQ_THERMAL=y`), useful when starting from a fresh Kupfer config.
- `README.md` — this file.

## Artifact

- `Image.gz` size 14,724,749 B
- SHA256 `54b4b14a4c533fd6b4cd18c66eb8b0093ce44f9817296ab1239b6ac9748b8292`
- The same `Image.gz` is embedded (byte-for-byte) in every current production
  boot image (`audio`, `wifimac`, `camera`, `camera-splash`).
- Compiler: gcc 15.2.0 (Ubuntu 15.2.0-16ubuntu1), GNU ld 2.46; built on the
  phone itself with `make Image.gz`.
- `CONFIG_LOCALVERSION=""` (`make kernelrelease` = `7.2.0`),
  `CONFIG_MODVERSIONS` and `CONFIG_MODULE_SIG` are off, so out-of-tree modules
  remain ABI-compatible.
- `CONFIG_IKCONFIG=y` / `CONFIG_IKCONFIG_PROC=y`; the device exposes the
  running config at `/proc/config.gz`.

## Source provenance

Kupfer sm8250/alioth kernel 7.2.0 (project notes record commit `71f4068`).
The 242 MB source tarball is **not** in git; the copy used for the build is on
the phone:

- `/root/kernel-build/linux-src.tar.zst`
- SHA256 `ad3f4fd8accc2f6dc3c422c6e360c3b251755c55b895b236655e98e65db669e3`

The extracted tree on the phone (`/root/kernel-build/linux`) is also the
`KSRC` used by `scripts/07-audio-dtb.sh` to preprocess the alioth DTS.

## Rebuild

```sh
tar --zstd -xf linux-src.tar.zst
cp alioth-debian/files/kernel/config-7.2.0-alioth linux/.config
make -C linux olddefconfig
make -C linux -j$(nproc) Image.gz
sha256sum linux/arch/arm64/boot/Image.gz
```

A rebuild can differ byte-wise from the artifact above because the compiler
patch level and build paths/timestamps are embedded; verify the image on the
device before replacing the known-good artifact.
