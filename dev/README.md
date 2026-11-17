# MT5 dev container (VNC)

MetaTrader 5 dev image: KasmVNC UI on port 3000 plus the mt5linux API on 8001,
with mt5linux enable/disable toggle, configurable MT5 auto-login credentials,
company environment labels, and comprehensive log monitoring. It is the **dev**
image and runs **on the local kind cluster** (dev-only) —
`./scripts/kind-up.sh` builds `localhost/mt5-dev:dev`, loads it into kind and
applies `deploy/overlays/kind-dev`; there is no compose path any more.

## Features

- **Dev Mode**: VNC on port 3000 + mt5linux API on port 8001
- **Runtime MT5 Installation**: MT5 installs on first container start, keeping the image portable
- **mt5linux API Toggle**: Enable/disable via `ENABLE_MT5LINUX_API` env var (default: enabled)
- **MT5 Auto-Login**: CLI credentials + xdotool GUI auto-login fallback (MT5 build 3000+ dropped CLI auth support)
- **Company Environment**: `COMPANY_ENV`, `COMPANY_REGION`, `MT5_BROKER_SERVER`, `MT5_BROKER_PORT`
- **Comprehensive Log Monitoring**: Streams EA, System, Trading, Tester, and Indicator logs to container stdout
- **EA Auto-Start**: `startup.ini` (`Expert`/`Symbol`/`Period`) is written by `start.sh` before every MT5 launch into both the AppData terminal dir and the portable-mode install root. MT5 build 6090 reads it and attaches the EA to a chart on boot — verified across restarts/rebuilds (see TROUBLESHOOT §3)
- **All Logs on STDOUT**: `init-mt5` runs as an s6 longrun service and execs `start.sh` in the foreground — every log (install, launch, mt5linux, monitor) appears in `kubectl -n mt5 logs -f deploy/mt5`
- **MQL5 Tree**: the pod clones the repo at `MQL5_GIT_REF` into an `emptyDir` mounted at `/opt/mt5/drive_c/Program Files/MetaTrader 5/MQL5/` (EAs, indicators, scripts)
- **Wine Prefix**: PVC `mt5-prefix` → `/opt/mt5/` (persists the entire Wine prefix — MT5 install, profile, session — across pod restarts)
- **MT5 LiveUpdate Blocked**: `update.mql5.com` / `updates.mql5.com` → `127.0.0.1` via the pod's `hostAliases` + a `start.sh` fallback

## Configuration

### Environment Variables

Non-secret values live in `ConfigMap mt5-env` (`deploy/base/configmap.yaml`);
the credentials come from `Secret mt5-secrets`, which `scripts/secrets.sh`
creates from the repo-root `.env` (`MT5_VNC_USER` → `CUSTOM_USER`,
`MT5_VNC_PASSWORD` → `PASSWORD`).

| Variable | Source | Description | Default |
|----------|--------|-------------|---------|
| `HEADLESS` | `mt5-env` | Set to `true` for headless mode | `false` |
| `ENABLE_MT5LINUX_API` | `mt5-env` | Enable/disable mt5linux API | `true` |
| `MT5_BROKER_SERVER` | `mt5-env` | Broker server address | — |
| `MT5_BROKER_PORT` | `mt5-env` | Broker server port | `443` |
| `COMPANY_ENV` | `mt5-env` | Deployment environment label | `production` |
| `COMPANY_REGION` | `mt5-env` | Geographic region label | `us-east-1` |
| `MT5_AUTO_START_EA` | `mt5-env` | EA auto-attached to a chart on launch | `TestAutoStartEA` |
| `MT5_AUTO_START_SYMBOL` | `mt5-env` | Symbol for the auto-attached chart | `EURUSD` |
| `MT5_AUTO_START_PERIOD` | `mt5-env` | Timeframe for the auto-attached chart (`M1`, `H1`, `D1`, …) | `H1` |
| `LOG_RETENTION_DAYS` | `mt5-env` | Delete MT5 log files older than N days (`0` = off) | `7` |
| `LOG_RETENTION_INTERVAL` | `mt5-env` | Seconds between log cleanups | `86400` |
| `WINEPREFIX` | `mt5-env` | Wine prefix path | `/opt/mt5` |
| `VNC_RESOLUTION` | `mt5-env` | VNC screen resolution | `1280x800` |
| `CUSTOM_USER` | `.env` | KasmVNC user (`MT5_VNC_USER`) | — |
| `PASSWORD` | `.env` | KasmVNC password (`MT5_VNC_PASSWORD`) | — |

