# MT5 Production (Headless)

Production **headless** MetaTrader 5 image. Same EA auto-start mechanism as
`dev/`, but no GUI and much lighter (`~2.7GB` vs dev VNC `~8.8GB`), and no MQL5
baked into the image at all — MQL5 is cloned from git into the pod at start.
Configuration is fully dynamic via the `mt5-env` ConfigMap — no rebuild needed
for a different EA / symbol / timeframe.

It runs on the local kind cluster: `./scripts/kind-up.sh --mode prod` builds
`localhost/mt5-prod:prod`, loads it into kind and applies
`deploy/overlays/kind-prod`.

---

## 1. Overview / ภาพรวม

| | `../dev` | **prod (this)** |
|---|---|---|
| Image | `localhost/mt5-dev:dev` (base ~8.8GB) | `localhost/mt5-prod:prod` (base ~2.7GB) |
| GUI | KasmVNC on host 3000 | none (headless, no `xdotool`) |
| mt5linux API | host 8001 | host 8001 |
| EA auto-start | `startup.ini` written by `start.sh` | same as dev |
| MQL5 source | git clone at `MQL5_GIT_REF` → pod `emptyDir` | same |
| Shared prefix | PVC `mt5-prefix` | same PVC |

> Both dev and prod auto-start the EA the same way: `start.sh` writes `startup.ini`
> (`[StartUp] Expert / Symbol / Period`) before every MT5 launch, and MT5 reads it and
> attaches the EA itself — no dragging in a GUI. Both modes get the same `mql5/`
> tree (same `MQL5_GIT_REF`), so the EA you test in dev is byte-for-byte the EA prod
> attaches. The difference is only the runtime: this image is **GUI-free**.
>
> `prod/` is a **GUI-free** image: `xdotool` and the VNC/desktop stack are **not
> installed**. Because the login state persists in the shared prefix PVC (seeded once
> from dev), MT5 authorizes on boot with no GUI automation. `start.sh` runs its
> xdotool auto-login block *only* if `xdotool` happens to be present; on prod it is
> always skipped. Verified 2026-11-16: `expert TestAutoStartEA (EURUSD,H1) loaded
> successfully` and `OnInit` in `MQL5/logs` on every pod (re)start.
>
> **Seed once from dev (per PVC):** the attached-EA/profile/login state that lets
> headless prod resume on boot comes from the shared prefix PVC. Start the EA once in
> dev's GUI and close MT5 cleanly so the "running program" state persists; prod then
> auto-resumes it. A fresh PVC needs that one-time seed.

---

## 2. Quickstart

```bash
# Stop dev first — the two must not run together on the shared prefix.
./scripts/kind-up.sh --mode prod

# Pod: mt5-… | host API port: 8001 | no UI (host 3000 refuses)
```

Configuration is **dynamic** — edit `deploy/base/configmap.yaml` (or the overlay
patch) and restart, no rebuild needed (unless you change `Metatrader/start.sh`,
which is baked into the image).

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

Non-secret values go in **ConfigMap `mt5-env`**; credentials go in **Secret
`mt5-secrets`** (generated from `prod/.env` by `kind-up.sh`). See §6.

---

## 3. MQL5 tree (git-delivered, never copied into the image)

There is **one** MQL5 tree in the repo — `mql5/` at the repository root — and
neither image bakes it in. The pod's `fetch-mql5` init container clones
`MQL5_GIT_URL` at `MQL5_GIT_REF` and copies `mql5/.` into an `emptyDir` mounted
at `/opt/mt5/drive_c/Program Files/MetaTrader 5/MQL5/`.

So dropping a new EA is commit + push (+ tag bump), then a rollout restart —
still no image rebuild:

```bash
git add -f mql5/Experts/MyRobot.ex5 mql5/Experts/MyRobot.mq5 && git commit -m "Add MyRobot"
git push origin main
# new tag for a reproducible release:
git tag -a mql5-v2 -m "MQL5 tree with MyRobot" && git push origin mql5-v2
# point MQL5_GIT_REF at the new tag, then:
kubectl apply -k deploy/overlays/kind-prod
kubectl -n mt5 rollout restart deploy/mt5
```

Path mapping (repo `mql5/` → wine container):

| Repo | Wine (container) |
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

Login + MT5 install + profile live in the shared prefix PVC `mt5-prefix`. Log in
once (dev), then prod continues on the same prefix. One PVC backs one instance;
dev and prod must **not** run simultaneously (enforced by `strategy: Recreate` on
the single Deployment).

---

## 4. Configuring for another EA

One EA per container (per `startup.ini` limitation). To run several EAs, run several
instances (one PVC per instance).

