# Checkpoint — 2026-08-05 (end of day)

Resume target: **EA auto-start in MT5 (build 6090, portable, under Wine)** so the EA
attaches to a chart at launch with **no manual action**. Approach: try methods in order,
**excluding method 3 (`xdotool`)**.

## Where we are
All work is recorded in `TROUBLESHOOT.md` §3 (rewritten as an ordered checklist).

| # | Method | Status |
|---|--------|--------|
| 1 | `[StartUp]`/`[Experts]` injected into `Config/common.ini` | **FAILED** — silently ignored |
| 2 | `/config:` CLI flag | **FAILED** — silently ignored |
| 3 | `xdotool` GUI drag | EXCLUDED |
| 4 | MQL5 **Service** | **IN PROGRESS** — compiled; needs one-time enable to persist |
| 5 | One-time manual attach → profile persistence | PENDING |

## What changed on disk (git status)
- `TROUBLESHOOT.md` — new file; §3 rewritten into the ordered checklist + status table.
- `Metatrader/start.sh` — added `inject_common_ini()` (Method 1) + `build_cli_config()` /
  `/config:` wiring (Method 2). Both **proven failed**; safe to remove later.
- `local/test-ea-auto-start-plan.md` — prior plan (pre-existing).
- New: `mql5/Services/TestAutoStartService.mq5` (+ compiled `.ex5` inside the container).
- Other dirty files (`.dockerignore`, `Dockerfile`, `README.md`, `docker-compose.yml`,
  `Metatrader/monitor-mt5-logs.sh` deleted) are **pre-existing** — not from today.

## Empirical findings (important, verified today)
- `startup.ini` (any location), `[StartUp]` in `common.ini`, and `/config:` are **all
  ignored** by build 6090 for EA auto-attach. Root-cause hypothesis (TROUBLESHOOT §3):
  attach is processed **before account authorization completes**, so it fails silently.
- **MetaEditor64.exe cannot compile while the MT5 terminal is running** ("not enough
  handles to start the platform"). Must `pkill -f terminal64.exe` first:
  ```bash
  podman exec mt5_app bash -c 'pkill -f terminal64.exe; sleep 5; \
    cd "/opt/mt5/drive_c/Program Files/MetaTrader 5" && \
    DISPLAY=:99 WINEPREFIX=/opt/mt5 WINEDEBUG=-all \
    wine MetaEditor64.exe "/compile:C:\Program Files\MetaTrader 5\MQL5\Services\<file>.mq5" /log'
  ```
  Result file lands next to the `.mq5`; log in `.../logs/metaeditor.log`.
- A freshly compiled, **never-run service does NOT auto-start** on restart. MT5 only
  reloads services that were running at last shutdown or explicitly enabled.

## Next steps (tomorrow)
1. **Method 4**: enable the service once so it persists across restarts. Options:
   - Edit the `[Common] Services=` mask in `common.ini` (currently `4294967295` = all
     enabled) and/or find the per-service "allow this service to run" flag.
   - Start the service once via VNC (acceptable one-time step, like Method 5).
   - Then restart the terminal and confirm `TestAutoStartService` lines appear in
     `MQL5/logs/<date>.log` **without** re-enabling.
   - Caveat: a Service runs chart-free `OnStart()` (loops) — it cannot attach EAs to
     charts. Good as a native auto-start proof / chart-free fallback, not as an EA launcher.
2) **Method 5 — profile persistence**: attach `TestAutoStartEA` once via VNC, shut MT5
   down **cleanly**, confirm `MQL5/Profiles/Charts/Default/chart01.chr` gains an `expert=`
   entry, then restart and check the EA comes back without re-attaching.
3. Once a method passes, **remove the failed Method 1+2 wiring** from `start.sh`.

## Useful commands
- Live-apply edited `start.sh`: `podman cp Metatrader/start.sh mt5_app:/Metatrader/start.sh`
- Restart MT5 session (keeps volume): `podman restart mt5_app`
- Check EA load: `podman exec mt5_app sh -c "tr -d '\000' < \".../logs/20260805.log\" |
  grep -iE 'expert.*loaded|TestAutoStart'"` (file is UTF-16LE → strip NUL first).
- Container is **currently Up** with MT5 authorized (15:xx), terminal running.