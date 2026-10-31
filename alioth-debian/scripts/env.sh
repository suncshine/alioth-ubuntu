# alioth-debian shared environment — sourced by every script
WORK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DL="$WORK/downloads"
OUT="$WORK/out"
FILES="$WORK/files"
SCRIPTS="$WORK/scripts"

# --- prebuilt kernel (Arch pkg from Kupfer releases = plain tar.xz) ---
KERNEL_PKG="$DL/linux-sm8250-7.2.0-1-aarch64.pkg.tar.xz"
KERNEL_URL="https://github.com/Vae555/kupfer-alioth-builds/releases/latest/download/linux-sm8250-7.2.0-1-aarch64.pkg.tar.xz"
KVER="7.2.0"

# --- device firmware (N1kroks, same commit as pmaports-alioth pins) ---
FW_URL="https://github.com/N1kroks/firmware-xiaomi-alioth/archive/95dfcdf6b154c00af3e093db82015cda90f4299a.tar.gz"
FW_TGZ="$DL/firmware-xiaomi-alioth.tar.gz"
FW_DIR="$OUT/firmware-xiaomi-alioth-95dfcdf6b154c00af3e093db82015cda90f4299a"

# --- build targets: Ubuntu 26.04 LTS (resolute) arm64 ----------------------
# Debian fallback: DISTRO=debian, DEB_SUITE=trixie,
#   DEB_MIRROR="http://deb.debian.org/debian",
#   DEB_COMPONENTS="main,contrib,non-free-firmware"
DISTRO="ubuntu"
DEB_SUITE="resolute"
DEB_MIRROR="http://ports.ubuntu.com/ubuntu-ports"
DEB_COMPONENTS="main,universe"
ROOTFS="$WORK/rootfs"
ROOT_IMG="$OUT/alioth-debian.img"
ROOT_IMG_SPARSE="$OUT/alioth-debian-sparse.img"
ROOT_IMG_SIZE="16G"
BOOT_IMG="$OUT/boot.img"
INITRD="$OUT/initrd.img"
MNT="/mnt-alioth"

# --- boot layout (verified byte-for-byte against Kupfer reference image,
#     see out/aboot-ref/ — header v0, second_addr=0 despite deviceinfo) ---
ROOT_PART="/dev/sda35"
CMDLINE="root=/dev/sda35 rootwait rw net.ifnames=0 console=tty0"
# RAM-test image: stay in the initramfs shell (break=mount), stream logs over
# the USB ACM console and auto-reboot on panic.
BOOT_IMG_DEBUG="$OUT/boot-debug.img"
# ip= lets dropbear-initramfs configure usb0 statically instead of DHCP-waiting.
CMDLINE_DEBUG="$CMDLINE console=ttyGS0,115200n8 loglevel=7 panic=10 break=mount ip=172.16.42.1::172.16.42.2:255.255.255.0::usb0:off"

# --- usb networking (pmOS convention so the debug habit carries over) ---
PHONE_IP="172.16.42.1"
HOST_IP="172.16.42.2"