```bash
# 1) commit the compiled .ex5 (with its .mq5 source) under mql5/Experts/
cp MyRobot.ex5 MyRobot.mq5 mql5/Experts/
git add -f mql5/Experts/MyRobot.* && git commit -m "Add MyRobot" && git push

# 2) point the pod at that tree, and set the EA (dynamic — no rebuild)
#    deploy/base/configmap.yaml: MQL5_GIT_REF: "mql5-v2"
#                               MT5_AUTO_START_EA: "MyRobot"
#                               MT5_AUTO_START_SYMBOL: "GBPUSD"

# 3) apply + restart
kubectl apply -k deploy/overlays/kind-prod
kubectl -n mt5 rollout restart deploy/mt5
```

> **New EA order matters:** the `.ex5` must be in the tagged tree **before** the
> pod starts, otherwise MT5 can't attach it.

Verify the EA attached — both log locations are available:

```bash
# 1) host-side terminal journal: "expert MyRobot (GBPUSD,H1) loaded successfully"
grep -a "loaded successfully" ~/mt5-data/prefix/drive_c/Program\ Files/MetaTrader\ 5/logs/$(date +%Y%m%d).log | tail

# 2) EA log inside the pod: "MyRobot: OnInit ..."  (per-pod emptyDir)
kubectl -n mt5 exec deploy/mt5 -- sh -c 'tr -d "\000" < "/opt/mt5/drive_c/Program Files/MetaTrader 5/MQL5/logs/$(date +%Y%m%d).log" | tail'
```

> `kubectl -n mt5 logs -f deploy/mt5` shows `[EA:filename] ... OnTick ...` lines
> streamed by `monitor-mt5-logs.sh` — all logs are on stdout as well, no need to
> exec unless you want the raw MQL5 lines. The EA's own `Print()` output is
> buffered by MT5 and can land a minute or two after the pod is Ready.

> A new `.ex5` plus a tagged tree + rollout restart is enough. Editing
> `prod/Metatrader/start.sh` itself requires an **image rebuild** (it is copied
> into the image).

### Log retention

MT5 writes a log file per day (`YYYYMMDD.log` under `MQL5/Logs/` and the terminal
`logs/`) and never deletes them, so long-running instances accumulate files. prod
purges them automatically via `Metatrader/log-retention.sh`, configurable in the
ConfigMap (`LOG_RETENTION_DAYS`, default `7`; `0` = disabled; cleaned daily).

```bash
# ConfigMap mt5-env  →  then restart (no rebuild; the script is baked into the image)
LOG_RETENTION_DAYS: "7"
LOG_RETENTION_INTERVAL: "86400"   # check every 24h
```

Covers: `MQL5/Logs`, `MQL5/Experts/Logs`, `MQL5/Indicators/Logs`, `MQL5/Tester/`,
terminal root `Logs/`, and `metaeditor.log`. Container **stdout** (the
`kubectl logs` stream) is a separate stream and is **not** cleaned by this —
see §7.

---

## 5. Common commands

```bash
./scripts/kind-up.sh --mode prod              # build + load + apply + wait
kubectl -n mt5 get pods                       # Ready 1/1
kubectl -n mt5 logs -f deploy/mt5             # all logs on stdout
kubectl -n mt5 logs deploy/mt5 -c fetch-mql5  # which MQL5 tree was cloned
kubectl -n mt5 rollout restart deploy/mt5     # apply ConfigMap/tag changes

# stop dev before running prod (shared prefix):
./scripts/kind-up.sh --mode prod              # recreates the single pod
```

---

## 6. Configuration in the cluster

- Env (`MT5_AUTO_START_*`, `ENABLE_MT5LINUX_API`, `MQL5_GIT_*`) → **ConfigMap `mt5-env`**
  (`deploy/base/configmap.yaml`)
- Credentials (`MT5_ACCOUNT/PASSWORD/SERVER`, VNC user/password) → **Secret
  `mt5-secrets`**, generated by `kind-up.sh` from `prod/.env`
- Mode differences (image, `HEADLESS`, entrypoint, resources) → the overlay in
  `deploy/overlays/kind-prod`
- MQL5 / data → cloned from git at start; runtime writes stay in the pod's
  `emptyDir` and disappear with it

---

## 7. Bounding container stdout (kubectl logs)

The EA/system logs you tail via `kubectl logs` are written to the container
runtime's log file on the node, **separate** from the on-disk MT5 logs handled by
log retention (§4). It is bounded by kubelet's log rotation, not by this image:

```bash
# node container-runtime log of the running pod
kubectl -n mt5 logs deploy/mt5 --tail=200
```

For a longer-lived deployment, set `--kubelet-arg=container-log-max-size` /
`container-log-max-files` when creating the kind cluster
(`deploy/kind-cluster.yaml.tmpl`).

---

## 8. Status

The Kubernetes path is the only supported way to run this image; there is no
compose or standalone-`podman run` path any more. `deploy/README.md` documents
the manifests, the shared prefix and the kind cluster.
