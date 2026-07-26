FROM gmag11/metatrader5_vnc:latest

# Install dependencies
RUN mkdir -pm755 /etc/apt/keyrings && \
    wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
RUN apt-get update && \
    apt-get install -y python3-xdg python3-pip xdotool xvfb && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --break-system-packages --no-cache-dir mt5linux

# Fix mt5linux: remove -w flag default
RUN sed -i 's/-w//g' /usr/local/bin/mt5linux 2>/dev/null || true

# Fix nginx: KasmVNC serves both HTTP + websocket on port 6901, not 6900
RUN sed -i 's|http://127.0.0.1:6900;|http://127.0.0.1:6901;|g' /defaults/default.conf

# Revert stale startwm patches
RUN sed -i '/^# Run MT5 install/d' /defaults/startwm.sh

# Pre-initialize Wine prefix in image layer (NOT on exFAT host mount)
ENV WINEPREFIX=/opt/mt5-prefix
ENV WINEARCH=win64

# Initialize Wine prefix during build (overlayfs supports symlinks/permissions)
RUN wineboot -u 2>/dev/null || true && \
    for i in $(seq 30); do \
      if [ -f "${WINEPREFIX}/system.reg" ]; then break; fi; \
      sleep 1; \
    done

# Make Wine prefix writable by abc user (container runs non-root for VNC)
RUN chmod -R 777 /opt/mt5-prefix

# Disable duplicate autostart (init-mt5 service already handles MT5 launch)
RUN printf '' > /defaults/autostart

# Environment variable defaults for custom scripts
ENV COMPANY_ENV="production"
ENV MT5_BROKER_SERVER=""
ENV MT5_BROKER_PORT="443"
ENV COMPANY_REGION="us-east-1"
ENV ENABLE_MT5LINUX_API="true"
ENV HEADLESS="false"

# Copy custom scripts (replaces base image start.sh sed modifications)
COPY Metatrader/start.sh /Metatrader/start.sh
COPY Metatrader/headless.sh /Metatrader/headless.sh
COPY Metatrader/monitor-mt5-logs.sh /Metatrader/monitor-mt5-logs.sh
RUN chmod +x /Metatrader/start.sh /Metatrader/headless.sh /Metatrader/monitor-mt5-logs.sh

# Create s6 init-mt5 service: wait for display, run start.sh
RUN mkdir -p /etc/s6-overlay/s6-rc.d/init-mt5/dependencies.d && \
    printf '#!/usr/bin/with-contenv bash\nset -e\n\
export DISPLAY=:1\n\
\n\
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
fi\n' > /etc/s6-overlay/s6-rc.d/init-mt5/run && \
    chmod +x /etc/s6-overlay/s6-rc.d/init-mt5/run && \
    echo "oneshot" > /etc/s6-overlay/s6-rc.d/init-mt5/type && \
    echo "/etc/s6-overlay/s6-rc.d/init-mt5/run" > /etc/s6-overlay/s6-rc.d/init-mt5/up && \
    echo "init-envfile" > /etc/s6-overlay/s6-rc.d/init-mt5/dependencies.d/init-envfile && \
    echo "init-mt5" >> /etc/s6-overlay/s6-rc.d/user/contents.d/init-mt5

# Window management script: waits for X display + MT5 windows, then resizes
RUN printf '#!/bin/bash\n\
for i in $(seq 30); do\n\
  if DISPLAY=:1 xdotool get_desktop >/dev/null 2>&1; then\n\
    break\n\
  fi\n\
  sleep 2\n\
done\n\
\n\
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

# Entrypoint wrapper: selects headless or full VNC mode
RUN printf '#!/bin/bash\n\
if [ "$HEADLESS" = "true" ]; then\n\
  exec /Metatrader/headless.sh\n\
else\n\
  exec /init\n\
fi\n' > /Metatrader/entrypoint.sh && \
    chmod +x /Metatrader/entrypoint.sh

ENTRYPOINT ["/Metatrader/entrypoint.sh"]