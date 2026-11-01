# Kernel artifact and configuration (7.2.0)

The production boot images use a **locally rebuilt 7.2.0 kernel**.  The
current build adds the first-frame backlight fix for the command-mode panel
(see below); the previous artifact also carried `CONFIG_DEVFREQ_THERMAL=y` so
the GPU devfreq cooling device registers.

## Tracked here

- `config-7.2.0-alioth` — the `.config` used for the pre-first-frame build.
  SHA256 `1a36587425c2fc4dea29059e2c694509bbf4952bd7c3af10e36950eaff4422cf`.
- `config.fragment` — build-time additions on top of the Kupfer config:
  `CONFIG_DEVFREQ_THERMAL=y` and, for the first-frame build,
  `CONFIG_DRM_PANEL_SAMSUNG_AMS667XX01=y` (panel driver built into Image.gz).
- `0001-drm-delay-backlight-until-first-frame.patch` — DRM panel/bridge core
  and DPU CRTC changes. SHA256
  `1e94f6835535d9d5bce6355efa7a8525f7e7f5ea588ab5f963dc18bf1b972ddd`.
- `0002-panel-samsung-ams667xx01-delay-backlight.patch` — sets
  `defer_backlight_until_first_frame` in the alioth panel driver; applies on
  top of the Kupfer panel patch. SHA256
  `b93c129fd95bb9b9c6f0b1a588732ea67f58d4a4cc93bbf98c59e22612511349`.
- `README.md` — this file.

## First-frame backlight fix

The alioth panel is a command-mode panel: after power-up its internal frame
memory (GRAM) contains undefined data.  The vendor device tree marks it with
`qcom,bl-update-flag = "delay_until_first_frame"`, and the vendor display
driver waits for `MSM_ENC_TX_COMPLETE` before calling
`backlight_update_status()`.  Mainline `drm_panel_enable()` instead enabled
the backlight in the panel enable callback, before the first frame was
transferred, so waking the screen showed ~1 s of GRAM garbage.

The fix keeps the backlight off until the DPU has reported the first
frame-done event after a CRTC enable:

1. `drm_panel` gains `defer_backlight_until_first_frame` /
   `backlight_deferred`; `drm_panel_enable()` skips `backlight_enable()` and
   `drm_panel_first_frame_done()` performs it later.
2. `drm_bridge` gains an optional `first_frame_done` op and
   `drm_bridge_chain_first_frame_done()`; the panel bridge forwards it.
3. `dpu_crtc` arms `first_frame_pending` in `dpu_crtc_enable()` and calls the
   bridge chain notification from `dpu_crtc_frame_event_work()` after the
   first `DPU_ENCODER_FRAME_EVENT_DONE`.
4. The alioth panel driver opts in.

Do not move the notification into `msm_atomic_commit_tail()` after
`wait_flush()`: for command-mode encoders that wait is satisfied by the
CTL-start IRQ, not by ping-pong/frame-done, so the backlight would still be
enabled ~20 ms before the pixels reach the panel.

The panel driver is built in (`=y`) so the fix is part of Image.gz without
having to repack the initramfs with a rebuilt module; the prebuilt Kupfer
module was compiled from a different tree.  The old
`panel-samsung-ams667xx01.ko.zst` therefore must not be loaded from the
rootfs; `modules-load-alioth.conf` no longer lists it.  udev may still try
the OF modalias once and log `Driver 'panel-samsung-ams667xx01' is already
registered`; this is harmless but will disappear once the stale module is
dropped from the rootfs/initramfs (tracked as tech debt in AGENTS.md).

## Artifacts

- First-frame `Image.gz`: 14,727,626 B, SHA256
  `a53411d9687a6c8261e19227a03a10925d11ecbda31eb635c09ac61e0a157b6d`.
- Production boot image `out/boot-production-firstframe.img`: 58,687,488 B,
  SHA256 `70519c4cd6768ea108198d1b477d5af8bbe2a0eab1a8d46042e385a3e0122404`.
  Its appended DTB (`a5c3be61…`) and 42 MB initrd (`afb37c1b…`, with DSP
  firmware) are byte-identical to `boot-production-final.img`; only the
  kernel changed.
- Pre-fix artifact (kept for rollback): `Image.gz` 14,724,749 B, SHA256
  `54b4b14a4c533fd6b4cd18c66eb8b0093ce44f9817296ab1239b6ac9748b8292`;
  boot image `out/boot-production-final.img`, SHA256 `8d6447a7…`.

## Source provenance

Kupfer sm8250/alioth kernel 7.2.0 (branch `7.2.0`, commit `71f4068`) plus the
panel/touchscreen patch archived under
`references/kupfer-alioth-builds/patches/gitlab.postmarketos.org/soc/qualcomm-sm8250/linux/`.
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
patch -Np1 -d linux < \
  references/kupfer-alioth-builds/patches/gitlab.postmarketos.org/soc/qualcomm-sm8250/linux/0001-Added-POCO-F3-dts-panel-and-touchscreen-drivers.patch
patch -Np1 -d linux < alioth-debian/files/kernel/0001-drm-delay-backlight-until-first-frame.patch
patch -Np1 -d linux < alioth-debian/files/kernel/0002-panel-samsung-ams667xx01-delay-backlight.patch
cat alioth-debian/files/kernel/config.fragment >> linux/.config
make -C linux olddefconfig
make -C linux -j$(nproc) Image.gz
sha256sum linux/arch/arm64/boot/Image.gz
```

The panel Kconfig entry must exist (first patch) before `olddefconfig` so the
fragment's `CONFIG_DRM_PANEL_SAMSUNG_AMS667XX01=y` is accepted.  A rebuild can
differ byte-wise from the artifact above because compiler patch level and
build paths/timestamps are embedded; verify the image on the device before
replacing the known-good artifact.

Pack the boot image with the unchanged DTB/initrd:

```sh
KERNEL_IMG=/path/to/Image.gz ALLOW_OTHER_KERNEL=1 \
  ./alioth-debian/scripts/16-production-boot-source.sh
```

`16-production-boot-source.sh` checks the kernel hash against
`EXPECTED_KERNEL_SHA`; it is set to the first-frame artifact.  Use
`ALLOW_OTHER_KERNEL=1` for local rebuilds.
