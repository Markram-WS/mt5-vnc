# MT5 Docker Container

MetaTrader 5 Docker container with support for both development (VNC) and production (headless) modes. Features mt5linux API for programmatic MT5 control and runtime MT5 installation for portability.

## Features

- **Dual Operation Modes**:
  - **Dev Mode**: VNC on port 3000 + mt5linux API on port 8001
  - **Headless Mode**: mt5linux API only (port 8002), no VNC overhead
- **Runtime MT5 Installation**: MT5 installs on first container start, keeping the image portable
- **mt5linux API**: Python-based API for controlling MT5 programmatically
- **MQL5 Volume Support**: Mount external Expert Advisors (EAs) from host
- **Wine Prefix**: Optimized Wine configuration at `/opt/mt5-prefix`
- **Rootless Compatible**: Works with rootless Podman

## Quick Start

### Prerequisites

- Podman or Docker
- For VNC access: VNC client (any browser-based VNC works with KasmVNC)

### Build

```bash
cd /media/wasan/Storage/mt5
podman build -t mt5-mt5-node .
```

### Dev Mode (VNC + API)

```bash
# Start container
podman compose up -d

# Access VNC
# Open browser to: http://localhost:3000/vnc.html
# Credentials: Set in .env (default: MT5_USER / MT5_PASSWORD)

# Access mt5linux API
# Python example:
import rpyc
conn = rpyc.connect("localhost", 8001)
# Use mt5linux API...
conn.close()
```

### Headless Mode (API Only)

```bash
# Start container
podman run -d --name mt5-headless \
  -e HEADLESS=true \
  -p 8002:8001 \
  mt5-mt5-node

# Wait for MT5 installation (first run takes 2-3 minutes)
# Check logs: podman logs -f mt5-headless

# Access mt5linux API
import rpyc
conn = rpyc.connect("localhost", 8002)
# Use mt5linux API...
conn.close()
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `HEADLESS` | Set to `true` for headless mode | `false` |
| `MT5_USER` | VNC username | Set in `.env` |
| `MT5_PASSWORD` | VNC password | Set in `.env` |
| `MT5_CMD_OPTIONS` | MT5 command line options | `/config:C:\mt5_config.ini` |
| `VNC_RESOLUTION` | VNC screen resolution | `1280x800` |
| `WINEPREFIX` | Wine prefix path | `/opt/mt5-prefix` |
| `WINEARCH` | Wine architecture | `win64` |

### Volume Mounts

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `./mql5` | `/opt/mt5-prefix/drive_c/Program Files/MetaTrader 5/MQL5/Experts` | Expert Advisors |
| `./config` | `/config` | MT5 configuration files |

### Ports

| Mode | Port | Protocol | Purpose |
|------|------|----------|---------|
| Dev | 3000 | HTTP | KasmVNC web interface |
| Dev | 8001 | TCP | mt5linux API |
| Headless | 8001 | TCP | mt5linux API (mapped to host 8002) |

## Architecture

### Runtime Installation

MT5 is installed at container first start rather than during image build due to Wine installer limitations under X servers. This approach provides:

- **Portability**: Image can be rebuilt without reinstalling MT5
- **Flexibility**: MT5 can be updated by deleting the wine prefix
- **Performance**: First start takes 2-3 minutes, subsequent starts are fast

### X Server Configuration

- **Dev Mode**: Uses base image's KasmVNC on display `:1`
- **Headless Mode**: Uses Xvfb on display `:99` with GLX and RANDR extensions

### Wine Configuration

- Wine prefix: `/opt/mt5-prefix`
- Architecture: win64
- MT5 runs with `/portable` flag
- wineprefix ownership warnings are expected in rootless mode

## Troubleshooting

### First Container Start Takes Longer

**Expected behavior**: MT5 installation takes 2-3 minutes on first start.

**Check logs**:
```bash
podman logs -f <container_name>
```

**Look for**:
- `[headless] Starting Xvfb...` / `[headless] Xvfb started successfully`
- `[7/7] Starting the mt5linux server...`
- `server started on [0.0.0.0]:8001`

### mt5linux API Connection Failed

**Verify mt5linux is running**:
```bash
# Inside container
podman exec <container_name> python3 -c 'import rpyc; conn = rpyc.connect("localhost", 8001); print("OK")'
```

**Check port exposure**:
```bash
podman port <container_name>
```

### VNC Shows 401 Unauthorized

**Use correct credentials** from `.env`:
```bash
cat .env | grep MT5_USER
cat .env | grep MT5_PASSWORD
```

### MT5 Installer Fails

**Clean wine prefix and restart**:
```bash
podman exec <container_name> rm -rf /opt/mt5-prefix
podman restart <container_name>
```

### ShellExecuteEx Failed Errors

**Expected behavior**: During MT5 installation, these errors are normal. MT5 installer will complete despite these warnings.

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
curl -s -u '<MT5_USER>:<MT5_PASSWORD>' -o /dev/null -w "%{http_code}" http://localhost:3000/vnc.html
# Expected: 200

# Test mt5linux API
podman run --rm --network host python:3.11 bash -c 'pip install rpyc -q && python3 -c "import rpyc; conn = rpyc.connect(\"127.0.0.1\", 8001); print(\"Connected\"); conn.close()"'
# Expected: "Connected"

podman compose down
```

