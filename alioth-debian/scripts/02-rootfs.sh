#!/bin/bash
# Build Debian trixie arm64 rootfs + inject all alioth device layers.
# RUN INSIDE THE ARM64 VM (uses sudo).
set -euo pipefail
. "$(dirname "$0")/env.sh"

# 1. base system ------------------------------------------------------------
# fresh target each run (mmdebstrap refuses a non-empty directory)
sudo rm -rf "$ROOTFS"
# Ubuntu 26.04: firmware is split per vendor; Debian's firmware-atheros /
# firmware-qcom-soc packages do not exist here.  Only the two Qualcomm
# subpackages we need are installed (graphics ~10 MB, wireless ~47 MB);
# device-specific firmware still comes from the N1kroks tarball below.
sudo mmdebstrap --arch=arm64 --variant=minbase \
  --components="$DEB_COMPONENTS" \
  --include="systemd,systemd-sysv,udev,kmod,initramfs-tools,busybox,network-manager,openssh-server,sudo,passwd,vim-tiny,phosh,phosh-common,phosh-mobile-tweaks,phosh-osk-stevia,squeekboard,feedbackd,gnome-session-bin,gnome-settings-daemon,mesa-utils,mesa-vulkan-drivers,linux-firmware-qualcomm-graphics,linux-firmware-qualcomm-wireless,alsa-utils,alsa-ucm-conf,pipewire,wireplumber,iio-sensor-proxy,bluez,wpasupplicant,locales,ca-certificates,dropbear-initramfs,libcap2-bin" \
  "$DEB_SUITE" "$ROOTFS" "$DEB_MIRROR"

# 2. kernel modules ---------------------------------------------------------
# Ubuntu's kmod does not create /usr/lib/modules; make the version directory
# explicitly (a bare `cp -a src dest/` would flatten the tree).
sudo mkdir -p "$ROOTFS/usr/lib/modules/$KVER"
sudo cp -a "$OUT/kernel/modules/$KVER/." "$ROOTFS/usr/lib/modules/$KVER/"
# Arch package artifact: dangling out-of-tree module link, not used on Debian/Ubuntu
sudo rm -f "$ROOTFS/usr/lib/modules/$KVER/extramodules"
sudo depmod -b "$ROOTFS" "$KVER"

# 3. device firmware --------------------------------------------------------
sudo rm -rf "$FW_DIR"
sudo tar -xf "$FW_TGZ" -C "$OUT"
install_from_list() {  # <list-file>
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    dst="$ROOTFS/${f#./}"
    sudo mkdir -p "$(dirname "$dst")"
    sudo cp "$FW_DIR/$f" "$dst"
  done < "$1"
}
install_from_list "$FILES/firmware.files"
install_from_list "$FILES/sensor.files"

# GPU / Wi-Fi firmware comes from the Ubuntu split packages
# (linux-firmware-qualcomm-graphics / -wireless); warn if absent.
for fw in qcom/a650_sqe.fw qcom/a650_gmu.bin ath11k/QCA6390/hw2.0/amss.bin; do
  # Ubuntu ships these compressed; the kernel has FW_LOADER_COMPRESS_ZSTD=y
  [ -e "$ROOTFS/lib/firmware/$fw" ] || [ -e "$ROOTFS/lib/firmware/$fw.zst" ] || \
    echo "WARN: $ROOTFS/lib/firmware/$fw{,.zst} missing — check linux-firmware-qualcomm-*"
done

# 4. alsa UCM / udev / NetworkManager ---------------------------------------
sudo install -Dm644 "$FILES/alsa/alioth.conf" "$ROOTFS/usr/share/alsa/ucm2/Xiaomi/alioth/alioth.conf"
sudo install -Dm644 "$FILES/alsa/HiFi.conf"   "$ROOTFS/usr/share/alsa/ucm2/Xiaomi/alioth/HiFi.conf"
sudo mkdir -p "$ROOTFS/usr/share/alsa/ucm2/conf.d/sm8250"
sudo ln -sf ../../Xiaomi/alioth/alioth.conf "$ROOTFS/usr/share/alsa/ucm2/conf.d/sm8250/xiaomi-alioth.conf"
sudo install -Dm644 "$FILES/rules/81-libssc-xiaomi-alioth.rules" "$ROOTFS/usr/lib/udev/rules.d/"
sudo install -Dm644 "$FILES/rules/wifi-powersave.conf" "$ROOTFS/etc/NetworkManager/conf.d/"

