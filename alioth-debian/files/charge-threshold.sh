#!/bin/sh
# charge-threshold — keep the battery inside a configurable window.
#
# On this platform there is no hardware bypass switch: writing 0 to
# pm8150b-charger/charging_enabled only stops the battery from charging while
# USB stays online, so the phone keeps running from the cable.
#
# Policy (defaults): start charging at <= 60%, stop at >= 70%.  Between the
# two thresholds the current state is kept (hysteresis).  Nothing is written
# while no charger is connected; the state is re-evaluated on every poll.

set -u

CHARGER=${CHARGER:-/sys/class/power_supply/pm8150b-charger}
BATTERY=${BATTERY:-/sys/class/power_supply/qcom-battery}
START=${START:-60}
STOP=${STOP:-70}
INTERVAL=${INTERVAL:-30}

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
read_val() { cat "$1" 2>/dev/null; }

capacity=
enabled=

apply() {  # apply <0|1> <reason>
    want=$1
    why=$2
    have=$(read_val "$CHARGER/charging_enabled")
    [ "$have" = "$want" ] && return 0
    if printf '%s\n' "$want" > "$CHARGER/charging_enabled" 2>/dev/null; then
        log "capacity=${capacity}%: charging_enabled ${have:-?} -> ${want} (${why})"
    else
        log "ERROR: cannot write ${want} to ${CHARGER}/charging_enabled (capacity=${capacity}%)"
    fi
}

evaluate() {
    capacity=$(read_val "$BATTERY/capacity")
    enabled=$(read_val "$CHARGER/charging_enabled")
    online=$(read_val "$CHARGER/online")

    case $capacity in
        ''|*[!0-9]*) log "WARN: cannot read ${BATTERY}/capacity"; return 1 ;;
    esac
    case $enabled in
        0|1) ;;
        *) log "WARN: cannot read ${CHARGER}/charging_enabled"; return 1 ;;
    esac

    # Unplugged: leave the charger state alone, replug is handled next poll.
    [ "${online:-0}" = 1 ] || return 0

    if [ "$enabled" = 1 ] && [ "$capacity" -ge "$STOP" ]; then
        apply 0 "capacity >= ${STOP}%"
    elif [ "$enabled" = 0 ] && [ "$capacity" -le "$START" ]; then
        apply 1 "capacity <= ${START}%"
    fi
}

show_status() {
    capacity=$(read_val "$BATTERY/capacity")
    online=$(read_val "$CHARGER/online")
    enabled=$(read_val "$CHARGER/charging_enabled")
    printf 'capacity=%s%% online=%s charging_enabled=%s battery_status=%s charger_status=%s thresholds=%s/%s interval=%ss\n' \
        "${capacity:-?}" "${online:-?}" "${enabled:-?}" \
        "$(read_val "$BATTERY/status")" "$(read_val "$CHARGER/status")" \
        "$START" "$STOP" "$INTERVAL"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--once|--status|--restore|--help]

Environment / /etc/default/charge-threshold:
  START     start charging at or below this capacity (default 60)
  STOP      stop charging at or above this capacity (default 70)
  INTERVAL  poll interval in seconds when running as a daemon (default 30)

--restore re-enables normal charging; the unit runs it on "systemctl stop".
EOF
}

case ${1:-} in
    --once)   evaluate; exit $? ;;
    --status) show_status; exit 0 ;;
    --restore)
        capacity=$(read_val "$BATTERY/capacity")
        apply 1 "service stopped"
        exit 0
        ;;
    -h|--help) usage; exit 0 ;;
    '') ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

log "start: charge at <=${START}%, stop at >=${STOP}%, poll every ${INTERVAL}s"
trap 'log "stopped"; exit 0' TERM INT

while :; do
    evaluate
    sleep "$INTERVAL" &
    wait $!
done
