#!/bin/sh
# Deploy the Qualcomm SSC sensor userspace (libssc + SSC-enabled iio-sensor-proxy).
#
# Two modes:
#   * live (default): run ON THE PHONE as root.  Installs the files, loads the
#     binaries, restarts iio-sensor-proxy and prints the D-Bus properties.
#   * --root ROOTFS: install-only into an offline rootfs built by 02-rootfs.sh
#     (no apt, no systemctl, no verification).  ldconfig -r runs if available.
#
# Prerequisite (both modes): hexagonrpcd must serve the SDSP firmware tree.
# The drop-in in files/sensors/hexagonrpcd-alioth.conf is installed here; the
# firmware itself comes from files/sensor.files via 02-rootfs.sh.
#
# Inputs (tracked):
#   files/sensors/alioth-sensors.tar.gz   libssc 0.4.4 + iio-sensor-proxy (SSC)
#   files/sensors/82-ssc-alioth.rules
#   files/sensors/iio-sensor-proxy-ssc-alioth.conf
#   files/sensors/hexagonrpcd-alioth.conf
#   files/ssc-wait
#
# Usage:
#   sudo ./20-sensors-ssc.sh                    # live, tracked tarball
#   sudo ./20-sensors-ssc.sh /path/to/tarball   # live, custom tarball
#   ./20-sensors-ssc.sh --root /path/rootfs     # offline rootfs install
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FILES_DIR=$(CDPATH= cd -- "$SELF_DIR/../files" && pwd)

ROOTFS=""
TARBALL=""
while [ $# -gt 0 ]; do
	case "$1" in
		--root)    [ $# -ge 2 ] || { echo "--root needs a path" >&2; exit 2; }; ROOTFS="$2"; shift 2 ;;
		-h|--help) sed -n '2,30p' "$0"; exit 0 ;;
		-*)        echo "unknown argument: $1" >&2; exit 2 ;;
		*)         TARBALL="$1"; shift ;;
	esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

PREFIX=${ROOTFS%/}
LIVE=0
[ -z "$PREFIX" ] && LIVE=1
[ "$(id -u)" = 0 ] || die "run as root"

[ -n "$TARBALL" ] || TARBALL="$FILES_DIR/sensors/alioth-sensors.tar.gz"
[ -f "$TARBALL" ] || TARBALL=/root/alioth-sensors.tar.gz
[ -f "$TARBALL" ] || die "sensors tarball not found"

SENSOR_FILES="82-ssc-alioth.rules iio-sensor-proxy-ssc-alioth.conf hexagonrpcd-alioth.conf"
for f in $SENSOR_FILES; do
	[ -f "$FILES_DIR/sensors/$f" ] || die "missing $FILES_DIR/sensors/$f"
done
[ -f "$FILES_DIR/ssc-wait" ] || die "missing $FILES_DIR/ssc-wait"

EXPECTED_SHA="8f306b2c4ff980d99e9bf1b42d849731504b84c6374b7a2fbb57b271ecf7b417"
if [ "${SENSORS_SKIP_VERIFY:-0}" != 1 ]; then
	ACTUAL_SHA=$(sha256sum "$TARBALL" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$TARBALL" | cut -d' ' -f1)
	[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] \
		|| die "sensors tarball checksum $ACTUAL_SHA != $EXPECTED_SHA (set SENSORS_SKIP_VERIFY=1 to override)"
fi
log "tarball $TARBALL"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
tar -C "$TMP" -xzf "$TARBALL"

for f in \
	usr/lib/aarch64-linux-gnu/libssc.so.2 \
	usr/local/bin/ssccli \
	usr/local/bin/monitor-sensor \
	usr/local/libexec/iio-sensor-proxy
do
	[ -f "$TMP/$f" ] || die "tarball is missing $f"
done

# --- 1. runtime libraries (live only; the rootfs gets them from mmdebstrap) --
if [ "$LIVE" -eq 1 ]; then
	MISSING=""
	for p in libqmi-glib5 libqrtr-glib0 libmbim-glib4 libprotobuf-c1; do
		dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"
	done
	if [ -n "$MISSING" ]; then
		log "installing runtime libs:$MISSING"
		DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 \
			install -y --no-install-recommends $MISSING
	fi
fi

# --- 2. install the userspace ----------------------------------------------
install -Dm644 "$TMP/usr/lib/aarch64-linux-gnu/libssc.so.2" \
	"$PREFIX/usr/lib/aarch64-linux-gnu/libssc.so.2"
ln -sfn libssc.so.2 "$PREFIX/usr/lib/aarch64-linux-gnu/libssc.so"
install -Dm755 "$TMP/usr/local/bin/ssccli" "$PREFIX/usr/local/bin/ssccli"
install -Dm755 "$TMP/usr/local/bin/monitor-sensor" "$PREFIX/usr/local/bin/monitor-sensor"
install -Dm755 "$FILES_DIR/ssc-wait" "$PREFIX/usr/local/bin/ssc-wait"
install -Dm755 "$TMP/usr/local/libexec/iio-sensor-proxy" \
	"$PREFIX/usr/local/libexec/iio-sensor-proxy"

# --- 3. udev + systemd drop-ins --------------------------------------------
install -Dm644 "$FILES_DIR/sensors/82-ssc-alioth.rules" \
	"$PREFIX/etc/udev/rules.d/82-ssc-alioth.rules"
install -Dm644 "$FILES_DIR/sensors/iio-sensor-proxy-ssc-alioth.conf" \
	"$PREFIX/etc/systemd/system/iio-sensor-proxy.service.d/ssc-alioth.conf"
install -Dm644 "$FILES_DIR/sensors/hexagonrpcd-alioth.conf" \
	"$PREFIX/etc/systemd/system/hexagonrpcd.service.d/alioth.conf"

if [ "$LIVE" -eq 0 ]; then
	if command -v ldconfig >/dev/null 2>&1; then
		ldconfig -r "$PREFIX"
	else
		log "WARN: ldconfig missing; libssc.so symlink was created but the cache is not"
	fi
	log "rootfs ready: libssc, ssccli/monitor-sensor, SSC iio-sensor-proxy, udev+drop-ins"
	log "first boot: hexagonrpcd -> iio-sensor-proxy (SSDP gate) -> net.hadess.SensorProxy"
	exit 0
fi

# --- 4. live activation and verification -----------------------------------
ldconfig
systemctl stop iio-sensor-proxy.service 2>/dev/null || true

echo "== ssccli accelerometer (5 s) =="
timeout 8 ssccli --sensor accelerometer --timeout 5 || echo "ssccli accelerometer FAILED"
echo "== ssccli light (5 s) =="
timeout 8 ssccli --sensor light --timeout 5 || echo "ssccli light FAILED"

udevadm control --reload-rules
udevadm trigger --action=change --subsystem-match=misc
systemctl daemon-reload
systemctl start iio-sensor-proxy.service || true
sleep 1
systemctl --no-pager --full status iio-sensor-proxy.service 2>&1 | head -15 || true

echo "== D-Bus properties =="
gdbus call --system --dest net.hadess.SensorProxy \
	--object-path /net/hadess/SensorProxy \
	--method org.freedesktop.DBus.Properties.GetAll \
	net.hadess.SensorProxy 2>&1 || true

echo "done. Rotate the phone by hand and run: monitor-sensor"
