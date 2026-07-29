# MT5 Docker Container

MetaTrader 5 Docker container with support for both development (VNC) and production (headless) modes. Features mt5linux API with enable/disable toggle, configurable MT5 auto-login credentials, company environment variables, and comprehensive log monitoring.

## Features

- **Dual Operation Modes**:
  - **Dev Mode**: VNC on port 3000 + mt5linux API on port 8001
  - **Headless Mode**: mt5linux API only (port 8001), no VNC overhead
- **Runtime MT5 Installation**: MT5 installs on first container start, keeping the image portable
- **mt5linux API Toggle**: Enable/disable via `ENABLE_MT5LINUX_API` env var (default: enabled)
- **MT5 Auto-Login**: CLI credentials + xdotool GUI auto-login fallback (MT5 build 3000+ dropped CLI auth support)
- **Company Environment**: `COMPANY_ENV`, `COMPANY_REGION`, `MT5_BROKER_SERVER`, `MT5_BROKER_PORT`
- **Comprehensive Log Monitoring**: Streams EA, System, Trading, Tester, and Indicator logs to container stdout
- **MQL5 Volume**: `./mql5` bind mount → `/opt/mt5-prefix/drive_c/.../MQL5/Experts` (your EAs on exFAT)
- **VNC Config**: `mt5-config` named volume → `/config` (persists VNC settings in Docker storage)
- **Wine Prefix**: Pre-initialized on overlayfs during build (not on exFAT host mounts)
- **Rootless Compatible**: Works with rootless Podman

## Quick Start

### Prerequisites

- Podman or Docker
- For VNC access: VNC client (any browser-based VNC works with KasmVNC)

### Setup

```bash
# Clone / navigate to project
cd /media/wasan/Storage/mt5

# Configure environment
cp .env.example .env
# Edit .env with your credentials

# Build image
podman build -t mt5-mt5-node .
```

### Dev Mode (VNC + API)

```bash
# Start container
podman compose up -d

# Access VNC
# Open browser to: http://localhost:3000/vnc.html

# Access mt5linux API
import rpyc
conn = rpyc.connect("localhost", 8001)
# Use mt5linux API...
conn.close()
```

### Headless Mode (API Only)

