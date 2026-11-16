# Troubleshooting - MT5 Dev Environment

Common issues, root causes, and fixes for the MT5 dev pod (`mt5` in namespace `mt5`,
run with `./scripts/kind-up.sh`).

## 1. EA logs not appearing in `kubectl -n mt5 logs deploy/mt5`

**Symptom:** The EA is running (attached to a chart) but no `[EA:...]` lines show up in
container stdout, even though MT5 writes log lines continuously.

### Root cause
- MT5 runs in **portable mode**, so EA logs land in the install dir
  `<WINEPREFIX>/drive_c/Program Files/MetaTrader 5/MQL5/logs`
  (the pod's `emptyDir`, filled from git), **not** in
  `AppData/Roaming/MetaQuotes/Terminal` (that dir has no `MQL5/Logs`).
- MT5 log files are **UTF-16LE**. `tail -F` splits lines on byte `0x0A`, but the UTF-16
  newline is `0A 00`, so after `tail` the stream is misaligned by one byte. Feeding that to
  `iconv` mangles every line (mojibake).
- `tr` block-buffers its pipe output (~4 KB), delaying EA ticks by tens of seconds.

### Fix (in `Metatrader/monitor-mt5-logs.sh`)
- Watch the install `MQL5` dir **and** the AppData terminal dir.
- Match log dirs **case-insensitively** (`find -ipath`) because the emptyDir may hold a
  copied-in tree whose casing is not guaranteed.
- Decode log lines by **stripping NUL bytes** (`tr -d '\000'`) instead of `iconv`, with
  `stdbuf -oL` to force line buffering:
  ```bash
  decode() {
      local log_file="$1"
      local nul_count
      nul_count=$(head -c 8192 "$log_file" 2>/dev/null | tr -cd '\000' | wc -c)
      if [ -n "$nul_count" ] && [ "$nul_count" -gt 0 ]; then
          stdbuf -oL tr -d '\000'
      else
          cat
      fi
  }
  ```
- Aggregate `ALL_FILES` newline-separated (paths contain spaces) with `SEEN_FILES` dedupe.

### Verification
```bash
kubectl -n mt5 logs -f deploy/mt5   # expect [EA:…] ... TestAutoStartEA ... OnTick ...
```

## 2. MT5 never launched on an existing prefix (empty VNC / no MT5 window)

**Symptom:** On a pod recreate **with a pre-existing `mt5-prefix` PVC**, the VNC
UI (`http://localhost:3000/`) loads but the MetaTrader window never appears.
`kubectl -n mt5 logs deploy/mt5` shows `[7/7] Auto-start EA configured ...` but
**no** `[7/7] Launching MT5...`.

### Root cause
- The EA auto-start refactor only called `launch_mt5()` from inside
  `enable_auto_start_ea()`'s **fresh-volume** branches. On an existing volume the function
  wrote `startup.ini` and returned without ever launching MT5.

### Fix (in `Metatrader/start.sh`)
- Track a `mt5_started` flag set by `launch_mt5()`; after `enable_auto_start_ea()`, if MT5
  was not already started, call `launch_mt5()` unconditionally:
  ```bash
  enable_auto_start_ea
  if [ "$mt5_started" != true ]; then
      launch_mt5
  fi
  ```
- Apply live without a rebuild: copy the script into the running pod and let the s6
  longrun restart it:
  ```bash
  kubectl -n mt5 cp Metatrader/start.sh mt5-<pod>:/Metatrader/start.sh
  kubectl -n mt5 exec deploy/mt5 -- pkill -9 -f /Metatrader/start.sh
  ```

## 3. EA auto-start — what works (verified 2026-08-06, build 6090)

**Symptom solved:** After a container restart/recreate, MT5 is running and logged in, and
the EA attaches to a chart **automatically** — the terminal log shows
`expert TestAutoStartEA (EURUSD,H1) loaded successfully` right after boot, and the EA log
(`MQL5/logs/<date>.log`) fills with `OnTick` lines. No manual VNC drag required.

### Working mechanism: `startup.ini`
- `start.sh`'s `enable_auto_start_ea()` writes a UTF-16LE `startup.ini`
  (`[StartUp] Expert=<EA> / Symbol=<SYM> / Period=<TF>`) to **both**:
  - the AppData terminal dir `<Terminal>/<uuid>/startup.ini`, and
  - the install root `<prefix>/drive_c/Program Files/MetaTrader 5/startup.ini`.
- On the next launch, MT5 reads it and attaches the EA to a chart itself.
- Key requirement: **the account must already be authorized in the prefix** (login
  persisted in the `mt5-prefix` PVC). The attach is processed once the chart loads; with a
  pre-authorized prefix this happens reliably. On a brand-new prefix, the login completes
  first and the EA still attaches on the same or the next boot.

### Verified sequence (2026-08-06)
```text
15:15:10  MetaTrader 5 x64 build 6090 started
15:15:13  expert TestAutoStartEA (EURUSD,H1) loaded successfully   <- auto-attach
15:18:50  MetaTrader 5 x64 build 6090 started                      <- after rebuild
15:18:53  expert TestAutoStartEA (EURUSD,H1) loaded successfully   <- auto-attach again
```
And `MQL5/logs/20260806.log` shows continuous `TestAutoStartEA: OnTick ts=...`.

### Historical failed approaches (removed 2026-08-06)
Verified empirically on build 6090 under Wine:
- **Method 1 — `[StartUp]`/`[Experts]` injected into `Config/common.ini`:** FAILED
  (silently ignored).
- **Method 2 — `/config:` CLI flag:** FAILED (silently ignored, and logged
  `cannot load config "...autostart-cli.ini"` every boot).
- **Method 3 — `xdotool` GUI drag:** EXCLUDED (brittle, unnecessary now).
- **Method 4 — MQL5 Service:** chart-independent alternative; compiled
  (`TestAutoStartService.ex5`) but did not auto-start until run once. Kept as a standby
  fallback for chart-free logic (K8s headless).
- **Method 5 — manual attach → profile `.chr` persistence:** no `.chr` was updated on
  clean shutdown, so profile persistence was not relied upon.

`start.sh` no longer carries Methods 1/2 (removed during cleanup). The dead
`Config/autostart-cli.ini` no longer gets created, so the boot-time
`cannot load config` error is gone.

## 4. Rebuilding / recreating while keeping the MT5 session

```bash
# Rebuild the image and re-apply the overlay, keeping the prefix PVC
./scripts/kind-up.sh

# Or just recreate the pod (same image, same prefix, fresh MQL5 clone)
kubectl -n mt5 delete pod -l app.kubernetes.io/name=mt5
```

The prefix PVC keeps login/profile/MT5-install state; the MQL5 tree is re-cloned
from `MQL5_GIT_REF` on every pod start. To start clean, delete the prefix data on
the host (`~/mt5-data/prefix`); a fresh prefix re-initializes the Wine prefix from
the image but re-runs the MT5 login cycle.

## 5. Monitor script missing from the image

`dev/Dockerfile` copies `/Metatrader/monitor-mt5-logs.sh` from the build context
`dev/Metatrader/`. `dev/.dockerignore` excludes `*.md`, `config/`, `Tests/` and
`.env` — it must **not** exclude `Metatrader/`, or `start.sh` logs
`MT5 log monitoring script not found` and no `[EA:…]` lines reach stdout.

## 6. `kubectl logs` only shows the main service, not `kubectl exec` output

- Only output from the s6 longrun tree (e.g. `/Metatrader/start.sh` and its children)
  reaches `kubectl logs`. A monitor started via `kubectl exec` writes to the exec session,
  **not** to container logs.
- To apply the monitor to a running container's stdout: kill the exec'd monitor, then
  restart the `init-mt5` service so s6 relaunches `start.sh`:
  ```bash
  kubectl -n mt5 exec deploy/mt5 -- pkill -TERM -f /Metatrader/start.sh   # s6 auto-restarts it
  ```

## Useful paths & facts

| Item | Value |
|------|-------|
| Image | `localhost/mt5-dev:dev` (loaded into kind) |
| Pod | `kubectl -n mt5 get pods` (Deployment `mt5`, one replica) |
| Prefix PVC | `mt5-prefix` → host `~/mt5-data/prefix` |
| Wine prefix | `/opt/mt5` |
| Portable EA logs | `<prefix>/drive_c/Program Files/MetaTrader 5/MQL5/logs` (in the pod's `emptyDir`) |
| Terminal profile | `<prefix>/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/<uuid>` |
| startup.ini (kept) | `<Terminal>/<uuid>/startup.ini` |
| startup.ini (read at startup) | `<prefix>/drive_c/Program Files/MetaTrader 5/startup.ini` (written by `start.sh` before every launch, from `MT5_AUTO_START_*`; MT5 consumes it once) |
| MQL5 source | git clone at `MQL5_GIT_REF` (pinned tag `mql5-v1`) into the pod's `emptyDir` |