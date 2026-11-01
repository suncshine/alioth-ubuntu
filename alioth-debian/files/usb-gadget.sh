#!/bin/sh
# USB NCM + ACM gadget: gives the phone a static 172.16.42.1 so the Mac can
# always reach it over the data cable, even with no WiFi.
#
# This script is idempotent and safe to re-run. The kernel unbinds the gadget
# when the Type-C data role switches to host (OTG dock) and the UDC disappears;
# on the way back to peripheral the UDC re-appears and this script has to bind
# the configfs gadget again. usb-gadget.service is triggered from udev for
# exactly that case.
set -e

CONFIGFS=/sys/kernel/config/usb_gadget
GADGET=g1
CFG="$CONFIGFS/$GADGET"

# Serialize boot and udev invocations.
if command -v flock >/dev/null 2>&1; then
    exec 9>/run/usb-gadget.lock
    flock -w 10 9 || exit 0
fi

modprobe libcomposite 2>/dev/null || true
mkdir -p /sys/kernel/config
[ -d "$CONFIGFS" ] || mount -t configfs none /sys/kernel/config 2>/dev/null || true

if [ ! -d "$CFG" ]; then
    mkdir "$CFG"
    cd "$CFG"
    echo 0x0525 > idVendor      # NetChip
    echo 0xa4a2 > idProduct     # NCM generic
    mkdir strings/0x409
    echo "alioth-debian"   > strings/0x409/serialnumber
    echo "Xiaomi"          > strings/0x409/manufacturer
    echo "alioth (Debian)" > strings/0x409/product
    mkdir configs/c.1
    echo 250 > configs/c.1/MaxPower
    mkdir functions/ncm.usb0
    ln -s functions/ncm.usb0 configs/c.1/
    # second function: serial console (ttyGS0) for kernel log streaming
    mkdir functions/acm.usb0
    ln -s functions/acm.usb0 configs/c.1/
fi

# Bind the UDC if it is present and the gadget is not actually bound. After a
# host->device role switch the configfs UDC attribute can still hold the old
# controller name; clear it first or the bind returns EBUSY.
# The UDC's "function" file is empty when no gadget driver is bound; the
# "gadget" symlink exists regardless, so it cannot be used as a bound check.
UDC=""
if [ -d /sys/class/udc ]; then
    UDC="$(ls /sys/class/udc 2>/dev/null | head -n 1)"
fi
CUR="$(cat "$CFG/UDC" 2>/dev/null || true)"
BOUND=""
if [ -n "$UDC" ] && [ -n "$(cat "/sys/class/udc/$UDC/function" 2>/dev/null)" ]; then
    BOUND=1
fi

if [ -z "$UDC" ]; then
    # Host mode (OTG dock attached): drop any stale name so the next bind works.
    [ -n "$CUR" ] && { echo "" > "$CFG/UDC" 2>/dev/null || true; }
elif [ -z "$BOUND" ]; then
    [ -n "$CUR" ] && { echo "" > "$CFG/UDC" 2>/dev/null || true; }
    echo "$UDC" > "$CFG/UDC"
fi

# usb0 appears asynchronously after the bind.
i=0
while [ ! -e /sys/class/net/usb0 ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
done
[ -e /sys/class/net/usb0 ] || exit 0

ip link set usb0 down 2>/dev/null || true
ip addr flush dev usb0 2>/dev/null || true
ip addr add 172.16.42.1/24 dev usb0
ip link set usb0 up