There is no MT5 account variable: the terminal logs in from its profile (see
`deploy/README.md`, "Login profile lifecycle"). The VNC pair is not generated
per overlay either: it lives in the repo-root `.env` and reaches the cluster
only through `scripts/secrets.sh` (see `docs/secrets.md`).

### Storage

| Source | Container Path | Purpose |
|--------|---------------|---------|
| PVC `mt5-prefix` (hostPath `/var/lib/mt5/prefix` in the node) | `/opt/mt5/` | Entire Wine prefix — MT5 install, profile, session, logs persist across pod restarts and dev↔prod switches |
| `emptyDir`, filled by the `fetch-mql5` init container | `/opt/mt5/drive_c/Program Files/MetaTrader 5/MQL5/` | Expert Advisors, indicators, scripts, profiles (per-pod; runtime writes die with the pod) |
| `emptyDir` (memory, 256Mi) | `/dev/shm` | Wine shared memory |

`startup.ini` is **not** mounted: `start.sh` rewrites it from the
`MT5_AUTO_START_*` env before every launch.

> The repo checkout itself is never mounted into the pod; the MQL5 tree comes
> from git at `MQL5_GIT_REF` (pinned tag `mql5-v1`). Editing `mql5/` in the
> checkout has no effect until it is committed and the tag bumped.

### Ports

| Mode | Host | Container | Purpose |
|------|------|-----------|---------|
| Dev | 3000 | 3000 | KasmVNC web interface |
| Both | 8001 | 8001 | mt5linux API |

kind maps host `3000 → node 30300` and host `8001 → node 30801`; in prod nothing
listens on 3000.

## Architecture

### Runtime Installation

