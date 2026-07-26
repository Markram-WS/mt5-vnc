FROM gmag11/metatrader5_vnc:latest

# Install dependencies
RUN mkdir -pm755 /etc/apt/keyrings && \
    wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
RUN apt-get update && \
    apt-get install -y python3-xdg python3-pip xdotool xvfb && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --break-system-packages --no-cache-dir mt5linux

RUN sed -i 's/-w//g' /usr/local/bin/mt5linux 2>/dev/null || true

# Fix nginx: KasmVNC serves both HTTP + websocket on port 6901, not 6900
RUN sed -i 's|http://127.0.0.1:6900;|http://127.0.0.1:6901;|g' /defaults/default.conf

# Revert stale startwm patches
RUN sed -i '/^# Run MT5 install/d' /defaults/startwm.sh

# Pre-initialize Wine prefix in image layer (not on exFAT)
ENV WINEPREFIX=/opt/mt5-prefix
ENV WINEARCH=win64

# Quick Wine prefix init


# Note: MT5 will be installed at runtime via start.sh, not at build time
# Modify start.sh to use image-based prefix, fix all hardcoded paths, add /portable flag, remove stale xdotool lines
RUN cp /Metatrader/start.sh /Metatrader/start.sh.bak && \
    sed -i 's|/config/.wine|/opt/mt5-prefix|g' /Metatrader/start.sh && \
    sed -i 's|mt5file=.*|mt5file="/opt/mt5-prefix/drive_c/Program Files/MetaTrader 5/terminal64.exe"|' /Metatrader/start.sh && \
    sed -i 's|wine_executable="wine"|wine_executable="wine"\nWINEPREFIX=/opt/mt5-prefix|' /Metatrader/start.sh && \
    sed -i 's|\$wine_executable "\$mt5file" \$MT5_CMD_OPTIONS \&|\$wine_executable "\$mt5file" \$MT5_CMD_OPTIONS /portable \&|' /Metatrader/start.sh && \
    sed -i '/# Resize MT5 windows/d' /Metatrader/start.sh && \
    sed -i 's|python3 -m mt5linux --host 0.0.0.0 -p $mt5server_port -w $wine_executable python.exe &|python3 -m mt5linux --host 0.0.0.0 -p $mt5server_port \&|' /Metatrader/start.sh

# Window management script: waits for X display + MT5 windows, then resizes
RUN printf '#!/bin/bash\n\
# Wait up to 60s for X display\n\
for i in $(seq 30); do\n\
  if DISPLAY=:1 xdotool get_desktop >/dev/null 2>&1; then\n\
    break\n\
  fi\n\
  sleep 2\n\
done\n\
\n\
# Poll for MT5 windows, resize when found\n\
for i in $(seq 20); do\n\
  found=false\n\
  for wid in $(DISPLAY=:1 xdotool search --class terminal64 2>/dev/null); do\n\
    xdotool windowmap "$wid" 2>/dev/null\n\
    xdotool windowraise "$wid" 2>/dev/null\n\
    xdotool windowmove "$wid" 200 50 2>/dev/null\n\
    xdotool windowsize "$wid" 1200 700 2>/dev/null\n\
    found=true\n\
  done\n\
  if [ "$found" = true ]; then\n\
    exit 0\n\
  fi\n\
  sleep 3\n\
done\n' > /Metatrader/resize-windows.sh && \
    chmod +x /Metatrader/resize-windows.sh

# Create s6 init-mt5 service: wait for display, run start.sh, then resize windows
RUN mkdir -p /etc/s6-overlay/s6-rc.d/init-mt5/dependencies.d && \
    printf '#!/usr/bin/with-contenv bash\nset -e\n\
export DISPLAY=:1\n\
\n\
# Wait up to 60s for X display socket\n\
for i in $(seq 30); do\n\
  if [ -e /tmp/.X11-unix/X1 ]; then\n\
    break\n\
  fi\n\
  sleep 2\n\
done\n\
\n\
if [ -f /Metatrader/start.sh ]; then\n\
  echo "[init-mt5] Starting MT5 setup..."\n\
  bash /Metatrader/start.sh 2>&1 | sed "s/^/[init-mt5] /" &\n\
  echo "[init-mt5] MT5 setup backgrounded."\n\
fi\n\
if [ -f /Metatrader/resize-windows.sh ]; then\n\
  echo "[init-mt5] Scheduling window resize..."\n\
  /Metatrader/resize-windows.sh 2>&1 | sed "s/^/[init-mt5] /" &\n\
fi\n' > /etc/s6-overlay/s6-rc.d/init-mt5/run && \
    chmod +x /etc/s6-overlay/s6-rc.d/init-mt5/run && \
    echo "oneshot" > /etc/s6-overlay/s6-rc.d/init-mt5/type && \
    echo "/etc/s6-overlay/s6-rc.d/init-mt5/run" > /etc/s6-overlay/s6-rc.d/init-mt5/up && \
    echo "init-envfile" > /etc/s6-overlay/s6-rc.d/init-mt5/dependencies.d/init-envfile && \
    echo "init-mt5" >> /etc/s6-overlay/s6-rc.d/user/contents.d/init-mt5



# Headless mode entrypoint: Xvfb + MT5 via start.sh (runtime install)
RUN printf '#!/bin/bash\n\
echo "[headless] Starting Xvfb..."\n\
mkdir -p /tmp/.X11-unix\n\
chmod 1777 /tmp/.X11-unix\n\
# Kill any existing Xvfb processes on display :99\n\
pkill -f "Xvfb.*:99" 2>/dev/null || true\n\
rm -f /tmp/.X99-lock 2>/dev/null || true\n\
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp -ac +extension GLX +extension RANDR &\n\
XVFB_PID=$!\n\
sleep 3\n\
# Check if Xvfb started successfully\n\
if ! kill -0 $XVFB_PID 2>/dev/null; then\n\
  echo "[headless] Xvfb failed to start"\n\
  exit 1\n\
fi\n\
echo "[headless] Xvfb started successfully"\n\
export DISPLAY=:99\n\
export WINEPREFIX=/opt/mt5-prefix\n\
export WINEDLLOVERRIDES="winemenubuilder.exe=d"\n\
export XDG_RUNTIME_DIR=/tmp\n\
export XDG_DATA_HOME=/config/.local/share\n\
# Run start.sh which handles MT5 installation and launch\n\
bash /Metatrader/start.sh\n\
wait\n' > /Metatrader/headless.sh && \
    chmod +x /Metatrader/headless.sh


# Entrypoint wrapper: selects headless or full VNC mode
RUN printf '#!/bin/bash\n\
if [ "$HEADLESS" = "true" ]; then\n\
  exec /Metatrader/headless.sh\n\
else\n\
  exec /init\n\
fi\n' > /Metatrader/entrypoint.sh && \
    chmod +x /Metatrader/entrypoint.sh

ENTRYPOINT ["/Metatrader/entrypoint.sh"]