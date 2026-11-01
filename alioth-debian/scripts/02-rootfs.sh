#!/bin/bash
# Build Ubuntu 26.04 (resolute) arm64 GNOME rootfs + all alioth device layers.
# RUN INSIDE AN ARM64 LINUX BUILD HOST (the UTM VM or the phone itself),
# as a user with sudo/root.
#
# The package set mirrors the working 2026-11-01 system:
#   ubuntu-desktop-minimal (GDM + GNOME Shell + ubuntu-session) + the curated
#   app list in files/desktop-apps.txt, PipeWire/WirePlumber, libcamera,
#   hexagonrpcd/iio-sensor-proxy, qrtr-tools, wireless-regdb.
#
# Device layers added after mmdebstrap:
#   kernel modules + firmware, audio UCM (WCD938x, 4 mics), camera modules and
#   PipeWire soft-ISP drop-ins, SSC sensor stack, charge threshold, power key,
#   dconf defaults, GDM auto-login, display config, USB NCM rescue gadget,
#   qbootctl, initramfs hooks and rescue SSH keys.
#
# Usage:
#   ./02-rootfs.sh                     # full build
#   ./02-rootfs.sh --skip-apps         # no files/desktop-apps.txt packages
#   ./02-rootfs.sh --skip-camera       # no imx582/dw9800 modules/drop-ins
#   ./02-rootfs.sh --skip-sensors      # no libssc/SSC userspace
#   ./02-rootfs.sh --build-daemons     # build qbootctl from source (10-daemons)
#   ./02-rootfs.sh --no-daemon-build   # copy qbootctl from the host (default)
#   ./02-rootfs.sh --reuse-rootfs      # skip mmdebstrap, rerun only the layers
#                                     # (useful when a post-install step failed)
#   ./02-rootfs.sh --no-rescue-key     # do not embed a host SSH key (public image)
#
# Requirements on the host: mmdebstrap, dtc/fdtget/fdtput, depmod, and either
# $OUT/kernel/modules/$KVER or a native /lib/modules/$KVER for the target.
set -euo pipefail
. "$(dirname "$0")/env.sh"

SKIP_APPS=0
SKIP_CAMERA=0
SKIP_SENSORS=0
BUILD_DAEMONS=0
REUSE=0
NO_RESCUE_KEY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-apps)       SKIP_APPS=1; shift ;;
    --skip-camera)     SKIP_CAMERA=1; shift ;;
    --skip-sensors)    SKIP_SENSORS=1; shift ;;
    --build-daemons)   BUILD_DAEMONS=1; shift ;;
    --no-daemon-build) BUILD_DAEMONS=0; shift ;;
    --reuse-rootfs)    REUSE=1; shift ;;
    --no-rescue-key)   NO_RESCUE_KEY=1; shift ;;
    -h|--help)         sed -n '2,42p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

command -v mmdebstrap >/dev/null || die "mmdebstrap missing (apt install mmdebstrap)"
command -v dtc >/dev/null || die "dtc missing (apt install device-tree-compiler)"
command -v depmod >/dev/null || die "depmod missing (apt install kmod)"
command -v sudo >/dev/null || die "sudo missing"

# 1. package list ------------------------------------------------------------
# Minimal but complete GNOME desktop.  Recommends are disabled by mmdebstrap;
# the user-visible apps come from files/desktop-apps.txt below.
BASE_PKGS="
systemd systemd-sysv udev kmod initramfs-tools busybox gzip zstd systemd-zram-generator
network-manager openssh-server sudo passwd vim-tiny locales ca-certificates
dropbear-initramfs libcap2-bin
alsa-utils alsa-ucm-conf pipewire pipewire-pulse wireplumber
bluez wpasupplicant
dconf-cli systemd-timesyncd polkitd upower xwayland
mesa-utils mesa-vulkan-drivers
linux-firmware-qualcomm-graphics linux-firmware-qualcomm-wireless wireless-regdb
ubuntu-desktop-minimal ubuntu-session gdm3 gnome-shell gnome-session-bin
gnome-settings-daemon gnome-software gnome-software-plugin-deb gnome-snapshot
gnome-terminal gnome-system-monitor
libcamera-tools libcamera-ipa libcamera-v4l2 libspa-0.2-libcamera
gstreamer1.0-libcamera v4l-utils
iio-sensor-proxy hexagonrpcd libqmi-glib5 libqrtr-glib0 libmbim-glib4
libprotobuf-c1 qrtr-tools
"

