#!/bin/bash
# Flash the images to the phone. RUN ON MACOS (fastboot on the host).
set -euo pipefail
. "$(dirname "$0")/env.sh"

PRIVATE="${PRIVATE:-$WORK/private}"
: "${ANDROID_SERIAL:?set ANDROID_SERIAL to the phone serial (see: fastboot devices)}"
FB=(fastboot -s "$ANDROID_SERIAL")

"${FB[@]}" devices 2>/dev/null | awk '{print $1}' | grep -qx "$ANDROID_SERIAL" || {
  echo "no fastboot device for serial $ANDROID_SERIAL — is the phone in bootloader mode?"
  exit 1
}

# Recovery anchors: never wipe a device we cannot restore.
for f in boot_a.img boot_b.img; do
  [ -s "$PRIVATE/$f" ] || {
    echo "missing $PRIVATE/$f — back up both boot slots before flashing."
    exit 1
  }
done
[ -s "$BOOT_IMG" ] || { echo "missing $BOOT_IMG (run 04-bootimg.sh)"; exit 1; }
[ -s "$ROOT_IMG_SPARSE" ] || { echo "missing $ROOT_IMG_SPARSE (run 04-bootimg.sh)"; exit 1; }

if [ "${CONFIRM_WIPE:-0}" != "1" ]; then
  cat <<EOF
This will:
  - erase dtbo_b
  - flash boot_b with $BOOT_IMG
  - OVERWRITE userdata with $ROOT_IMG_SPARSE (all current data is lost)
  - set active slot b and reboot
Re-run with CONFIRM_WIPE=1 to proceed.
EOF
  exit 2
fi

"${FB[@]}" getvar current-slot 2>&1 | tail -1
"${FB[@]}" getvar unlocked 2>&1 | tail -1

"${FB[@]}" erase dtbo_b
"${FB[@]}" flash boot_b "$BOOT_IMG"
"${FB[@]}" flash userdata "$ROOT_IMG_SPARSE"
"${FB[@]}" set_active b
"${FB[@]}" reboot

echo "flashed. after boot: ssh root@$PHONE_IP (Mac side: sudo ifconfig enX inet $HOST_IP netmask 255.255.255.0 up)"
