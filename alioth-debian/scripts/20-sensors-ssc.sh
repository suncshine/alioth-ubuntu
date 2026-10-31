#!/bin/sh
# Deploy Qualcomm SSC sensor userspace ON THE DEVICE (alioth, as root).
#
# Prerequisite: hexagonrpcd must already be serving the SDSP firmware tree
#   (see /etc/systemd/system/hexagonrpcd.service.d/alioth.conf).
# That alone stops the SLPI sensor_process dog-crash loop; this script adds
# libssc + the SSC-enabled iio-sensor-proxy so the desktop can use sensors.
#
# Artifacts (built on the arm64 VM, Ubuntu 24.04):
#   libssc 0.4.4  gitlab/salsa DebianOnMobile-team/libssc @ 59b00ba
#   iio-sensor-proxy main @ ca0d5b0 with -Dssc-support=enabled
#   tarball layout: usr/lib/aarch64-linux-gnu/libssc.so.2
#                   usr/local/bin/{ssccli,monitor-sensor}
#                   usr/local/libexec/iio-sensor-proxy
set -eu

TARBALL="${1:-/root/alioth-sensors.tar.gz}"
WORK=/root/alioth-sensors

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK"
tar -C "$WORK" -xzf "$TARBALL"

# Runtime libraries our binaries need (Ubuntu package names).
MISSING=""
for p in libqmi-glib5 libqrtr-glib0 libmbim-glib4 libprotobuf-c1; do
	dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"
done
if [ -n "$MISSING" ]; then
	echo "installing runtime libs:$MISSING"
	DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 \
		install -y --no-install-recommends $MISSING
fi

# libssc: no distro package, install under the normal multiarch path.
install -Dm644 "$WORK/usr/lib/aarch64-linux-gnu/libssc.so.2" \
	/usr/lib/aarch64-linux-gnu/libssc.so.2
ln -sfn libssc.so.2 /usr/lib/aarch64-linux-gnu/libssc.so
ldconfig

install -Dm755 "$WORK/usr/local/bin/ssccli" /usr/local/bin/ssccli
install -Dm755 "$WORK/usr/local/bin/monitor-sensor" /usr/local/bin/monitor-sensor
# Readiness gate: SSC discovery in iio-sensor-proxy does not retry.
install -Dm755 "$(dirname "$0")/ssc-wait" /usr/local/bin/ssc-wait

# Keep the distro iio-sensor-proxy binary untouched; run ours via drop-in.
install -Dm755 "$WORK/usr/local/libexec/iio-sensor-proxy" \
	/usr/local/libexec/iio-sensor-proxy

# Test the sensor stack before enabling the D-Bus proxy (exclusive access).
systemctl stop iio-sensor-proxy.service 2>/dev/null || true
echo "== ssccli accelerometer (5 s) =="
timeout 8 ssccli --sensor accelerometer --timeout 5 || echo "ssccli accelerometer FAILED"
echo "== ssccli light (5 s) =="
timeout 8 ssccli --sensor light --timeout 5 || echo "ssccli light FAILED"

# Udev: tag the SDSP FastRPC device with all SSC sensor types. Ubuntu's
# packaged 80-iio-sensor-proxy.rules may only tag light/compass (or nothing).
cat > /etc/udev/rules.d/82-ssc-alioth.rules <<'EOF'
ACTION=="remove", GOTO="ssc_alioth_end"
SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp*", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-accel ssc-light ssc-proximity ssc-compass"
ENV{IIO_SENSOR_PROXY_TYPE}=="", GOTO="ssc_alioth_end"
TAG+="systemd", ENV{SYSTEMD_WANTS}+="iio-sensor-proxy.service"
LABEL="ssc_alioth_end"
EOF

mkdir -p /etc/systemd/system/iio-sensor-proxy.service.d
cat > /etc/systemd/system/iio-sensor-proxy.service.d/ssc-alioth.conf <<'EOF'
[Unit]
Wants=hexagonrpcd.service
After=hexagonrpcd.service

[Service]
ExecStart=
ExecStart=/usr/local/libexec/iio-sensor-proxy
# Wait for SLPI's sensor_process / SNS service before SSC discovery.
ExecStartPre=/usr/local/bin/ssc-wait
RestrictAddressFamilies=AF_UNIX AF_LOCAL AF_NETLINK AF_QIPCRTR
EOF

udevadm control --reload-rules
udevadm trigger --action=change --subsystem-match=misc
systemctl daemon-reload
systemctl start iio-sensor-proxy.service || true
sleep 1
systemctl --no-pager --full status iio-sensor-proxy.service | head -15 || true

echo "== D-Bus properties =="
gdbus call --system --dest net.hadess.SensorProxy \
	--object-path /net/hadess/SensorProxy \
	--method org.freedesktop.DBus.Properties.GetAll \
	net.hadess.SensorProxy 2>&1 || true

echo "done. Rotate the phone by hand and run: monitor-sensor"