PKGS="$BASE_PKGS"
if [ "$SKIP_APPS" -eq 0 ]; then
  APPS="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$FILES/desktop-apps.txt" | grep -v '^$' | tr '\n' ' ')"
  PKGS="$PKGS $APPS"
fi
INCLUDE="$(printf '%s\n' $PKGS | awk 'NF && !seen[$0]++' | paste -sd, -)"
[ "$REUSE" -eq 1 ] || \
  log "installing $(printf '%s\n' "$INCLUDE" | tr ',' '\n' | wc -l | tr -d ' ') packages"

# 2. mmdebstrap --------------------------------------------------------------
if [ "$REUSE" -eq 0 ]; then
  sudo rm -rf "$ROOTFS"

  APT_OPTS=(--aptopt='Apt::Install-Recommends "false"')

  sudo mmdebstrap --arch=arm64 --variant=minbase \
    --components="$DEB_COMPONENTS" \
    "${APT_OPTS[@]}" \
    --include="$INCLUDE" \
    "$DEB_SUITE" "$ROOTFS" "$DEB_MIRROR"

  # --aptopt is persisted by mmdebstrap in 99mmdebstrap, but
  # Install-Recommends=false is a build-only setting; drop the generated file
  # so the image keeps stock apt behaviour.
  sudo rm -f "$ROOTFS/etc/apt/apt.conf.d/99mmdebstrap"
else
  [ -f "$ROOTFS/etc/os-release" ] \
    || die "--reuse-rootfs: $ROOTFS is not an existing rootfs"
  log "reusing existing rootfs: $ROOTFS (package install skipped)"
fi

# 3. kernel modules ----------------------------------------------------------
# Prefer the kernel package extracted by 01-kernel.sh; when building on the
# phone itself, copy the running 7.2.0 tree (headers/build and extra are
# excluded; the camera modules are installed separately in step 8).
KMOD_SRC="$OUT/kernel/modules/$KVER"
if [ ! -d "$KMOD_SRC" ] && [ -d "/lib/modules/$KVER" ]; then
  KMOD_SRC="/lib/modules/$KVER"
fi
[ -d "$KMOD_SRC" ] || die "kernel modules for $KVER not found (run 01-kernel.sh or build on the phone)"
log "kernel modules: $KMOD_SRC"
sudo mkdir -p "$ROOTFS/usr/lib/modules/$KVER"
sudo cp -a "$KMOD_SRC/." "$ROOTFS/usr/lib/modules/$KVER/"
sudo rm -rf "$ROOTFS/usr/lib/modules/$KVER/build" \
            "$ROOTFS/usr/lib/modules/$KVER/source" \
            "$ROOTFS/usr/lib/modules/$KVER/extra"
# Arch package artifact: dangling out-of-tree module link, not used on Ubuntu
sudo rm -f "$ROOTFS/usr/lib/modules/$KVER/extramodules"
sudo depmod -b "$ROOTFS" "$KVER"

# 4. device firmware ---------------------------------------------------------
install_from_n1kroks() {  # <list-file> — paths relative to the tarball root
  local f src dst
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    src="$FW_DIR/$f"
    dst="$ROOTFS/${f#./}"
    sudo mkdir -p "$(dirname "$dst")"
    sudo cp "$src" "$dst"
  done < "$1"
}
install_from_host() {  # <list-file> — paths relative to / on this host
  local f src dst
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    src="/${f#./}"
    dst="$ROOTFS/${f#./}"
    [ -e "$src" ] || die "host firmware missing: $src"
    sudo mkdir -p "$(dirname "$dst")"
    sudo cp -a "$src" "$dst"
  done < "$1"
}

