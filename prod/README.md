# MT5 Production (Headless)

Production **headless** MetaTrader 5 container. Same EA auto-start mechanism as
`dev/`, but no GUI and much lighter (`~2.7GB` vs dev VNC `~8.8GB`), and no MQL5
baked into the image at all — both modes mount the repo's single `mql5/` tree.
Configuration is fully dynamic via `.env` — no rebuild needed for setting a
different EA / symbol / timeframe.

---

## 1. Overview / ภาพรวม

| | `../dev` | **prod (this)** |
|---|---|---|
| Image | `gmag11/metatrader5_vnc` (~8.8GB) | `tobix/wine:stable` (~2.7GB) |
| GUI | VNC port 3000 | none (headless, no `xdotool`) |
| mt5linux API | port 8001 | port 8001 (host 8002) |
| EA auto-start | `startup.ini` written by `start.sh` | same as dev |
| MQL5 source | shared `../mql5/` bind mount | same tree |
| Shared volume | `mt5-vantage` | same (external: `mt5-dev_mt5-vantage`) |

> Both dev and prod auto-start the EA the same way: `start.sh` writes `startup.ini`
> (`[StartUp] Expert / Symbol / Period`) before every MT5 launch, and MT5 reads it and
> attaches the EA itself — no dragging in a GUI. Both modes see the same `mql5/`
> tree, so the EA you test in dev is byte-for-byte the EA prod attaches. The
> difference is only the runtime: this image is **GUI-free**.
>
> `prod/` is a **GUI-free** image: `xdotool` and the VNC/desktop stack are **not
> installed**. Because the login state persists in the shared volume (seeded once from
> dev), MT5 authorizes on boot with no GUI automation. `start.sh` runs its xdotool
> auto-login block *only* if `xdotool` happens to be present; on prod it is always
> skipped. Verified 2026-08-07: `expert TestAutoStartEA (EURUSD,H1) loaded
> successfully` and `OnTick ...` resumed across container restarts.
>
> **Seed once from dev (per PV):** the attached-EA/profile/login state that lets
> headless prod resume on boot comes from the shared volume (same `mt5-dev_mt5-vantage`
> used by dev, same as the future k8s PV). Start the EA once in dev's GUI and close MT5
> cleanly so the "running program" state persists; prod then auto-resumes it. A fresh
> volume needs that one-time seed (kube: one PV = one instance).

---

## 2. Quickstart

```bash
# Stop dev first — the two must not run together on the shared volume.
DOCKER_HOST=unix:///run/user/1000/podman/podman.sock

cd /media/wasan/Storage/mt5-dev/prod

cp .env.example .env          # fill MT5_ACCOUNT / MT5_PASSWORD / MT5_SERVER (+ MT5_AUTO_START_*)
docker-compose up -d --build

# Container: mt5_prod   |   host API port: 8002
```

Configuration is **dynamic** — edit `.env` and `docker-compose restart`, no rebuild
needed (unless you change `Metatrader/start.sh`, which is baked into the image).

| Variable | Default | Meaning |
|----------|---------|---------|
| `MT5_ACCOUNT` | — | account number |
| `MT5_PASSWORD` | — | account password |
| `MT5_SERVER` | — | broker server name or `host:port` |
| `ENABLE_MT5LINUX_API` | `true` | enable mt5linux API |
| `MT5_AUTO_START_EA` | `TestAutoStartEA` | EA inside `MQL5/Experts` to auto-attach |
| `MT5_AUTO_START_SYMBOL` | `EURUSD` | chart symbol |
| `MT5_AUTO_START_PERIOD` | `H1` | timeframe (`M1`, `H1`, `D1`, …) |
| `LOG_RETENTION_DAYS` | `7` | delete MT5 log files older than N days (`0` = off) |
| `LOG_RETENTION_INTERVAL` | `86400` | seconds between cleanups (daily) |
| `COMPANY_ENV` / `COMPANY_REGION` | `production` / `us-east-1` | labels |

On Kubernetes the same variables go to a **ConfigMap** (`MT5_AUTO_START_*`,
`ENABLE_MT5LINUX_API`) and credentials to a **Secret**
(`MT5_ACCOUNT/PASSWORD/SERVER`). Set them via Helm/Kustomize. See §6.

---

## 3. MQL5 tree (shared, no copying)

There is **one** MQL5 tree in the repo — `../mql5/` at the repository root — and
prod mounts it at `/opt/mt5/drive_c/Program Files/MetaTrader 5/MQL5/`
(`docker-compose.yml`). Dev mounts the same directory; on Kubernetes the pod
clones the repo at `MQL5_GIT_REF` and serves `mql5/` from an `emptyDir`. Nothing
is copied between modes any more, and no image bakes MQL5 in.

So dropping a new EA into `../mql5/Experts/` and restarting the container is
the whole workflow on compose; on Kubernetes it is commit + push + rollout
restart, still with no image rebuild:

```bash
cp MyRobot.ex5 MyRobot.mq5 ../mql5/Experts/
DOCKER_HOST=unix:///run/user/1000/podman/podman.sock docker-compose restart
```

Path mapping (host `../mql5` → wine container):

| Host | Wine (container) |
|---|---|
| `mql5/Experts/` | `.../MQL5/Experts/` |
| `mql5/Include/` | `.../MQL5/Include/` |
| `mql5/Indicators/` | `.../MQL5/Indicators/` |
| `mql5/Scripts/` | `.../MQL5/Scripts/` |
| `mql5/Profiles/` | `.../MQL5/Profiles/` |

