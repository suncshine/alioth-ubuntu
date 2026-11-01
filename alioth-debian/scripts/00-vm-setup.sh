#!/bin/bash
# Run ONCE inside the freshly created arm64 Ubuntu 24.04 VM.
# Installs everything scripts/02..04 and 10 need.
set -euo pipefail
sudo apt update
sudo apt install -y \
  git curl wget xz-utils zstd cpio rsync e2fsprogs python3 \
  mmdebstrap debootstrap \
  android-sdk-libsparse-utils u-boot-tools device-tree-compiler \
  build-essential pkg-config bc meson ninja-build cmake \
  libssl-dev libudev-dev libxml2-dev zlib1g-dev linux-libc-dev \
  ubuntu-keyring \
  sudo
mmdebstrap --version && img2simg 2>&1 | head -1 || true
echo "VM dependencies ready."
