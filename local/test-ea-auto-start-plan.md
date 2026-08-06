# Plan: Create Test EA with Auto-Start

## Context

The repo is an MT5 Docker container with a bind-mounted `mql5/` directory. Currently there are no custom Expert Advisors in `mql5/Experts/` and no auto-start EA mechanism in `start.sh`. The request is to create a simple test EA that prints on `OnInit` and `OnTick`, and configure it to auto-start when MT5 launches.

## Approach

### Step 1: Create the test EA file

Create `mql5/Experts/TestAutoStartEA.mq5` — a minimal EA that:
- Has `OnInit()` with `Print("TestAutoStartEA: OnInit")` and returns `INIT_SUCCEEDED`
- Has `OnTick()` with `Print("TestAutoStartEA: OnTick")`
- Has `OnDeinit()` with `Print("TestAutoStartEA: OnDeinit")`
- Includes standard `#property` directives (copyright, version, description)
- Uses a magic number input (`InpMagic`) for position identification

This file is placed in the `mql5/` directory so it gets bind-mounted into the container at `/opt/mt5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/`.

### Step 2: Add EA auto-start to start.sh

Add a function `enable_auto_start_ea()` to `Metatrader/start.sh` that:
1. Waits for the MT5 terminal data directory to appear under the Wine prefix (`$WINEPREFIX/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/`)
2. Finds the terminal UUID subdirectory (the only `????????-????-????-????-????????????` directory)
3. Writes a `startup.ini` file into that directory with:
   ```ini
   [Startup]
   Expert=TestAutoStartEA
   ```
4. Logs the action so it appears in container stdout

This function is called **after** MT5 is launched (after the xdotool login block, before log monitoring), so the terminal data directory should exist by then. If the directory doesn't exist yet, it retries for up to 30 seconds.

### Step 3: Add `MT5_AUTO_START_EA` env var to docker-compose.yml and start.sh

- Add `MT5_AUTO_START_EA` environment variable to `docker-compose.yml` (default: `TestAutoStartEA`)
- In `start.sh`, read `MT5_AUTO_START_EA` (defaulting to `TestAutoStartEA`) so the EA name is configurable
- This lets users override which EA auto-starts without editing scripts

### Step 4: Add the EA to the log monitor's EA log path

The `monitor-mt5-logs.sh` already monitors `*/MQL5/Logs/*` for EA logs. No change needed — the test EA's Print() output will appear in the EA log stream automatically.

## Critical files & anchors

- `mql5/Experts/TestAutoStartEA.mq5` — new test EA source file (bind-mounted into container)
- `Metatrader/start.sh` — add `enable_auto_start_ea()` function and call it after MT5 launch (after xdotool block, before log monitoring)
- `docker-compose.yml` — add `MT5_AUTO_START_EA` env var to the `mt5-node` service
- `Metatrader/monitor-mt5-logs.sh` — no change needed; already monitors EA logs

## Verification

1. **Build and start the container**: `podman compose up -d`
2. **Check EA file is present in container**: `podman exec mt5_app ls -la "/opt/mt5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/TestAutoStartEA.mq5"`
3. **Check startup.ini was written**: `podman exec mt5_app find /opt/mt5/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal -name startup.ini -exec cat {} \;`
4. **Check EA log output**: `podman logs mt5_app | grep "TestAutoStartEA"` — should show `OnInit` and `OnTick` lines
5. **Verify auto-start EA env var**: `podman exec mt5_app env | grep MT5_AUTO_START_EA` — should show `TestAutoStartEA`
