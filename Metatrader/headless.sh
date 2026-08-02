#!/bin/bash
# Custom headless.sh: Xvfb + MT5 via start.sh
# Preserves Xvfb setup from base image with credential pass-through

set -e

echo "[headless] Starting Xvfb..."
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

pkill -f "Xvfb.*:99" 2>/dev/null || true
rm -f /tmp/.X99-lock 2>/dev/null || true

Xvfb :99 -screen 0 1280x800x24 -nolisten tcp -ac +extension GLX +extension RANDR &
XVFB_PID=$!
sleep 3

if ! kill -0 $XVFB_PID 2>/dev/null; then
    echo "[headless] Xvfb failed to start"
    exit 1
fi

echo "[headless] Xvfb started successfully"

export DISPLAY=:99
export WINEPREFIX="${WINEPREFIX:-/app}"
export WINEDLLOVERRIDES="winemenubuilder.exe=d"
export XDG_RUNTIME_DIR=/tmp
export XDG_DATA_HOME=/app/.local/share

echo "[headless] Running start.sh..."
bash /Metatrader/start.sh

echo "[headless] Entering wait state..."
wait