if [ -f "$FW_TGZ" ]; then
  log "firmware: $FW_TGZ"
  sudo rm -rf "$FW_DIR"
  sudo tar -xf "$FW_TGZ" -C "$OUT"
  install_from_n1kroks "$FILES/firmware.files"
  install_from_n1kroks "$FILES/sensor.files"
else
  log "firmware: copying from host /lib/firmware and /usr/share/qcom"
  install_from_host "$FILES/firmware.files"
  install_from_host "$FILES/sensor.files"
fi

# GPU / Wi-Fi firmware comes from the Ubuntu split packages
# (linux-firmware-qualcomm-graphics / -wireless); warn if absent.
for fw in qcom/a650_sqe.fw qcom/a650_gmu.bin ath11k/QCA6390/hw2.0/amss.bin; do
  [ -e "$ROOTFS/lib/firmware/$fw" ] || [ -e "$ROOTFS/lib/firmware/$fw.zst" ] || \
    echo "WARN: $ROOTFS/lib/firmware/$fw{,.zst} missing — check linux-firmware-qualcomm-*"
done

# 5. audio UCM / udev / NetworkManager / WirePlumber -------------------------
# HiFi.conf is the WCD938x + 4-mic version from the audio work (files/audio),
# not the old Phosh-era files/alsa copy.
sudo install -Dm644 "$FILES/alsa/alioth.conf" "$ROOTFS/usr/share/alsa/ucm2/Xiaomi/alioth/alioth.conf"
sudo install -Dm644 "$FILES/audio/HiFi.conf" "$ROOTFS/usr/share/alsa/ucm2/Xiaomi/alioth/HiFi.conf"
sudo mkdir -p "$ROOTFS/usr/share/alsa/ucm2/conf.d/sm8250"
sudo ln -sf ../../Xiaomi/alioth/alioth.conf "$ROOTFS/usr/share/alsa/ucm2/conf.d/sm8250/xiaomi-alioth.conf"
sudo install -Dm644 "$FILES/rules/81-libssc-xiaomi-alioth.rules" "$ROOTFS/usr/lib/udev/rules.d/"
sudo install -Dm644 "$FILES/rules/wifi-powersave.conf" "$ROOTFS/etc/NetworkManager/conf.d/"
sudo install -Dm644 "$FILES/machine-info" "$ROOTFS/etc/machine-info"
sudo install -Dm644 "$FILES/51-qcom.conf" "$ROOTFS/usr/share/wireplumber/wireplumber.conf.d/51-qcom.conf"
# 2 GiB zstd zram swap; the generator creates it at boot (no disk swap).
sudo install -Dm644 "$FILES/zram-generator.conf" "$ROOTFS/etc/systemd/zram-generator.conf"
sudo tee "$ROOTFS/etc/NetworkManager/conf.d/usb0-unmanaged.conf" >/dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:usb0
EOF

# 6. Qualcomm daemons --------------------------------------------------------
# qbootctl is mandatory (A/B slot success marking).  Prefer a host copy on a
# phone-side build; use --build-daemons on a clean VM.
if [ "$BUILD_DAEMONS" -eq 1 ]; then
  "$SCRIPTS/10-daemons.sh" || die "10-daemons.sh failed"
else
  QBOOTCTL="$(command -v qbootctl || true)"
  [ -n "$QBOOTCTL" ] || die "qbootctl not found on the host; rerun with --build-daemons"
  sudo install -Dm755 "$QBOOTCTL" "$ROOTFS/usr/local/bin/qbootctl"
fi