MT5 is installed at container first start rather than during image build. The Wine prefix is pre-initialized during the image build on overlayfs (not on the host's exFAT filesystem, which lacks symlink support required by Wine) and seeded into the PVC once by the `seed-prefix` init container.

### Custom Scripts

The container uses custom scripts that replace the base image's start.sh:

| Script | Purpose |
|--------|---------|
| `/Metatrader/start.sh` | MT5 installation, API toggle, auto-login, log monitoring |
| `/Metatrader/headless.sh` | Xvfb-based headless mode |
| `/Metatrader/monitor-mt5-logs.sh` | Comprehensive log streaming (EA, System, Trading, Tester, Indicator) |
| `/Metatrader/entrypoint.sh` | HEADLESS toggle wrapper |
| `/Metatrader/resize-windows.sh` | VNC window auto-sizing |

### Startup Service (`init-mt5`)

MT5 is launched by a custom s6 service (`/etc/s6-overlay/s6-rc.d/init-mt5`) that:

- Is a **longrun** service (auto-restarts the setup if MT5 exits)
- Waits for the KasmVNC display socket (`/tmp/.X11-unix/X1`) before launching
- Runs `/Metatrader/start.sh` **as root** in the foreground with no log-file redirect, so all output streams to container STDOUT (`kubectl -n mt5 logs -f deploy/mt5`)
- Does not write `/tmp/mt5-startup.log` (removed — that file redirect previously failed under rootless Podman user namespaces and silently stopped MT5 from ever launching)

### Log Monitoring

`monitor-mt5-logs.sh` streams all MT5 log files to container stdout with type prefixes:

| Prefix | Source |
|--------|--------|
| `[EA:filename.log]` | Expert Advisor logs |
| `[EXPERT:filename.log]` | Expert-specific logs |
| `[INDICATOR:filename.log]` | Indicator logs |
| `[SYSTEM:filename.log]` | Terminal system logs |
| `[TESTER:filename.log]` | Strategy tester logs |

MT5 runs in **portable mode**, so EA logs are written to the install dir
`/opt/mt5/drive_c/Program Files/MetaTrader 5/MQL5/logs` (i.e. the pod's emptyDir)
rather than `AppData/Roaming/MetaQuotes/Terminal`. The monitor watches both
locations.

Two encoding pitfalls are handled by the monitor:

- MT5 log files are **UTF-16LE**. `tail -F` splits lines on byte `0x0A`, but the UTF-16
  newline is `0A 00`, so the stream ends up misaligned by one byte. The monitor strips NUL
  bytes (`stdbuf -oL tr -d '\000'`) instead of using `iconv`, which would mangle every line.
- `stdbuf -oL` forces line buffering; without it `tr` block-buffers ~4 KB and delays EA ticks
  by tens of seconds.

Directory discovery uses case-insensitive `find -ipath` matching (the emptyDir is
always lowercase, but a copied-in tree may not be).

### MT5 Authentication Strategy

MT5 build 3000+ dropped support for command-line `/login:`/`/password:`/`/server:` parameters. The container uses a two-layer approach:

1. **CLI parameters** — MT5 is launched with `/login:ACCOUNT /password:PASS /server:SERVER /portable` in the background (works on some builds)
2. **xdotool GUI auto-login** — While MT5 is running, `start.sh` uses `xdotool` to type credentials into the login window via X11 automation. Works with both KasmVNC (`:1`) and Xvfb (`:99`) displays, with a 60-second retry loop.

Both are attempted automatically. MT5 always starts — if auto-login fails, log in manually via VNC.

> **Note:** MT5 must be launched in the **background** (`&`) before the xdotool login step. A foreground `wine` call blocks `start.sh` until the terminal exits, which prevented the GUI auto-login from ever running.

### Server Address Resolution

If `MT5_SERVER` is not set but `MT5_BROKER_SERVER` + `MT5_BROKER_PORT` are, the address is constructed as `server:port`.

### Auto-Login Flow (start.sh)

```
[7/7] enable_auto_start_ea()
        ├─ UUID dir exists?  YES → write startup.ini (Expert/Symbol/Period)
        │                        to AppData <uuid>/ AND install root
        └─ NO (fresh volume) → launch MT5 briefly → wait for UUID dir
             → write startup.ini → relaunch MT5 once so it reads it
        └─ [7/7] launch_mt5() guaranteed (existing volume fix: MT5 used to
             never launch because launch_mt5 only ran inside the fresh-volume
             branches of enable_auto_start_ea)
        └─ xdotool GUI auto-login (60s retry loop)
             ├─ Login window found → type credentials via X11
             └─ No window found → skip (CLI auth succeeded)
```

### EA Auto-Start

`start.sh` writes `startup.ini` **before** MT5 reads it, into **two** locations:

1. The AppData terminal instance directory
   (`AppData/Roaming/MetaQuotes/Terminal/<uuid>/startup.ini`) — kept by MT5 but ignored
2. The portable-mode **install root**
   (`<prefix>/drive_c/Program Files/MetaTrader 5/startup.ini`) — MT5 reads (and consumes)
   this at startup; `start.sh` re-creates it on every boot

```ini
[StartUp]
Expert=TestAutoStartEA
Symbol=EURUSD
Period=H1
```

On a fresh volume (no UUID dir yet) MT5 is started briefly to create the profile, then
relaunched once. Configure via `MT5_AUTO_START_EA`, `MT5_AUTO_START_SYMBOL`,
`MT5_AUTO_START_PERIOD` (see Environment Variables).

> **Known limitation:** this MT5 build (6090) under a prefix without a saved
> EA state does **not** reliably auto-attach the EA — the install-root
> `startup.ini` is consumed before account authorization completes, and the
> attach fails silently. Verified across formats (`[StartUp]`/`[Startup]`) and
> both locations. The `mql5/Profiles` tree is tracked precisely to avoid this:
> the saved default chart carries the EA. See TROUBLESHOOT §3.

### Wine pip Timeouts

Some Wine Python packages (mt5linux, rpyc) hang during pip download due to Wine networking issues. These packages are skipped in Wine — mt5linux runs on the Linux side and does not require them.

### MT5 Runs as Root

MT5 (wine) runs as the container's root user instead of the non-root `abc` user. This is intentional and required for **rootless Podman**:

- Container root maps to the host user (e.g. `wasan`, uid 1000), which is the owner of the PVC-backed prefix — so MT5 can write/compile EAs. The `abc` user (uid 911) maps to a subuid and *cannot* write there.
- The Wine prefix is built as root during image build (registry points to `C:\users\root`), so wine-as-root matches ownership exactly — no `chown` gymnastics, no user-namespace permission traps.
- KasmVNC runs with `-SecurityTypes None` and `/tmp/.X11-unix` is world-writable, so the root MT5 window renders normally in the browser.

### Duplicate start.sh Processes

If two instances of `start.sh` appear (abc + root), delete the stale autostart file persisted in the prefix and restart the pod:

```bash
kubectl -n mt5 exec deploy/mt5 -- rm -f /opt/mt5/.config/openbox/autostart
kubectl -n mt5 rollout restart deploy/mt5
```

## Verification

### Bring it up

```bash
./scripts/kind-up.sh                # build + load + apply + wait for Ready
```

### Dev Mode Verification

```bash
# VNC answers without credentials, then with them
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/        # 401
curl -s -o /dev/null -w '%{http_code}\n' -u '<user>:<password>' http://localhost:3000/   # 200

# mt5linux API (rpyc over TCP): a bare TCP connect is the cheapest check
timeout 3 bash -c 'cat < /dev/null > /dev/tcp/127.0.0.1/8001' && echo "8001 open" || echo "8001 closed"

# EA attached
kubectl -n mt5 exec deploy/mt5 -- sh -c 'tr -d "\000" < "/opt/mt5/drive_c/Program Files/MetaTrader 5/MQL5/logs/$(date +%Y%m%d).log" | tail'
```

### API Toggle Verification

Set `ENABLE_MT5LINUX_API: "false"` in the ConfigMap, re-apply the overlay and
restart; 8001 then refuses connections:

```bash
./scripts/kind-up.sh
curl -s -m 3 http://localhost:8001/ && echo "ERROR: API running" || echo "OK: API disabled"
```

## Troubleshooting

> For detailed root-cause analysis of the most common issues — **EA logs not
> appearing in `kubectl logs`**, **MT5 not launching on an existing volume**, and
> **the EA not auto-attaching despite `startup.ini`** — see
> [`TROUBLESHOOT.md`](./TROUBLESHOOT.md).

### First Container Start Takes Longer

MT5 installation takes 2-3 minutes on first start. Look for these log markers:

```
[init-mt5] Starting MT5 setup (logs on stdout)...
[start.sh] === MT5 Startup ===
[start.sh] [3/7] Installing MetaTrader 5...
[start.sh] [6/7] The mt5linux server is running on port 8001.
[start.sh] [7/7] Starting MT5 with auto-login credentials...
```

### mt5linux API Connection Failed

```bash
# Check if mt5linux is running
kubectl -n mt5 exec deploy/mt5 -- ps aux | grep mt5linux

# The API is the readiness probe target
kubectl -n mt5 get pods
```

### Permission Denied on Downloads

If you see `curl: (23) Failure writing output to destination`, the target filesystem doesn't support Wine prefix operations. The prefix lives in the ext4-backed PVC (`$MT5_DATA_DIR/prefix`); keep it off exFAT.

### VNC Shows 401 Unauthorized

```bash
# Credentials come from Secret mt5-secrets, created from the repo-root .env
kubectl -n mt5 get secret mt5-secrets -o jsonpath='{.data.CUSTOM_USER}' | base64 -d; echo
```

### Duplicate start.sh Processes

If two instances of `start.sh` appear (abc + root), delete the stale autostart and restart:

```bash
kubectl -n mt5 exec deploy/mt5 -- rm -f /opt/mt5/.config/openbox/autostart
kubectl -n mt5 rollout restart deploy/mt5
```

### MT5 Installer Fails

```bash
# Re-seed the prefix from the image (destroys the current prefix)
kubectl -n mt5 exec deploy/mt5 -- rm -rf /opt/mt5/drive_c/Program\ Files/MetaTrader\ 5
kubectl -n mt5 delete pod -l app.kubernetes.io/name=mt5
```

### ObRender: Cannot load Terminal.ico

MT5 may log `ObRender-Message: Cannot load image ".../Terminal.ico"` on startup. This is a non-fatal Wine rendering warning — the icon file is missing from the MT5 installation directory. The fix is applied automatically in `start.sh`:

A placeholder `Terminal.ico` is created if missing from the MT5 installation directory.

If the error persists, verify the icon file exists:

```bash
kubectl -n mt5 exec deploy/mt5 -- ls /opt/mt5/drive_c/Program\ Files/MetaTrader\ 5/Terminal.ico
```

## Security Notes

- VNC credentials live in the repo-root `.env` and reach the pod only as `Secret mt5-secrets` (`scripts/secrets.sh apply`) — keep both secure
- mt5linux API has no built-in authentication — use network security (firewall for production)
- No MT5 account credentials are configured anywhere: the terminal logs in from its login profile, so nothing account-related can appear in the pod's process list
- MT5 runs as root inside the container (see "MT5 Runs as Root" above) — a development convenience for rootless Podman, not a hardened production posture

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

1. **Wine Prefix**: Pre-initialized on overlayfs during build (not on host exFAT mount), seeded into the PVC by the `seed-prefix` init container
2. **MT5 Runs as Root**: Fixed `wine: '<prefix>' is not owned by you` under rootless Podman (see "MT5 Runs as Root")
3. **`init-mt5` Longrun Service**: Runs `start.sh` in the foreground as root; all logs stream to STDOUT (`kubectl logs`) instead of a `/tmp/mt5-startup.log` file redirect that failed under rootless Podman user namespaces
4. **Duplicate Autostart**: Disabled in Dockerfile + stale file removal in the prefix
5. **mt5linux API**: Removed `-w` flag incompatible with mt5linux v1.0.3+
6. **API Toggle**: `ENABLE_MT5LINUX_API` controls mt5linux launch
7. **MT5 Credentials**: MT5 launched in background, then xdotool GUI auto-login (a foreground `wine` call blocked the login step)
8. **Log Monitoring**: Comprehensive script covering all MT5 log types — watches both the portable install `MQL5/logs` and `AppData/.../MetaQuotes/Terminal`; decodes UTF-16LE by stripping NUL bytes with `stdbuf -oL tr -d '\000'` (a `tail -F` + `iconv` pipeline misaligned by one byte and block-buffered for seconds)
9. **Wine pip Timeouts**: Skipped mt5linux/rpyc in Wine (hang on download) — mt5linux runs on Linux side
10. **MT5 LiveUpdate Blocked**: `update.mql5.com` / `updates.mql5.com` → `127.0.0.1` via the pod's `hostAliases` + `start.sh` fallback
11. **EA Auto-Start (verified working)**: `startup.ini` written by `start.sh` before launch into both the AppData terminal dir and portable-mode install root; includes fresh-volume relaunch + a guaranteed `launch_mt5()` on existing volumes. MT5 build 6090 reads it and auto-attaches the EA on boot. Verified 2026-08-06: `expert TestAutoStartEA loaded successfully` on consecutive restarts + rebuilds with `OnTick` continuing in `MQL5/logs`. Cleanup: removed the dead Method 1 (`inject_common_ini`) and Method 2 (`build_cli_config`/`/config:`) code, so the boot-time `cannot load config "...autostart-cli.ini"` error no longer appears
12. **Existing-volume launch fix**: `launch_mt5()` was previously only called inside the fresh-volume branches of `enable_auto_start_ea()` — MT5 never started on an existing volume (empty VNC). Now launched unconditionally after `enable_auto_start_ea()`

## Performance Considerations

- **First Start**: 2-3 minutes for MT5 installation
- **Subsequent Starts**: ~30 seconds (MT5 already installed)
- **Memory Usage**: ~500MB base, +200MB with MT5 running
- **Headless vs Dev**: Headless mode saves ~100MB memory (no VNC)
- **API Disabled**: Saves ~30MB and reduces startup time by 5-10 seconds

## License

This project builds upon the gmag11/metatrader5_vnc base image and maintains compatibility with its licensing terms.
