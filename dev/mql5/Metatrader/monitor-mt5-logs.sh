#!/bin/bash
# MT5 Comprehensive Log Monitor
# Monitors ALL MT5 log types: EA, system, trading, tester, indicators
# Streams to container stdout/stderr with type prefixes and timestamps
#
# NOTE: MT5 runs in PORTABLE mode, so EA/terminal logs are written to the
# install directory (<WINEPREFIX>/drive_c/Program Files/MetaTrader 5/MQL5/Logs),
# NOT to AppData/Roaming/MetaQuotes/Terminal. Both locations are monitored to
# stay robust. MT5 logs are UTF-16LE and are decoded to UTF-8 for readability.

set -e

WINEPREFIX="${WINEPREFIX:-/opt/mt5}"
INSTALL_MQL5_DIR="${WINEPREFIX}/drive_c/Program Files/MetaTrader 5/MQL5"
APP_DATA_TERMINAL_DIR="${WINEPREFIX}/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal"

echo "[monitor-mt5-logs] Starting comprehensive MT5 log monitoring..."
echo "[monitor-mt5-logs] Install MQL5 dir (portable logs): $INSTALL_MQL5_DIR"
echo "[monitor-mt5-logs] AppData Terminal dir: $APP_DATA_TERMINAL_DIR"

# Wait for a log directory to be created by MT5
MAX_WAIT=120
WAIT_INTERVAL=5

for ((i=0; i<MAX_WAIT/WAIT_INTERVAL; i++)); do
    if [ -d "$INSTALL_MQL5_DIR" ] || [ -d "$APP_DATA_TERMINAL_DIR" ]; then
        echo "[monitor-mt5-logs] Log directory found"
        break
    fi
    echo "[monitor-mt5-logs] Waiting for log directory... ($((i*WAIT_INTERVAL))/${MAX_WAIT}s)"
    sleep $WAIT_INTERVAL
done

if [ ! -d "$INSTALL_MQL5_DIR" ] && [ ! -d "$APP_DATA_TERMINAL_DIR" ]; then
    echo "[monitor-mt5-logs] ERROR: Log directory not found after ${MAX_WAIT}s"
    echo "[monitor-mt5-logs] Log monitoring will poll for directory creation"
fi

# Decode a UTF-16LE log stream to UTF-8 (MT5 writes logs as UTF-16LE).
# Stripping NUL bytes converts UTF-16LE back to ASCII (MT5 logs are ASCII).
# It is also a safe no-op for plain ASCII/UTF-8 files.
# stdbuf -oL forces line buffering (tr would otherwise block-buffer the pipe
# and delay log lines by ~4KB, i.e. tens of seconds of EA ticks).
# (tail -F splits lines on byte 0x0A; the UTF-16 newline is "0A 00", so after
# tail the stream is misaligned by one byte - iconv would mangle it.)
decode() {
    local log_file="$1"
    local nul_count
    nul_count=$(head -c 8192 "$log_file" 2>/dev/null | tr -cd '\000' | wc -c)
    if [ -n "$nul_count" ] && [ "$nul_count" -gt 0 ]; then
        stdbuf -oL tr -d '\000'
    else
        cat
    fi
}

# Function to process a single log file with type prefix
process_log_file() {
    local log_file="$1"
    local log_name=$(basename "$log_file")
    local log_type="LOG"
    # The MT5 data dir is on an exFAT host mount where directory case is not
    # preserved (may appear as "Logs" or "logs"), so classify case-insensitively.
    local lc_file=$(printf '%s' "$log_file" | tr 'A-Z' 'a-z')

    case "$lc_file" in
        */mql5/logs/*)             log_type="EA";;
        */mql5/experts/logs/*)     log_type="EXPERT";;
        */mql5/indicators/logs/*)  log_type="INDICATOR";;
        */logs/*)                  log_type="SYSTEM";;
        */tester/*)                log_type="TESTER";;
        *)                         log_type="MT5";;
    esac

    echo "[monitor-mt5-logs] Monitoring [$log_type] log file: $log_name"
    tail -F "$log_file" 2>/dev/null | decode "$log_file" | while IFS= read -r line; do
        if [ -n "$line" ]; then
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            echo "[$log_type:$log_name] [$timestamp] $line"
        fi
    done
}

# Find *.log files of the given type pattern under a base directory.
# Uses -ipath (case-insensitive): the exFAT host mount may store the dirs as
# "logs" or "Logs", so matching must be case-insensitive.
find_type_logs() {
    local base="$1"
    local pattern="$2"
    [ -d "$base" ] || return 0
    find "$base" -type f -name "*.log" $pattern 2>/dev/null || true
}

echo "[monitor-mt5-logs] Starting log monitoring for all MT5 log types..."
declare -A SEEN_FILES

while true; do
    # Paths contain spaces ("Program Files", "MetaTrader 5"), so collect them
    # newline-separated - never split on spaces.
    ALL_FILES=""
    for base in "$INSTALL_MQL5_DIR" "$APP_DATA_TERMINAL_DIR"; do
        ALL_FILES="${ALL_FILES}
$(find_type_logs "$base" "-ipath */MQL5/Logs/*")
$(find_type_logs "$base" "-ipath */MQL5/Experts/Logs/*")
$(find_type_logs "$base" "-ipath */MQL5/Indicators/Logs/*")
$(find_type_logs "$base" "-ipath */Logs/* ! -ipath */MQL5/*")
$(find_type_logs "$base" "-ipath */Tester/*")"
    done
    ALL_FILES=$(printf '%s\n' "$ALL_FILES" | grep -v '^$' | sort -u)

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