# device identity, Phosh output scale and Qualcomm audio defaults
# (sources: Kupfer device-sm8250-xiaomi-alioth, pmOS soc-qcom)
sudo install -Dm644 "$FILES/machine-info" "$ROOTFS/etc/machine-info"
sudo install -Dm644 "$FILES/phosh-rootston.ini" "$ROOTFS/etc/phosh/rootston.ini"
sudo install -Dm644 "$FILES/51-qcom.conf" "$ROOTFS/usr/share/wireplumber/wireplumber.conf.d/51-qcom.conf"
sudo tee "$ROOTFS/etc/NetworkManager/conf.d/usb0-unmanaged.conf" >/dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:usb0
EOF

# 5. qualcomm userspace daemons (qbootctl mandatory, rest best-effort) ------
"$SCRIPTS/10-daemons.sh"

# 6. usb ncm gadget (rescue network, pmOS convention) ------------------------
sudo install -Dm755 "$FILES/usb-gadget.sh" "$ROOTFS/usr/local/sbin/usb-gadget"
sudo install -Dm644 "$FILES/usb-gadget.service" "$ROOTFS/etc/systemd/system/usb-gadget.service"

# 6b. battery charge window (start <=60%, stop >=70%) ------------------------
sudo install -Dm755 "$FILES/charge-threshold.sh" "$ROOTFS/usr/local/sbin/charge-threshold"
sudo install -Dm644 "$FILES/charge-threshold.service" "$ROOTFS/etc/systemd/system/charge-threshold.service"
sudo install -Dm644 "$FILES/charge-threshold.default" "$ROOTFS/etc/default/charge-threshold"

# 6c. power key: short press = lock + screen off/on, long press = shutdown dialog
# (GNOME's own power-button action is set to "nothing" by the schema override)
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

# 7. system config -----------------------------------------------------------
echo alioth | sudo tee "$ROOTFS/etc/hostname" >/dev/null
echo "$ROOT_PART / ext4 noatime,errors=remount-ro 0 1" | sudo tee "$ROOTFS/etc/fstab" >/dev/null

# display/touch/remote-processor modules must exist before udev/graphical boot
sudo install -Dm644 "$FILES/modules-load-alioth.conf" "$ROOTFS/etc/modules-load.d/alioth.conf"

# mark the current A/B slot successful, otherwise ABL falls back to slot A
sudo install -Dm644 "$FILES/qbootctl.service" "$ROOTFS/etc/systemd/system/qbootctl.service"

# initramfs rescue: USB NCM+ACM gadget + dropbear, so a failed root mount is
# still reachable over the cable (172.16.42.1).
sudo tee -a "$ROOTFS/etc/initramfs-tools/modules" >/dev/null < "$FILES/initramfs-modules"
sudo install -Dm755 "$FILES/initramfs-usb-gadget" \
  "$ROOTFS/etc/initramfs-tools/scripts/init-premount/00-usb-gadget"
sudo install -Dm755 "$FILES/initramfs-hook-usb-gadget" \
  "$ROOTFS/etc/initramfs-tools/hooks/usb-gadget"
if [ -f "$WORK/private/rescue_authorized_keys" ]; then
  sudo install -Dm600 "$WORK/private/rescue_authorized_keys" \
    "$ROOTFS/etc/dropbear/initramfs/authorized_keys"
  sudo install -Dm600 "$WORK/private/rescue_authorized_keys" \
    "$ROOTFS/root/.ssh/authorized_keys"
else
  echo "WARN: private/rescue_authorized_keys missing — initramfs SSH will have no key"
fi

sudo chroot "$ROOTFS" systemctl enable usb-gadget.service qbootctl.service \
  charge-threshold.service alioth-powerkey.service NetworkManager ssh \
  serial-getty@ttyGS0.service phosh.service 2>/dev/null || \
  echo "WARN: systemctl enable failed (expected before first chroot boot on some setups)"
sudo chroot "$ROOTFS" systemctl set-default graphical.target 2>/dev/null || \
  echo "WARN: could not set graphical.target as default"
echo 'root:root' | sudo chroot "$ROOTFS" chpasswd
# phosh.service is hardcoded to User=1000
sudo chroot "$ROOTFS" useradd -u 1000 -m -G sudo -s /bin/bash user 2>/dev/null || true
echo 'user:user' | sudo chroot "$ROOTFS" chpasswd
# rescue device: allow root password SSH over the usb0 link; change after first boot
sudo tee "$ROOTFS/etc/ssh/sshd_config.d/10-alioth-rescue.conf" >/dev/null <<EOF
PermitRootLogin yes
EOF

echo "OK: rootfs ready at $ROOTFS"
