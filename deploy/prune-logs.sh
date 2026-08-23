#!/bin/bash
# Compress and expire collected logs. Driven by syslog-prune.timer on lotor.
#
# The collector writes one file per source per day, so rotation is already
# handled by the filename — this only has to compress settled files and expire
# old ones. Running on the host rather than inside the container keeps the image
# to a single process.
set -euo pipefail

LOG_ROOT="${SYSLOG_LOG_ROOT:-/srv/syslog.crunchtools.com/data/logs}"
COMPRESS_AFTER_DAYS="${SYSLOG_COMPRESS_AFTER_DAYS:-2}"
DELETE_AFTER_DAYS="${SYSLOG_DELETE_AFTER_DAYS:-90}"

if [ ! -d "$LOG_ROOT" ]; then
    echo "prune-logs: log root $LOG_ROOT does not exist" >&2
    exit 1
fi

# -mtime +N means "last modified more than N*24h ago", which keeps us clear of
# the file rsyslog is currently appending to. rsyslog's closeTimeout (10 min)
# has long since released the handle by then, so compressing cannot strand a
# writer on a deleted inode.
find "$LOG_ROOT" -type f -name '*.log' -mtime "+$COMPRESS_AFTER_DAYS" -print0 \
    | xargs -0 -r gzip -9

find "$LOG_ROOT" -type f \( -name '*.log.gz' -o -name '*.log' \) \
    -mtime "+$DELETE_AFTER_DAYS" -delete

# Clean up directories left behind by containers that no longer exist.
find "$LOG_ROOT" -mindepth 1 -type d -empty -delete

echo "prune-logs: $(du -sh "$LOG_ROOT" | cut -f1) retained under $LOG_ROOT"
