#!/bin/sh
# USB NCM gadget: gives the phone a static 172.16.42.1 so the Mac can always
# reach it over the data cable, even with no WiFi. Mirrors the pmOS convention.
set -e

CONFIGFS=/sys/kernel/config/usb_gadget
GADGET=g1

modprobe libcomposite 2>/dev/null || true
mkdir -p /sys/kernel/config
[ -d "$CONFIGFS" ] || mount -t configfs none /sys/kernel/config 2>/dev/null || true

if [ ! -d "$CONFIGFS/$GADGET" ]; then
    mkdir "$CONFIGFS/$GADGET"
    cd "$CONFIGFS/$GADGET"
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
    UDC=$(ls /sys/class/udc | head -1)
    [ -n "$UDC" ] && echo "$UDC" > UDC
fi

ip link set usb0 down 2>/dev/null || true
ip addr flush dev usb0 2>/dev/null || true
ip addr add 172.16.42.1/24 dev usb0
ip link set usb0 up