### Headless Mode Verification

```bash
podman run -d --name mt5-headless -e HEADLESS=true -p 8002:8001 mt5-mt5-node

# Wait for MT5 installation
sleep 120

# Test mt5linux API
podman run --rm --network host python:3.11 bash -c 'pip install rpyc -q && python3 -c "import rpyc; conn = rpyc.connect(\"127.0.0.1\", 8002); print(\"Connected\"); conn.close()"'
# Expected: "Connected"

# Verify no VNC port exposed
podman port mt5-headless
# Expected: 8001/tcp -> 0.0.0.0:8002 (no 3000 port)

# Verify MT5 installation
podman exec mt5-headless ls -la "/opt/mt5-prefix/drive_c/Program Files/MetaTrader 5/terminal64.exe"
# Expected: File exists

podman rm -f mt5-headless
```

### MQL5 Volume Verification

```bash
podman run --rm --entrypoint sh -v $(pwd)/mql5:/opt/mt5-prefix/drive_c/Program\ Files/MetaTrader\ 5/MQL5/Experts:ro mt5-mt5-node -c 'ls -la "/opt/mt5-prefix/drive_c/Program Files/MetaTrader 5/MQL5/Experts"'
```

## Technical Details

### Base Image

Based on `gmag11/metatrader5_vnc:latest` which includes:
- KasmVNC X server
- Wine configuration
- MetaTrader 5 base files

### Key Fixes Applied

1. **mt5linux API**: Removed `-w` flag incompatible with mt5linux v1.0.3+
2. **Wine Prefix**: Mapped from `/config/.wine` to `/opt/mt5-prefix`
3. **Environment Variable**: Fixed `MT5_CMD_OPTION` → `MT5_CMD_OPTIONS`
4. **Headless Mode**: Implemented Xvfb-based headless operation with robust error handling

### Container Files

- `/Metatrader/start.sh` - MT5 installation and launch
- `/Metatrader/headless.sh` - Headless mode entrypoint
- `/Metatrader/entrypoint.sh` - HEADLESS toggle wrapper
- `/Metatrader/resize-windows.sh` - VNC window auto-sizing
- `/etc/s6-overlay/s6-rc.d/init-mt5/run` - Dev mode MT5 initialization

### mt5linux API Usage

The mt5linux server runs on port 8001 (dev) or 8002 (headless) and provides Python-based control over MT5:

```python
import rpyc

# Connect to mt5linux
conn = rpyc.connect("localhost", 8001)

# Access mt5linux API
mt5 = conn.root

# Example: Get terminal info
terminal_info = mt5.terminal_info()

# Example: Execute MQL5 code
result = mt5.execute('Print("Hello from mt5linux")')

conn.close()
```

## Performance Considerations

- **First Start**: 2-3 minutes for MT5 installation
- **Subsequent Starts**: ~30 seconds (MT5 already installed)
- **Memory Usage**: ~500MB base, +200MB with MT5 running
- **Headless vs Dev**: Headless mode saves ~100MB memory (no VNC)

## Security Notes

- VNC credentials are stored in `.env` file - keep this file secure
- mt5linux API has no built-in authentication - use network security
- Wine prefix warnings about ownership are expected in rootless mode
- MT5 runs with elevated privileges within the container

## License

This project builds upon the gmang11/metatrader5_vnc base image and maintains compatibility with its licensing terms.

## Support

For issues related to:
- **Base image**: Refer to [gmag11/metatrader5_vnc](https://github.com/gmag11/metatrader5_vnc)
- **mt5linux**: Refer to [mt5linux documentation](https://github.com/fabfranz/mql5)
- **This implementation**: Check troubleshooting section or logs