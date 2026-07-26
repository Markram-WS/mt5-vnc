#!/bin/bash
set -e
export WINEPREFIX=/opt/mt5-prefix
export WINEARCH=win64
mkdir -p "$WINEPREFIX"

# Set up XDG directories (needed for Wine)
export XDG_RUNTIME_DIR=/tmp/xdg-runtime
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# Start Xvnc for Wine installer with VNC listener disabled
# -rfbport 0 and SecurityTypes None disable VNC connections, we only need the X server
# Use display :99 to avoid conflicts
/usr/local/bin/Xvnc :99 -screen 0 1280x800x24 -nolisten tcp -ac -rfbport 0 -SecurityTypes None &
XVNC_PID=$!
sleep 3

# Cleanup on failure
trap "kill $XVNC_PID 2>/dev/null || true" EXIT

export DISPLAY=:99
export WINEDLLOVERRIDES="winemenubuilder.exe=d"

# Initialize Wine
echo "Initializing Wine..."
wine wineboot --init
wineserver -w

# Download and install MT5
MT5_URL="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
cd /tmp
echo "Downloading MT5 installer..."
wget -O mt5setup.exe "$MT5_URL"
echo "Installing MT5..."
wine mt5setup.exe /auto
wineserver -w

# Verify installation
if [ ! -f "$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe" ]; then
  echo "ERROR: MT5 installation failed"
  exit 1
fi

# Cleanup
kill $XVNC_PID || true
rm -f /tmp/mt5setup.exe
echo "MT5 installed successfully"