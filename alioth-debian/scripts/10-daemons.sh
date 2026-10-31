#!/bin/bash
# Build the Qualcomm userspace tools on the VM and install into the rootfs.
# qbootctl is MANDATORY (A/B slot success marking); the rest are best-effort
# extras for modem/audio/sensors — build failures are logged, not fatal.
# Sources verified 2026-10: linux-msm org + sm8250-mainline/N1kroks on GitLab.
set -uo pipefail
. "$(dirname "$0")/env.sh"

BUILD="$WORK/build"
mkdir -p "$BUILD"
clone() { [ -d "$BUILD/$1/.git" ] || git clone --depth=1 "$2" "$BUILD/$1" 2>&1 | tail -1; }

clone qbootctl    https://github.com/linux-msm/qbootctl
clone qrtr        https://github.com/linux-msm/qrtr
clone rmtfs       https://github.com/linux-msm/rmtfs
clone pd-mapper   https://github.com/linux-msm/pd-mapper
clone tqftpserv   https://github.com/linux-msm/tqftpserv
clone hexagonrpcd https://gitlab.com/sm8250-mainline/hexagonrpcd
clone bootmac     https://gitlab.com/N1kroks/bootmac

install_bin() { sudo install -Dm755 "$1" "$ROOTFS/usr/local/bin/$(basename "$1")"; }

build_auto() {  # <dir> — try meson, then cmake, then make; echo binary names found
  local d="$1" out=""
  if [ -f "$d/meson.build" ]; then
    meson setup "$d/build" "$d" >/dev/null 2>&1 && ninja -C "$d/build" >/dev/null 2>&1 && out="$d/build"
  elif [ -f "$d/CMakeLists.txt" ]; then
    cmake -S "$d" -B "$d/build" >/dev/null 2>&1 && cmake --build "$d/build" -j"$(nproc)" >/dev/null 2>&1 && out="$d/build"
  elif [ -f "$d/Makefile" ]; then
    make -C "$d" -j"$(nproc)" >/dev/null 2>&1 && out="$d"
  fi
  [ -n "$out" ] && find "$out" -maxdepth 1 -type f -executable ! -name "*.so*" | head -5
}

echo "== qbootctl (required) =="
bins=$(build_auto "$BUILD/qbootctl") || true
if [ -z "$bins" ]; then
  echo "FATAL: qbootctl failed to build — inspect $BUILD/qbootctl and fix manually."
  echo "Without it the bootloader may fall back to slot A after a few reboots."
  exit 1
fi
for b in $bins; do install_bin "$b"; echo "  installed $(basename "$b")"; done

echo "== optional daemons (best-effort) =="
for repo in qrtr rmtfs pd-mapper tqftpserv hexagonrpcd bootmac; do
  bins=$(build_auto "$BUILD/$repo") || true
  if [ -n "$bins" ]; then
    for b in $bins; do install_bin "$b"; echo "  $repo: installed $(basename "$b")"; done
  else
    echo "  $repo: build failed (optional — modem/audio/sensors only); inspect $BUILD/$repo"
  fi
done

echo "done. NOTE: systemd units for the optional daemons are not yet generated —"
echo "mirror Kupfer's etc/kupfer/systemd/*.lst (tqftpserv/rmtfs/pd-mapper/hexagonrpcd-sdsp/bootmac-bluetooth) when adding them."