# 7. USB NCM rescue gadget ---------------------------------------------------
sudo install -Dm755 "$FILES/usb-gadget.sh" "$ROOTFS/usr/local/sbin/usb-gadget"
sudo install -Dm644 "$FILES/usb-gadget.service" "$ROOTFS/etc/systemd/system/usb-gadget.service"
sudo install -Dm644 "$FILES/80-alioth-usb-gadget.rules" \
  "$ROOTFS/etc/udev/rules.d/80-alioth-usb-gadget.rules"

# 8. camera: external modules + PipeWire soft-ISP drop-ins -------------------
if [ "$SKIP_CAMERA" -eq 0 ]; then
  "$SCRIPTS/13-camera-modules.sh" --root "$ROOTFS" --auto
else
  log "camera: skipped"
fi

# 9. SSC sensors userspace ---------------------------------------------------
if [ "$SKIP_SENSORS" -eq 0 ]; then
  "$SCRIPTS/20-sensors-ssc.sh" --root "$ROOTFS"
else
  log "sensors: skipped"
fi

# 10. battery charge window / power key / dconf / display --------------------
sudo install -Dm755 "$FILES/charge-threshold.sh" "$ROOTFS/usr/local/sbin/charge-threshold"
sudo install -Dm644 "$FILES/charge-threshold.service" "$ROOTFS/etc/systemd/system/charge-threshold.service"
sudo install -Dm644 "$FILES/charge-threshold.default" "$ROOTFS/etc/default/charge-threshold"

sudo install -Dm755 "$FILES/alioth-powerkey" "$ROOTFS/usr/local/sbin/alioth-powerkey"
sudo install -Dm644 "$FILES/alioth-powerkey.service" \
  "$ROOTFS/etc/systemd/system/alioth-powerkey.service"
sudo install -Dm644 "$FILES/90-alioth-settings.gschema.override" \
  "$ROOTFS/usr/share/glib-2.0/schemas/90_alioth.gschema.override"
if sudo chroot "$ROOTFS" test -x /usr/bin/glib-compile-schemas; then
  sudo chroot "$ROOTFS" glib-compile-schemas /usr/share/glib-2.0/schemas
else
  echo "WARN: glib-compile-schemas missing — power-button override not compiled"
fi
sudo install -Dm644 "$FILES/50-powerkey.conf" \
  "$ROOTFS/etc/systemd/logind.conf.d/50-powerkey.conf"

sudo install -Dm644 "$FILES/dconf/00-alioth" \
  "$ROOTFS/etc/dconf/db/local.d/00-alioth"
if sudo chroot "$ROOTFS" test -x /usr/bin/dconf; then
  sudo chroot "$ROOTFS" dconf update
else
  echo "WARN: dconf-cli missing — desktop defaults not compiled"
fi

# GDM auto-login and display configuration.
sudo install -Dm644 "$FILES/gdm/custom.conf" "$ROOTFS/etc/gdm3/custom.conf"
sudo install -Dm644 "$FILES/environment" "$ROOTFS/etc/environment"

# 11. system config ----------------------------------------------------------
echo alioth | sudo tee "$ROOTFS/etc/hostname" >/dev/null
echo "$ROOT_PART / ext4 noatime,errors=remount-ro 0 1" | sudo tee "$ROOTFS/etc/fstab" >/dev/null

# display/touch/remote-processor modules must exist before udev/graphical boot
sudo install -Dm644 "$FILES/modules-load-alioth.conf" "$ROOTFS/etc/modules-load.d/alioth.conf"

# mark the current A/B slot successful, otherwise ABL falls back to slot A
sudo install -Dm644 "$FILES/qbootctl.service" "$ROOTFS/etc/systemd/system/qbootctl.service"

# initramfs rescue: USB NCM+ACM gadget + dropbear, so a failed root mount is
# still reachable over the cable (172.16.42.1).
# Idempotent: --reuse-rootfs reruns this section.
if ! grep -qxF libcomposite "$ROOTFS/etc/initramfs-tools/modules" 2>/dev/null; then
  sudo tee -a "$ROOTFS/etc/initramfs-tools/modules" >/dev/null < "$FILES/initramfs-modules"
