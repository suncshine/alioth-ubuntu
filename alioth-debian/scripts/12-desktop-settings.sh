#!/bin/bash
# Apply alioth's system-wide GNOME desktop defaults on a running phone.
# RUN ON THE PHONE as root.
#
# Installs files/dconf/00-alioth into the dconf system database and, when the
# desktop user has a live session, writes the same values to the user database
# so they take effect immediately:
#   * idle-delay = 300 s (blank + lock after 5 idle minutes)
#   * power-button-action = 'nothing' (alioth-powerkey owns the power key)
#   * screen-keyboard-enabled = true (GNOME on-screen keyboard on touch)
#   * Rotation Lock on, fixed Landscape Left on the built-in panel
#   * screen lock off: GDM auto-login and wake returns straight to the desktop
#   * internal Android partitions hidden from udisks/GNOME; volume icons are
#     left enabled so external USB disks still show up
#   * window buttons and favourites
#
# Usage:
#   sudo ./12-desktop-settings.sh
#   sudo ./12-desktop-settings.sh --no-live   # system database only
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${ALIOTH_USER:-user}"
DCONF_FILE=""
LIVE=1

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

for arg in "$@"; do
  case "$arg" in
    --no-live) LIVE=0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
command -v dconf >/dev/null || die "dconf not installed (install dconf-cli)"

for f in "$SELF_DIR/../files/dconf/00-alioth" /usr/local/share/alioth/00-alioth; do
  if [ -f "$f" ]; then DCONF_FILE="$f"; break; fi
done
[ -n "$DCONF_FILE" ] || die "00-alioth dconf file not found (run from the repo or install /usr/local/share/alioth/00-alioth)"

FILES_SRC=""
for d in "$SELF_DIR/../files" /usr/local/share/alioth; do
  if [ -f "$d/monitors.xml" ]; then FILES_SRC="$d"; break; fi
done

live_session_uid() {
  local uid
  uid="$(id -u "$USER_NAME" 2>/dev/null || true)"
  [ -n "$uid" ] && [ "$uid" -ne 0 ] && [ -S "/run/user/$uid/bus" ] || return 1
  printf '%s\n' "$uid"
}

run_as_user() {  # <uid> <command...>
  local uid="$1"; shift
  local home
  home="$(getent passwd "$USER_NAME" | cut -d: -f6)"
  runuser -u "$USER_NAME" -- env \
    HOME="$home" \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    "$@"
}

log "installing $DCONF_FILE -> /etc/dconf/db/local.d/00-alioth"
install -d /etc/dconf/db/local.d
if [ -f /etc/dconf/db/local.d/00-alioth ]; then
  backup="/root/00-alioth.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a /etc/dconf/db/local.d/00-alioth "$backup"
  log "backup: $backup"
fi
install -m644 "$DCONF_FILE" /etc/dconf/db/local.d/00-alioth
dconf update

# Landscape Left is applied after login because Mutter treats the built-in
# panel's orientation as accelerometer-managed (see alioth-display-layout).
if [ -n "$FILES_SRC" ] && [ -f "$FILES_SRC/alioth-display-layout" ]; then
  log "installing Landscape Left display helper"
  install -Dm755 "$FILES_SRC/alioth-display-layout" /usr/local/bin/alioth-display-layout
  if [ "$FILES_SRC" != "/usr/local/share/alioth" ]; then
    install -Dm644 "$FILES_SRC/monitors.xml" /usr/local/share/alioth/monitors.xml
  fi
  install -Dm644 "$FILES_SRC/alioth-display-layout.desktop" \
    /etc/xdg/autostart/alioth-display-layout.desktop
elif [ -x /usr/local/bin/alioth-display-layout ]; then
  log "Landscape Left display helper already installed"
else
  log "WARN: display helper not found — Landscape Left will not be enforced at login"
fi

# The Android partition table would otherwise show up as a stack of drive
# icons in the dock/desktop.  udisks ignores the internal partitions (no
# ID_USB_* marker), while USB disks remain visible.  A change event makes
# udisks update its hint-ignore property, which gvfs/dock/desktop pick up.
if [ -n "$FILES_SRC" ] && [ -f "$FILES_SRC/99-alioth-udisks-internal.rules" ]; then
  log "installing udisks rule for internal partitions"
  install -Dm644 "$FILES_SRC/99-alioth-udisks-internal.rules" \
    /etc/udev/rules.d/99-alioth-udisks-internal.rules
  udevadm control --reload-rules
  udevadm trigger --action=change --subsystem-match=block
else
  log "WARN: udisks rule not found — internal partitions may show as drives"
fi

if [ "$LIVE" -eq 1 ]; then
  if uid="$(live_session_uid)"; then
    log "applying live values for $USER_NAME (uid $uid)"
    run_as_user "$uid" gsettings set org.gnome.desktop.session idle-delay 300
    run_as_user "$uid" gsettings set org.gnome.settings-daemon.plugins.power power-button-action nothing
    run_as_user "$uid" gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
    run_as_user "$uid" gsettings set org.gnome.settings-daemon.peripherals.touchscreen orientation-lock true
    # GDM already auto-logs in; make wake/unlock return to the session too.
    run_as_user "$uid" gsettings set org.gnome.desktop.screensaver lock-enabled false
    run_as_user "$uid" gsettings set org.gnome.desktop.lockdown disable-lock-screen true
    # Internal partitions are filtered in udisks, so keep volume icons on for
    # external USB disks (they are the distro defaults; re-assert anyway).
    run_as_user "$uid" gsettings set org.gnome.shell.extensions.dash-to-dock show-mounts true
    run_as_user "$uid" gsettings set org.gnome.shell.extensions.ding show-volumes true
    if [ -x /usr/local/bin/alioth-display-layout ]; then
      log "applying Landscape Left"
      run_as_user "$uid" /usr/local/bin/alioth-display-layout ||
        log "WARN: alioth-display-layout failed"
    fi
  else
    log "no live session for $USER_NAME — system database only"
  fi
fi

log "effective values:"
if [ "$LIVE" -eq 1 ] && uid="$(live_session_uid)"; then
  run_as_user "$uid" sh -c '
    gsettings get org.gnome.desktop.session idle-delay
    gsettings get org.gnome.settings-daemon.plugins.power power-button-action
    gsettings get org.gnome.desktop.a11y.applications screen-keyboard-enabled
    gsettings get org.gnome.settings-daemon.peripherals.touchscreen orientation-lock
    gsettings get org.gnome.desktop.screensaver lock-enabled
    gsettings get org.gnome.desktop.lockdown disable-lock-screen
    gsettings get org.gnome.shell.extensions.dash-to-dock show-mounts
    gsettings get org.gnome.shell.extensions.ding show-volumes
  '
else
  echo "  (no live session; values apply at next login)"
fi

log "done"