```bash
podman run -d --name mt5-headless \
  -e HEADLESS=true \
  -e MT5_SERVER="broker.example.com:443" \
  -e MT5_ACCOUNT="12345678" \
  -e MT5_PASSWORD="yourpass" \
  -p 8001:8001 \
  mt5-mt5-node

# Check logs
podman logs -f mt5-headless
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `HEADLESS` | Set to `true` for headless mode | `false` |
| `ENABLE_MT5LINUX_API` | Enable/disable mt5linux API | `true` |
| `MT5_SERVER` | Full MT5 server address (server:port) | — |
| `MT5_ACCOUNT` | MT5 account number for auto-login | — |
| `MT5_PASSWORD` | MT5 account password | — |
| `MT5_BROKER_SERVER` | Broker server address (alt to MT5_SERVER) | — |
| `MT5_BROKER_PORT` | Broker server port | `443` |
| `COMPANY_ENV` | Deployment environment label | `production` |
| `COMPANY_REGION` | Geographic region label | `us-east-1` |
| `MT5_VNC_USER` | VNC username | Set in `.env` |
| `MT5_VNC_PASSWORD` | VNC password | Set in `.env` |
| `VNC_RESOLUTION` | VNC screen resolution | `1280x800` |
| `WINEPREFIX` | Wine prefix path | `/opt/mt5-prefix` |
| `WINEARCH` | Wine architecture | `win64` |

### Volume Mounts

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `mt5-config` | `/config` | VNC openbox config (Docker storage) |
| `./mql5` | `/opt/mt5-prefix/drive_c/Program Files/MetaTrader 5/MQL5/Experts` | Expert Advisors |
| `./logs` (optional) | `/opt/mt5-prefix/drive_c/users/container/AppData/Roaming/MetaQuotes/Terminal` | MT5 log persistence |

### Ports

| Mode | Port | Protocol | Purpose |
|------|------|----------|---------|
| Dev | 3000 | HTTP | KasmVNC web interface |
| Both | 8001 | TCP | mt5linux API |

## Architecture

### Runtime Installation

MT5 is installed at container first start rather than during image build. The Wine prefix is pre-initialized during Docker build on overlayfs (not on the host's exFAT filesystem, which lacks symlink support required by Wine).

### Custom Scripts

The container uses custom scripts that replace the base image's start.sh:

| Script | Purpose |
|--------|---------|
| `/Metatrader/start.sh` | MT5 installation, API toggle, auto-login, log monitoring |
| `/Metatrader/headless.sh` | Xvfb-based headless mode |
| `/Metatrader/monitor-mt5-logs.sh` | Comprehensive log streaming (EA, System, Trading, Tester, Indicator) |
| `/Metatrader/entrypoint.sh` | HEADLESS toggle wrapper |
| `/Metatrader/resize-windows.sh` | VNC window auto-sizing |

### Log Monitoring

`monitor-mt5-logs.sh` streams all MT5 log files to container stdout with type prefixes:

| Prefix | Source |
|--------|--------|
| `[EA:filename.log]` | Expert Advisor logs |
| `[EXPERT:filename.log]` | Expert-specific logs |
| `[INDICATOR:filename.log]` | Indicator logs |
| `[SYSTEM:filename.log]` | Terminal system logs |
| `[TESTER:filename.log]` | Strategy tester logs |

### MT5 Authentication Strategy

MT5 build 3000+ dropped support for command-line `/login:`/`/password:`/`/server:` parameters. The container uses a two-layer approach:

1. **CLI parameters** — Attempts `/login:ACCOUNT /password:PASS /server:SERVER /portable` first (may work on older builds)
2. **xdotool GUI auto-login** — If CLI params fail or MT5 shows a login dialog, `start.sh` uses `xdotool` to type credentials into the login window via X11 automation. Works with both KasmVNC (`:1`) and Xvfb (`:99`) displays, with a 60-second retry loop.

Both are attempted automatically. MT5 always starts — if auto-login fails, log in manually via VNC.
### Server Address Resolution

If `MT5_SERVER` is not set but `MT5_BROKER_SERVER` + `MT5_BROKER_PORT` are, the address is constructed as `server:port`.
### Auto-Login Flow (start.sh)

```
[7/7] Starting MT5 with auto-login credentials...
       ├─ CLI attempt (/login: /password: /server:)
       │    ├─ Success → MT5 running with credentials
       │    └─ Failure → MT5 launched in /portable mode
       └─ xdotool GUI auto-login (60s retry loop)
            ├─ Login window found → type credentials via X11
            └─ No window found → skip (CLI auth succeeded)
```
### Wine pip Timeouts

Some Wine Python packages (mt5linux, rpyc) hang during pip download due to Wine networking issues. These packages are skipped in Wine — mt5linux runs on the Linux side and does not require them.

### Duplicate start.sh Processes

If two instances of `start.sh` appear (abc + root), delete the stale autostart file persisted on the host volume:

```bash
rm -f config/.config/openbox/autostart
podman compose down && podman compose up -d
```
## Verification

### Build Verification

```bash
cd /media/wasan/Storage/mt5
podman build -t mt5-mt5-node .
```

### Dev Mode Verification

```bash
podman compose up -d

# Test VNC
curl -s -u '<MT5_VNC_USER>:<MT5_VNC_PASSWORD>' -o /dev/null -w "%{http_code}" http://localhost:3000/vnc.html
# Expected: 200

# Test mt5linux API
podman run --rm --network host python:3.11 bash -c 'pip install rpyc -q && python3 -c "import rpyc; conn = rpyc.connect(\"127.0.0.1\", 8001); print(\"Connected\"); conn.close()"'
# Expected: "Connected"

podman compose down
```

### Headless Mode with Credentials

```bash
podman run -d --name mt5-test \
  -e HEADLESS=true \
  -e MT5_ACCOUNT="123456" \
  -e MT5_PASSWORD="testpass" \
  -e MT5_SERVER="test.server.com:443" \
  -p 8002:8001 \
  mt5-mt5-node

# Wait for startup (first run: 2-3 min)
sleep 120

# Verify credential logs
podman logs mt5-test | grep -E "auto-login|/login|/password|/server"

# Test API
podman run --rm --network host python:3.11 bash -c 'pip install rpyc -q && python3 -c "import rpyc; conn = rpyc.connect(\"127.0.0.1\", 8002); print(\"Connected\"); conn.close()"'

# Verify MT5 binary
podman exec mt5-test ls -la "/opt/mt5-prefix/drive_c/Program Files/MetaTrader 5/terminal64.exe"

