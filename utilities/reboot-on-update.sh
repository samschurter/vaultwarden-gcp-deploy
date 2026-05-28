#!/usr/bin/env sh

# Local timezone - use the TZ database name from https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
# e.g., Etc/UTC, America/New_York, etc
TZ=${TZ:-Etc/UTC}

# Local time to schedule reboot
TIME=${TIME:-06:00}

SCHEDULED="$TIME"
TARGET_DATE=$(date +%F)
TARGET_EPOCH=$(TZ="$TZ" date -d "$TARGET_DATE $TIME" +%s 2>/dev/null)

if [ -n "$TARGET_EPOCH" ]; then
	SCHEDULED=$(date -d "@$TARGET_EPOCH" +%H:%M 2>/dev/null || printf '%s' "$TIME")
fi

sleep 60 && update_engine_client --block_until_reboot_is_needed
shutdown -r "$SCHEDULED"