fi
# Keep MODULES=most (MODULES=dep cannot determine the root device in a
# chroot), but stop the DSP remoteproc driver from auto-loading inside the
# initramfs: the .mbn firmware lives in the rootfs, and an early failed probe
# leaves adsp/slpi/cdsp offline for the whole boot.  The rootfs loads
# qcom_q6v5_pas explicitly from modules-load.d after switch_root.
sudo sed -i 's/^MODULES=.*/MODULES=most/' "$ROOTFS/etc/initramfs-tools/initramfs.conf"
sudo install -Dm644 "$FILES/modprobe.d/alioth-remoteproc-initramfs.conf" \
  "$ROOTFS/etc/modprobe.d/alioth-remoteproc-initramfs.conf"
sudo install -Dm755 "$FILES/initramfs-usb-gadget" \
  "$ROOTFS/etc/initramfs-tools/scripts/init-premount/00-usb-gadget"
sudo install -Dm755 "$FILES/initramfs-hook-usb-gadget" \
  "$ROOTFS/etc/initramfs-tools/hooks/usb-gadget"
# MODULES=most puts qcom_q6v5_pas in the initramfs; include the firmware too so
# an early remoteproc probe cannot fail (see files/initramfs-hook-remoteproc-fw).
sudo install -Dm755 "$FILES/initramfs-hook-remoteproc-fw" \
  "$ROOTFS/etc/initramfs-tools/hooks/remoteproc-fw"
RESCUE_KEY="$WORK/private/rescue_authorized_keys"
if [ "$NO_RESCUE_KEY" -eq 1 ]; then
  log "rescue SSH key: skipped (--no-rescue-key)"
  # Also remove a key left by an earlier --reuse-rootfs build.
  sudo rm -f "$ROOTFS/etc/dropbear/initramfs/authorized_keys" \
              "$ROOTFS/root/.ssh/authorized_keys"
else
  [ -f "$RESCUE_KEY" ] || RESCUE_KEY=/root/.ssh/authorized_keys
  if [ -f "$RESCUE_KEY" ]; then
    sudo install -Dm600 "$RESCUE_KEY" "$ROOTFS/etc/dropbear/initramfs/authorized_keys"
    sudo install -Dm600 "$RESCUE_KEY" "$ROOTFS/root/.ssh/authorized_keys"
  else
    echo "WARN: no rescue authorized_keys found — initramfs SSH will have no key"
  fi
fi

# 12. user, display config, passwords ---------------------------------------
sudo chroot "$ROOTFS" useradd -u 1000 -m -G sudo -s /bin/bash user 2>/dev/null || true
# Force the Ubuntu GNOME session for GDM autologin even on a fresh account.
sudo install -d -m 700 "$ROOTFS/var/lib/AccountsService/users"
printf '[User]\nSession=ubuntu\nXSession=ubuntu\nSystemAccount=false\n' \
  | sudo tee "$ROOTFS/var/lib/AccountsService/users/user" >/dev/null
sudo chmod 600 "$ROOTFS/var/lib/AccountsService/users/user"
printf '[Desktop]\nSession=ubuntu\n' | sudo tee "$ROOTFS/home/user/.dmrc" >/dev/null
sudo chown 1000:1000 "$ROOTFS/home/user/.dmrc"
sudo install -Dm644 "$FILES/monitors.xml" "$ROOTFS/home/user/.config/monitors.xml"
sudo chown -R 1000:1000 "$ROOTFS/home/user/.config"
GDM_IDS="$(awk -F: '$1=="gdm"{print $3":"$4}' "$ROOTFS/etc/passwd")"
if [ -n "$GDM_IDS" ]; then
  sudo install -Dm644 "$FILES/monitors.xml" "$ROOTFS/var/lib/gdm3/.config/monitors.xml"
  sudo chown -R "$GDM_IDS" "$ROOTFS/var/lib/gdm3"
fi