podman rm -f mt5-test
```

### API Toggle Verification

```bash
podman run -d --name mt5-no-api \
  -e HEADLESS=true \
  -e ENABLE_MT5LINUX_API=false \
  -p 8003:8001 \
  mt5-mt5-node

sleep 60

# Verify API is disabled (connection refused)
curl -s -m 3 http://localhost:8003/ && echo "ERROR: API running" || echo "OK: API disabled"

podman rm -f mt5-no-api
```

## Troubleshooting

### First Container Start Takes Longer

MT5 installation takes 2-3 minutes on first start. Look for these log markers:

```
[headless] Starting Xvfb...
[headless] Xvfb started successfully
[start.sh] [3/7] Installing MetaTrader 5...
[start.sh] [6/7] The mt5linux server is running on port 8001.
[start.sh] [7/7] Starting MT5 with auto-login credentials...
```

### mt5linux API Connection Failed

```bash
# Check if mt5linux is running
podman exec mt5_app ps aux | grep mt5linux

# Verify port
podman port mt5_app
```

### Permission Denied on Downloads

If you see `curl: (23) Failure writing output to destination`, the host filesystem (exFAT) doesn't support Wine prefix operations. Ensure the Wine prefix stays inside the container on overlayfs (do not mount `/opt/mt5-prefix` as a host volume).

### VNC Shows 401 Unauthorized

```bash
cat .env | grep MT5_VNC_USER
cat .env | grep MT5_VNC_PASSWORD
```

### Duplicate start.sh Processes

If two instances of `start.sh` appear (abc + root), delete the stale autostart:

```bash
rm -f config/.config/openbox/autostart
podman compose down && podman compose up -d
```

### MT5 Installer Fails

```bash
podman exec mt5_app rm -rf /opt/mt5-prefix
podman restart mt5_app
```

## Security Notes

- VNC credentials are stored in `.env` file — keep this file secure
- mt5linux API has no built-in authentication — use network security (firewall for production)
- MT5 account credentials passed as command-line args — secure `.env` accordingly
- Wine prefix is world-writable (777) inside the container — this is necessary because the container runs as a non-root user for VNC

## Container Files

```
/Metatrader/
├── start.sh               # Custom: install, API toggle, auto-login, log monitor
├── headless.sh             # Custom: Xvfb headless mode
├── monitor-mt5-logs.sh     # Comprehensive MT5 log streaming
├── entrypoint.sh           # HEADLESS toggle wrapper
└── resize-windows.sh       # VNC window auto-sizing
```

## mt5linux API Usage

```python
import rpyc

conn = rpyc.connect("localhost", 8001)
mt5 = conn.root

# Get terminal info
terminal_info = mt5.terminal_info()

# Execute MQL5 code
result = mt5.execute('Print("Hello from mt5linux")')

conn.close()
```

## Technical Details

### Base Image

Based on `gmag11/metatrader5_vnc:latest` which includes:
- KasmVNC X server
- Wine configuration
- MetaTrader 5 base files

### Key Fixes Applied

1. **Wine Prefix**: Pre-initialized on overlayfs during build (not on host exFAT mount)
2. **Wine Prefix Permissions**: World-writable (777) for non-root VNC user
3. **Duplicate Autostart**: Disabled in Dockerfile + stale file removal on host volume
4. **mt5linux API**: Removed `-w` flag incompatible with mt5linux v1.0.3+
5. **API Toggle**: `ENABLE_MT5LINUX_API` controls mt5linux launch
6. **MT5 Credentials**: CLI auth + xdotool GUI auto-login fallback (MT5 build 3000+ dropped CLI support)
7. **Log Monitoring**: Comprehensive script covering all MT5 log types
8. **Wine pip Timeouts**: Skipped mt5linux/rpyc in Wine (hang on download) — mt5linux runs on Linux side
## Performance Considerations

- **First Start**: 2-3 minutes for MT5 installation
- **Subsequent Starts**: ~30 seconds (MT5 already installed)
- **Memory Usage**: ~500MB base, +200MB with MT5 running
- **Headless vs Dev**: Headless mode saves ~100MB memory (no VNC)
- **API Disabled**: Saves ~30MB and reduces startup time by 5-10 seconds

## License

This project builds upon the gmag11/metatrader5_vnc base image and maintains compatibility with its licensing terms.