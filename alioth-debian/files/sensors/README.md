# SSC sensor userspace

Tracked inputs for the alioth sensor stack (libssc + SSC-enabled
iio-sensor-proxy).  Install with `scripts/20-sensors-ssc.sh` (live phone or
`--root <rootfs>`).

- `alioth-sensors.tar.gz` — prebuilt arm64 userspace, built on the VM from
  libssc 0.4.4 (DebianOnMobile-team/libssc @ 59b00ba) and iio-sensor-proxy
  main @ ca0d5b0 with `-Dssc-support=enabled`.  SHA256
  `8f306b2c4ff980d99e9bf1b42d849731504b84c6374b7a2fbb57b271ecf7b417`.
  Layout: `usr/lib/aarch64-linux-gnu/libssc.so.2`,
  `usr/local/bin/{ssccli,monitor-sensor}`,
  `usr/local/libexec/iio-sensor-proxy`.
- `82-ssc-alioth.rules` — tag the SDSP FastRPC device for iio-sensor-proxy.
- `iio-sensor-proxy-ssc-alioth.conf` — run the SSC build, gated by `ssc-wait`.
- `hexagonrpcd-alioth.conf` — point hexagonrpcd at the SDSP firmware tree.

Sensor firmware/registry data lives in `files/sensor.files` and is copied from
the N1kroks firmware tarball by `02-rootfs.sh`.
