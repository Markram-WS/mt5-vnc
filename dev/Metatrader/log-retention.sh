#!/bin/bash
# MT5 Log Retention
# Deletes MT5 log files older than LOG_RETENTION_DAYS (default 7).
# Runs every LOG_RETENTION_INTERVAL (seconds, default 86400 = daily).
# Covers: MQL5/Logs, MQL5/Experts/Logs, MQL5/Indicators/Logs, Tester logs,
#         terminal root logs, metaeditor.log.
# Controlled from .env: LOG_RETENTION_DAYS, LOG_RETENTION_INTERVAL.

set -e

WINEPREFIX="${WINEPREFIX:-/opt/mt5}"
MT5_DIR="${WINEPREFIX}/drive_c/Program Files/MetaTrader 5"
RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
INTERVAL="${LOG_RETENTION_INTERVAL:-86400}"

RETENTION_DAYS=$(( RETENTION_DAYS > 0 ? RETENTION_DAYS : 7 ))

cleanup_once() {
    local dir
    for dir in \
        "${MT5_DIR}/MQL5/Logs" \
        "${MT5_DIR}/MQL5/Experts/Logs" \
        "${MT5_DIR}/MQL5/Indicators/Logs" \
        "${MT5_DIR}/MQL5/Tester/Logs" \
        "${MT5_DIR}/MQL5/Tester" \
        "${MT5_DIR}/Logs" \
        "${MT5_DIR}"; do
        [ -d "$dir" ] || continue
        # delete *.log and .log.bak older than N days (MT5 names logs %Y%m%d.log)
        find "$dir" -maxdepth 1 -type f -name "*.log*" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
    done
    echo "[log-retention] Cleaned logs older than ${RETENTION_DAYS} day(s) (tick: done)"
}

echo "[log-retention] MT5 log retention enabled: delete > ${RETENTION_DAYS} day(s), every ${INTERVAL}s"
cleanup_once

while true; do
    sleep "$INTERVAL"
    cleanup_once
done