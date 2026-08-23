#!/usr/bin/bash
# Liveness probe for the collector: is it still WRITING, not merely running?
#
# imjournal stops following the journal across a rotation. rsyslogd stays up,
# its port stays open, its queue reports empty and healthy — and nothing is
# ingested until it is restarted. On lotor the journal rotates every one to two
# hours, so this is not a rare edge case.
#
# A restart is lossless: imjournal seeks to the cursor in its state file and
# replays the gap (measured: 16,446 lines recovered after a 12-minute stall).
# So killing an ingesting-but-stalled collector costs nothing and fixes it.
#
# Pure bash on purpose — the ubi-micro base has no find and no awk.
set -u

LOG_ROOT="${SYSLOG_LOG_ROOT:-/logs}"
MAX_AGE="${SYSLOG_HEALTH_MAX_AGE:-900}"

newest=0
for dir in "$LOG_ROOT"/*/; do
    # Skip the collector's own impstats output. It is written on a timer whether
    # or not journal ingest is working, so counting it would make this probe
    # report healthy during exactly the failure it exists to catch.
    case "$dir" in
        "$LOG_ROOT"/_collector/) continue ;;
    esac
    for file in "$dir"*.log; do
        [ -f "$file" ] || continue
        mtime=$(stat -c %Y "$file" 2>/dev/null) || continue
        [ "$mtime" -gt "$newest" ] && newest=$mtime
    done
done

if [ "$newest" -eq 0 ]; then
    echo "no log files written yet"
    exit 1
fi

age=$(( $(date +%s) - newest ))
if [ "$age" -ge "$MAX_AGE" ]; then
    echo "stalled: newest write ${age}s ago (limit ${MAX_AGE}s)"
    exit 1
fi

echo "ingesting: newest write ${age}s ago"
exit 0
