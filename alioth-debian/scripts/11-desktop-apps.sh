#!/bin/bash
# Install a trimmed stock Ubuntu 26.04 desktop application set on a running
# alioth.  RUN ON THE PHONE as root.
#
# Why this exists: 02-rootfs.sh builds the rootfs with
# `ubuntu-desktop-minimal --no-install-recommends`, so the app grid only has
# Settings / Files / Terminal / Text Editor / Calculator / Disks / System
# Monitor.  This script installs the user-visible applications from the
# Recommends of ubuntu-desktop{,-minimal}; the package list lives in
# files/desktop-apps.txt.  The LibreOffice suite is deliberately excluded --
# this device is used mainly for browsing.
#
# Snap-only packages (firefox, thunderbird, snapd) are not installed: this
# kernel has no AppArmor (LSM=capability,bpf), so snapd is not usable.
#   * Firefox: Mozilla's official linux-aarch64 tarball -> /opt/firefox,
#     with a .desktop entry, icon, and default-browser registration.
#   * Thunderbird: Mozilla publishes no arm64 Linux build; not installed.
#
# Usage:
#   sudo APP_LIST=/path/to/desktop-apps.txt ./11-desktop-apps.sh
#   sudo ./11-desktop-apps.sh --skip-firefox
#   sudo ./11-desktop-apps.sh --refresh-firefox   # re-download latest
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_LIST="${APP_LIST:-}"
FIREFOX_URL="${FIREFOX_URL:-https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64-aarch64&lang=en-US}"
INSTALL_FIREFOX=1
REFRESH_FIREFOX=0
WORK_TMP=""
trap 'rm -rf "${WORK_TMP:-}"' EXIT

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

for arg in "$@"; do
  case "$arg" in
    --skip-firefox)    INSTALL_FIREFOX=0 ;;
    --refresh-firefox) REFRESH_FIREFOX=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
[ "$(dpkg --print-architecture)" = "arm64" ] || die "expected arm64 rootfs"

if [ -z "$APP_LIST" ]; then
  for f in "$SELF_DIR/../files/desktop-apps.txt" /usr/local/share/alioth/desktop-apps.txt; do
    if [ -f "$f" ]; then APP_LIST="$f"; break; fi
  done
fi
[ -n "$APP_LIST" ] && [ -f "$APP_LIST" ] || die "desktop-apps.txt not found (set APP_LIST)"

# Firefox is downloaded directly from Mozilla; the systemd unit that runs this
# script does not inherit the interactive proxy environment.
if [ -z "${https_proxy:-}" ] && [ -r /etc/environment ]; then
  eval "$(grep -E '^(http|https|no)_proxy=' /etc/environment || true)"
fi

install_packages() {
  local pkgs=()
  mapfile -t pkgs < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$APP_LIST" | grep -v '^$')
  [ "${#pkgs[@]}" -gt 0 ] || die "package list is empty: $APP_LIST"
  log "installing ${#pkgs[@]} packages from $APP_LIST"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
}

