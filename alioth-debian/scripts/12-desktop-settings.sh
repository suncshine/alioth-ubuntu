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

if [ "$LIVE" -eq 1 ]; then
  if uid="$(live_session_uid)"; then
    log "applying live values for $USER_NAME (uid $uid)"
    run_as_user "$uid" gsettings set org.gnome.desktop.session idle-delay 300
    run_as_user "$uid" gsettings set org.gnome.settings-daemon.plugins.power power-button-action nothing
    run_as_user "$uid" gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
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
  '
else
  echo "  (no live session; values apply at next login)"
fi

log "done"