> The tree needs `git add -f` (it carries the stock MT5 `.gitignore`), and it
> holds `Profiles` deliberately: `startup.ini`'s `[StartUp] Expert` attaches to
> the saved default chart, so a tree without it boots MT5 but never loads the EA.

### Login / session state

Login + MT5 install + profile live in the shared volume `mt5-dev_mt5-vantage`.
Log in once (dev), then prod continues on the same volume. A PV backs one instance;
dev and prod must **not** run simultaneously on the same volume.

---

## 4. Configuring for another EA

One EA per container (per `startup.ini` limitation). To run several EAs, run several
container instances (fits the K8s one-PV-one-instance model).

```bash
# 1) drop the compiled .ex5 (with its .mq5 source) into ../mql5/Experts/
cp MyRobot.ex5 MyRobot.mq5 ../mql5/Experts/

# 2) set config in .env (dynamic — no rebuild; restart for the bind-mount)
MT5_AUTO_START_EA=MyRobot        # no ".ex5" suffix; subfolders ok e.g. "Sub/MyRobot"
MT5_AUTO_START_SYMBOL=GBPUSD
MT5_AUTO_START_PERIOD=H1

# 3) restart (bind-mount already has the new .ex5)
DOCKER_HOST=unix:///run/user/1000/podman/podman.sock docker-compose restart
```

> **New EA order matters:** put the `.ex5` on disk and restart **once** so
> `start.sh` writes `startup.ini` with the new EA — the EA must exist in
> `MQL5/Experts` **before** the container (re)starts, otherwise MT5 can't attach it.

Verify the EA attached — confirm via the container (both logs land on stdout):

```bash
# 1) expect terminal log:  "expert MyRobot (GBPUSD,H1) loaded successfully"
docker logs mt5_prod | tr -d '\0' | grep -a "loaded successfully"

# 2) expect EA log:  "MyRobot: OnTick ..."  (streamed by monitor-mt5-logs.sh)
docker logs -f mt5_prod | tr -d '\0' | grep -a "MyRobot:"
```

Or tail the raw files inside the container:

```bash
# terminal journal
docker exec mt5_prod bash -c 'tr -d "\000" < "/opt/mt5/drive_c/Program Files/MetaTrader 5/logs/$(date +%Y%m%d).log" | tail'
# EA OnTick log
docker exec mt5_prod bash -c 'tr -d "\000" < "/opt/mt5/drive_c/Program Files/MetaTrader 5/MQL5/logs/$(date +%Y%m%d).log" | tail'
```

> `docker logs -f mt5_prod` shows `[EA:filename] ... OnTick ...` lines streamed by
> `monitor-mt5-logs.sh` — i.e. **all logs are on stdout** and visible with
> `docker logs`, no need to exec or read files unless you want raw MQL5 lines.

> New `.ex5` → restart is enough (bind mount). Editing `prod/Metatrader/start.sh`
> itself requires a **rebuild** (it is copied into the image).

### Log retention

MT5 writes a log file per day (`YYYYMMDD.log` under `MQL5/Logs/` and the terminal
`logs/`) and never deletes them, so long-running instances accumulate files. prod
purges them automatically via `Metatrader/log-retention.sh`, configurable in `.env`
(`LOG_RETENTION_DAYS`, default `7`; `0` = disabled; cleaned daily).

```bash
# in .env  →  then restart (no rebuild; retention script is baked into the image)
LOG_RETENTION_DAYS=7
LOG_RETENTION_INTERVAL=86400   # check every 24h
```

Covers: `MQL5/Logs`, `MQL5/Experts/Logs`, `MQL5/Indicators/Logs`, `MQL5/Tester/`,
terminal root `Logs/`, and `metaeditor.log`. Container **stdout** (the
`docker logs` you watch) is a separate stream (`journald` by default) and is **not**
cleaned by this — see §7 for controlling that too.

---

## 5. Common commands

```bash
DOCKER_HOST=unix:///run/user/1000/podman/podman.sock

docker-compose up -d --build      # build + run
docker-compose logs -f mt5_prod   # all logs on stdout
docker-compose restart            # apply .env / bind-mount changes

# stop dev before running prod (shared volume):
DOCKER_HOST=... podman stop mt5_app
```

---

## 6. Bounding container stdout (docker logs)

The EA/system logs you tail via `docker logs -f mt5_prod` are written to the
container's log driver (default `journald` on this setup), **separate** from the
on-disk MT5 logs handled by log retention (§4). To bound it, use a size-capped
driver in `docker-compose.yml` (example below), then `docker-compose up -d`:

```yaml
services:
  mt5-prod:
    ...
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
```

This caps each stdout log file at 10MB, keeps 5 (`= 50MB max`), and drops
out-of-policy. With `journald` there is no per-container option here —
configure host `journald.conf` (`SystemMaxUse`) / rely on journald rotation.

---

## 7. Kubernetes / MinIO (planned, not implemented yet)

- Env (`MT5_AUTO_START_*`, `ENABLE_MT5LINUX_API`) → **ConfigMap**
- Credentials (`MT5_ACCOUNT/PASSWORD/SERVER`) → **Secret**
- `MT5_AUTO_START_*` set via **Helm / Kustomization**
- MQL5 / data served from **MinIO** (future) — today the pod clones the repo's
  `mql5/` tree at start, compose bind-mounts the same tree; no copying or
  syncing anywhere.