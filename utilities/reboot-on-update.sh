#!/usr/bin/env sh
set -eu

# Wait for a confirmed COS update before scheduling the next local reboot window.
TZ=${TZ:-Etc/UTC}
TIME=${TIME:-06:00}
TZDIR=${TZDIR:-/usr/share/zoneinfo}

case "$TIME" in
  [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
  *) echo "update-reboot: invalid reboot time: $TIME" >&2; exit 1 ;;
esac
case "$TZ" in
  ''|/*|*..*|*[!A-Za-z0-9_+/-]*)
    echo "update-reboot: invalid timezone: $TZ" >&2
    exit 1
    ;;
esac
if [ ! -f "$TZDIR/$TZ" ]; then
  echo "update-reboot: timezone data not found for $TZ" >&2
  exit 1
fi

echo "update-reboot: waiting for a COS update that requires reboot" >&2
if ! update_engine_client --block_until_reboot_is_needed; then
  echo "update-reboot: update engine wait failed; no reboot scheduled" >&2
  exit 1
fi

if ! status=$(update_engine_client --status); then
  echo "update-reboot: could not confirm update status; no reboot scheduled" >&2
  exit 1
fi
if ! printf '%s\n' "$status" | grep -qx 'CURRENT_OP=UPDATE_STATUS_UPDATED_NEED_REBOOT'; then
  echo "update-reboot: update status does not require reboot; no reboot scheduled" >&2
  exit 1
fi

# Calculate AFTER waiting, which can last days. Use the requested timezone for
# both the calendar date and time, including tomorrow's DST offset if needed.
now=$(date +%s)
target_date=$(TZ="$TZ" date +%F)
target_epoch=$(TZ="$TZ" date -d "$target_date $TIME" +%s)
if [ "$target_epoch" -le "$now" ]; then
  target_date=$(TZ="$TZ" date -d "$target_date +1 day" +%F)
  target_epoch=$(TZ="$TZ" date -d "$target_date $TIME" +%s)
fi
minutes=$(( (target_epoch - now + 59) / 60 ))

# Relative minutes avoid interpreting a local HH:MM in the host's timezone.
echo "update-reboot: scheduling reboot for $target_date $TIME $TZ (in $minutes minutes)" >&2
shutdown -r "+$minutes"
