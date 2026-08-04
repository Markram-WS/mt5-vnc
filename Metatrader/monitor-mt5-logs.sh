#!/bin/bash
# MT5 Comprehensive Log Monitor
# Monitors ALL MT5 log types: EA, system, trading, tester, indicators
# Streams to container stdout/stderr with type prefixes and timestamps

set -e

WINEPREFIX="${WINEPREFIX:-/opt/mt5}"
LOG_DIR_BASE="${WINEPREFIX}/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal"

echo "[monitor-mt5-logs] Starting comprehensive MT5 log monitoring..."
echo "[monitor-mt5-logs] Log directory base: $LOG_DIR_BASE"

# Wait for log directory to be created by MT5
MAX_WAIT=120
WAIT_INTERVAL=5

for ((i=0; i<MAX_WAIT/WAIT_INTERVAL; i++)); do
    if [ -d "$LOG_DIR_BASE" ]; then
        echo "[monitor-mt5-logs] Log directory found"
        break
    fi
    echo "[monitor-mt5-logs] Waiting for log directory... ($((i*WAIT_INTERVAL))/${MAX_WAIT}s)"
    sleep $WAIT_INTERVAL
done

if [ ! -d "$LOG_DIR_BASE" ]; then
    echo "[monitor-mt5-logs] ERROR: Log directory not found after ${MAX_WAIT}s"
    echo "[monitor-mt5-logs] Log monitoring will poll for directory creation"
fi

# Function to process a single log file with type prefix
process_log_file() {
    local log_file="$1"
    local log_name=$(basename "$log_file")
    local log_type="LOG"

    case "$log_file" in
        */MQL5/Logs/*)       log_type="EA";;
        */MQL5/Experts/Logs/*) log_type="EXPERT";;
        */MQL5/Indicators/Logs/*) log_type="INDICATOR";;
        */Logs/*)             log_type="SYSTEM";;
        */Tester/*)           log_type="TESTER";;
        *)                    log_type="MT5";;
    esac

    echo "[monitor-mt5-logs] Monitoring [$log_type] log file: $log_name"
    tail -F "$log_file" 2>/dev/null | while IFS= read -r line; do
        if [ -n "$line" ]; then
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            echo "[$log_type:$log_name] [$timestamp] $line"
        fi
    done
}

echo "[monitor-mt5-logs] Starting log monitoring for all MT5 log types..."
declare -A SEEN_FILES

while true; do
    EA_FILES=$(find "$LOG_DIR_BASE" -type f -name "*.log" -path "*/MQL5/Logs/*" 2>/dev/null || true)
    EXPERT_FILES=$(find "$LOG_DIR_BASE" -type f -name "*.log" -path "*/MQL5/Experts/Logs/*" 2>/dev/null || true)
    INDICATOR_FILES=$(find "$LOG_DIR_BASE" -type f -name "*.log" -path "*/MQL5/Indicators/Logs/*" 2>/dev/null || true)
    SYSTEM_FILES=$(find "$LOG_DIR_BASE" -type f -name "*.log" -path "*/Logs/*" ! -path "*/MQL5/*" 2>/dev/null || true)
    TESTER_FILES=$(find "$LOG_DIR_BASE" -type f -name "*.log" -path "*/Tester/*" 2>/dev/null || true)

    ALL_FILES=$(echo "$EA_FILES$EXPERT_FILES$INDICATOR_FILES$SYSTEM_FILES$TESTER_FILES" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

    if [ -n "$ALL_FILES" ]; then
        TOTAL_FILES=$(echo "$ALL_FILES" | wc -l)
        while IFS= read -r log_file; do
            [ -z "$log_file" ] && continue
            if [ -z "${SEEN_FILES[$log_file]}" ]; then
                SEEN_FILES[$log_file]=1
                process_log_file "$log_file" &
            fi
        done <<< "$ALL_FILES"
        if [ $((RANDOM % 60)) -eq 0 ]; then
            echo "[monitor-mt5-logs] Monitoring $TOTAL_FILES log files across all types"
        fi
    fi
    sleep 10
done