install_firefox_tarball() {
  local tmp final rel_root sums expected actual suffix newver s src
  tmp="$(mktemp -d)"
  WORK_TMP="$tmp"

  log "downloading Firefox aarch64 tarball"
  python3 - "$FIREFOX_URL" "$tmp/firefox.tar.xz" "$tmp/final_url" <<'PY'
import sys, urllib.request
url, out, final = sys.argv[1:4]
req = urllib.request.Request(url, headers={"User-Agent": "alioth-desktop-apps/1"})
with urllib.request.urlopen(req, timeout=180) as r, open(out, "wb") as f:
    open(final, "w").write(r.geturl())
    while True:
        chunk = r.read(1 << 20)
        if not chunk:
            break
        f.write(chunk)
PY
  final="$(cat "$tmp/final_url")"
  log "resolved: $final"

  # Verify against Mozilla's SHA256SUMS when the redirected URL has the
  # usual .../releases/<version>/<platform>/<lang>/<file> layout.
  rel_root="$(printf '%s\n' "$final" | sed -E 's#(/releases/[^/]+)/.*#\1#')"
  if [ "$rel_root" != "$final" ]; then
    python3 - "$rel_root/SHA256SUMS" "$tmp/SHA256SUMS" <<'PY'
import sys, urllib.request
url, out = sys.argv[1:3]
req = urllib.request.Request(url, headers={"User-Agent": "alioth-desktop-apps/1"})
with urllib.request.urlopen(req, timeout=60) as r, open(out, "wb") as f:
    f.write(r.read())
PY
    suffix="$(printf '%s\n' "$final" | sed -E 's#^.*/releases/[^/]+/##')"
    expected="$(awk -v f="$suffix" '$2 == f { print $1; exit }' "$tmp/SHA256SUMS")"
    [ -n "$expected" ] || die "no SHA256SUMS entry for $suffix"
    actual="$(sha256sum "$tmp/firefox.tar.xz" | cut -d' ' -f1)"
    [ "$actual" = "$expected" ] || die "Firefox checksum mismatch: $actual != $expected"
    log "checksum ok: $actual"
  else
    log "WARN: non-standard Firefox URL, skipping checksum verification"
  fi

  log "installing /opt/firefox"
  tar -xJf "$tmp/firefox.tar.xz" -C "$tmp"
  [ -x "$tmp/firefox/firefox" ] || die "tarball does not contain firefox/firefox"
  newver="$(sed -n 's/^Version=//p' "$tmp/firefox/application.ini" | head -1)"

  rm -rf /opt/firefox
  install -d /opt
  mv "$tmp/firefox" /opt/firefox
  ln -sfn /opt/firefox/firefox /usr/local/bin/firefox

  for s in 16 32 48 64 128; do
    src="/opt/firefox/browser/chrome/icons/default/default${s}.png"
    if [ -f "$src" ]; then
      install -Dm644 "$src" "/usr/share/icons/hicolor/${s}x${s}/apps/firefox.png"
    fi
  done
  if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
  fi

  cat > /usr/share/applications/firefox.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Name=Firefox Web Browser
GenericName=Web Browser
Comment=Browse the World Wide Web
Keywords=Internet;WWW;Browser;Web;Explorer;
Exec=firefox %u
Terminal=false
X-MultipleArgs=false
Type=Application
Icon=firefox
Categories=GNOME;GTK;Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;application/xml;application/rss+xml;application/rdf+xml;image/gif;image/jpeg;image/png;x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/ftp;x-scheme-handler/chrome;video/webm;application/x-xpinstall;
StartupNotify=true
StartupWMClass=firefox
DESKTOP
  if command -v update-desktop-database >/dev/null; then
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
  fi

  update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/local/bin/firefox 200
  update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/local/bin/firefox 200

  # Default browser for the desktop user.  mimeapps.list is enough; no
  # session bus is needed for this.
  if command -v xdg-mime >/dev/null; then
    runuser -u user -- env HOME=/home/user xdg-mime default firefox.desktop \
      text/html x-scheme-handler/http x-scheme-handler/https \
      application/xhtml+xml 2>/dev/null || \
      log "WARN: could not set Firefox as default browser for user"
  fi
  log "Firefox $newver installed"
}

main() {
  install_packages

  if [ "$INSTALL_FIREFOX" -eq 1 ]; then
    if [ -x /opt/firefox/firefox ] && [ "$REFRESH_FIREFOX" -eq 0 ]; then
      log "Firefox already installed: $(sed -n 's/^Version=//p' /opt/firefox/application.ini | head -1) (use --refresh-firefox to update)"
    else
      install_firefox_tarball
    fi
  fi

  # snapd must not be pulled in by a dependency; snap is unusable on this kernel.
  if dpkg-query -W -f='${db:Status-Abbrev}' snapd 2>/dev/null | grep -q '^ii'; then
    log "WARN: snapd is installed, unexpected for this package list"
  fi

  log "done"
  echo
  echo "Installed applications:"
  ls /usr/share/applications/*.desktop 2>/dev/null | sed 's#.*/##' | sort | grep -vE 'panel|portal|daemon|Xwayland|python3' || true
}

main "$@"
