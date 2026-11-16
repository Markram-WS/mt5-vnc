# Production headless MT5 image - lightweight Wine base (no KasmVNC/nginx/s6)
# Base: tobix/wine (Debian trixie + Wine 10 stable + Xvfb + tini) ~803MB
# Target size < 2GB (dev gmag11 image is ~8.8GB)
FROM tobix/wine:stable

# ---------------------------------------------------------------------------
# Install Linux-side deps required by start.sh / headless.sh / mt5linux API
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-xdg \
        procps \
        iproute2 \
        winbind \
    && rm -rf /var/lib/apt/lists/*

# mt5linux API server (Linux side, connects to MT5 via Wine MCP)
RUN pip install --break-system-packages --no-cache-dir mt5linux rpyc plumbum numpy pyxdg

# Fix mt5linux: remove -w flag default
RUN sed -i 's/-w//g' /usr/local/bin/mt5linux 2>/dev/null || true

# ---------------------------------------------------------------------------
# Wine prefix - pre-initialized in image layer (overlayfs, not exFAT host mount)
# ---------------------------------------------------------------------------
ENV WINEPREFIX=/opt/mt5
ENV WINEARCH=win64
ENV WINEDLLOVERRIDES="winemenubuilder.exe=d,mscoree=n"
# Runtime behaviour is fully dynamic: HEADLESS, ENABLE_MT5LINUX_API, and the
# MT5_AUTO_START_* EA config are injected at runtime from .env / compose /
# (on k8s) ConfigMap+Secret. Defaults for the MT5_AUTO_START_* keys live in
# Metatrader/start.sh, so neither the image nor a rebuild is needed to change them.

RUN mkdir -p "$WINEPREFIX" && \
    xvfb-run -a WINEDEBUG=-all wineboot 2>/dev/null || true

# Block MT5 LiveUpdate (auto-update breaks under Wine); start.sh also re-appends
# to /etc/hosts at runtime because the container runtime regenerates it.
RUN printf '127.0.0.1 update.mql5.com\n127.0.0.1 updates.mql5.com\n' >> /etc/hosts

# ---------------------------------------------------------------------------
# Copy scripts (verified working in dev) + MQL5 (EAs/services shipped in image)
# ---------------------------------------------------------------------------
COPY Metatrader/headless.sh /Metatrader/headless.sh
COPY Metatrader/start.sh /Metatrader/start.sh
COPY Metatrader/monitor-mt5-logs.sh /Metatrader/monitor-mt5-logs.sh
COPY Metatrader/log-retention.sh /Metatrader/log-retention.sh
COPY mql5/ /tmp/mql5/
RUN mkdir -p "/opt/mt5/drive_c/Program Files/MetaTrader 5" && \
    cp -a /tmp/mql5/. "/opt/mt5/drive_c/Program Files/MetaTrader 5/MQL5/" && \
    rm -rf /tmp/mql5

RUN chmod +x /Metatrader/headless.sh /Metatrader/start.sh /Metatrader/monitor-mt5-logs.sh /Metatrader/log-retention.sh

# Entrypoint: tini -> headless.sh (Xvfb :99 -> start.sh). No s6 in this image.
ENTRYPOINT ["/tini", "--", "/Metatrader/headless.sh"]