# 13. enable services -------------------------------------------------------
sudo chroot "$ROOTFS" systemctl enable \
  usb-gadget.service qbootctl.service charge-threshold.service alioth-powerkey.service \
  NetworkManager.service ssh.service serial-getty@ttyGS0.service \
  systemd-timesyncd.service hexagonrpcd.service 2>/dev/null || \
  echo "WARN: systemctl enable failed (expected before first chroot boot on some setups)"
# GDM: the Ubuntu package ships gdm3.service (alias of gdm.service); enable the
# display-manager alias explicitly.
if sudo chroot "$ROOTFS" systemctl enable gdm3.service 2>/dev/null; then
  :
elif sudo chroot "$ROOTFS" systemctl enable gdm.service 2>/dev/null; then
  :
else
  echo "WARN: could not enable GDM"
fi
sudo chroot "$ROOTFS" systemctl set-default graphical.target 2>/dev/null || \
  echo "WARN: could not set graphical.target as default"

# 14. passwords / SSH -------------------------------------------------------
# WARNING: well-known default credentials. Change them immediately after the
# first boot (`passwd root`, `passwd user`); root SSH login stays enabled.
echo 'root:root' | sudo chroot "$ROOTFS" chpasswd
echo 'user:user' | sudo chroot "$ROOTFS" chpasswd
sudo tee "$ROOTFS/etc/ssh/sshd_config.d/10-alioth-rescue.conf" >/dev/null <<EOF
PermitRootLogin yes
EOF

# 15. keep the update scripts for post-boot use -----------------------------
sudo install -Dm755 "$SCRIPTS/11-desktop-apps.sh" "$ROOTFS/usr/local/lib/alioth/11-desktop-apps.sh"
sudo install -Dm755 "$SCRIPTS/12-desktop-settings.sh" "$ROOTFS/usr/local/lib/alioth/12-desktop-settings.sh"
sudo install -Dm644 "$FILES/desktop-apps.txt" "$ROOTFS/usr/local/share/alioth/desktop-apps.txt"

# 16. clean up --------------------------------------------------------------
sudo chroot "$ROOTFS" apt-get clean 2>/dev/null || true
sudo rm -rf "$ROOTFS/var/lib/apt/lists"/* "$ROOTFS/var/cache/apt/archives"/*.deb

# Build-host state that must not ship in a redistributable image.
# 95proxy is only present in rootfs trees produced by older build scripts.
sudo rm -f "$ROOTFS/etc/apt/apt.conf.d/95proxy"
if [ -f "$ROOTFS/etc/resolv.conf" ] && [ ! -L "$ROOTFS/etc/resolv.conf" ]; then
  echo "nameserver 1.1.1.1" | sudo tee "$ROOTFS/etc/resolv.conf" >/dev/null
fi
# Host keys and machine-id are generated on first boot, not shared by every
# device that flashes the image.
sudo rm -f "$ROOTFS"/etc/ssh/ssh_host_*
sudo rm -f "$ROOTFS/etc/machine-id" "$ROOTFS/var/lib/dbus/machine-id" \
           "$ROOTFS/var/lib/systemd/random-seed"
sudo install -Dm644 "$FILES/ssh-host-keys.service" \
  "$ROOTFS/etc/systemd/system/ssh-host-keys.service"
sudo chroot "$ROOTFS" systemctl enable ssh-host-keys.service 2>/dev/null || \
  echo "WARN: could not enable ssh-host-keys.service"
sudo rm -rf "$ROOTFS"/var/log/* "$ROOTFS"/var/log/journal
sudo find "$ROOTFS/root" "$ROOTFS/home/user" -maxdepth 2 \
  -name '.bash_history' -delete 2>/dev/null || true

echo "OK: rootfs ready at $ROOTFS"
echo "Next: 03-initramfs.sh (initrd), 04-bootimg.sh (ext4 + boot image)."
echo "Firefox is not included (no arm64 deb; snapd unusable): after first boot run"
echo "  sudo /usr/local/lib/alioth/11-desktop-apps.sh --refresh-firefox"
