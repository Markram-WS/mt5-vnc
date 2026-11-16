# mt5-vnc

MetaTrader 5 running under Wine, in two mutually exclusive container modes, plus
the kustomize + kind deployment that runs them on a single-node local cluster.

<https://github.com/Markram-WS/mt5-vnc>

## Layout

```
.
├── mql5/         # the one MQL5 tree, mounted by BOTH modes
├── dev/          # interactive mode: KasmVNC UI + mt5linux API
├── prod/         # headless mode: mt5linux API only, minimal image
├── deploy/       # kustomize base + kind-dev / kind-prod overlays
└── scripts/      # kind-up.sh, kind-down.sh
```

| Mode | Base image | UI | API | Notes |
|---|---|---|---|---|
| `dev/` | `gmag11/metatrader5_vnc` (~8.8 GB) | KasmVNC on `:3000` | `:8001` | `HEADLESS=false`, `mt5linux==1.0.11` pin, `xdotool` login fallback |
| `prod/` | `tobix/wine:stable` (~0.8 GB base) | none — `Xvfb :99` | `:8001` | `HEADLESS=true`, no xdotool, lower resource requests/limits |

Both modes use the **same** `mql5/` tree; neither image bakes MQL5 in. On
Kubernetes the pod fetches it itself: the `fetch-mql5` init container clones
this repo at `MQL5_GIT_REF` (ConfigMap `mt5-env`, default `main`) into an
`emptyDir` mounted at `.../MetaTrader 5/MQL5`; compose instead bind-mounts
`../mql5` into the same path. The tree holds `mql5/Include`, the authored
`mql5/Experts/TestAutoStartEA.{mq5,ex5}` and `mql5/Profiles`, and both modes
auto-start the EA the same way:
`start.sh` writes `startup.ini` (`[StartUp] Expert / Symbol / Period`) before
every MT5 launch, and MT5 attaches the EA on boot. `MT5_AUTO_START_EA`,
`MT5_AUTO_START_SYMBOL` and `MT5_AUTO_START_PERIOD` select it at runtime, so no
rebuild is needed to point at a different EA, symbol or timeframe.

### MQL5 needs `git add -f`

`mql5/` carries the stock MT5 `.gitignore` (`*`, `*/`, `!.gitignore`), so any
MQL5 file has to be added with `git add -f`.
`MQL5/Profiles` is tracked deliberately: `startup.ini`'s `[StartUp] Expert`
attaches to the default chart profile, so without it MT5 boots but never loads
the expert.

## Deployment

`deploy/` is one `Deployment/mt5` in namespace `mt5` with two overlays that
differ only in image, `HEADLESS` and resources; both mount the same MQL5 tree:

* `deploy/base/` — namespace, ConfigMap `mt5-env`, Deployment, Service
  (ClusterIP, VNC 3000 + mt5linux 8001), `secretGenerator` from
  `deploy/base/secrets.env`.
* `deploy/overlays/kind-dev` — image `localhost/mt5-dev:dev`, UI enabled,
  NodePorts `30300`/`30801`.
* `deploy/overlays/kind-prod` — image `localhost/mt5-prod:prod`, headless, lean
  requests/limits, same NodePorts.

### The shared Wine-prefix rule

Both modes mount **one** Wine-prefix PVC (`mt5-prefix`, hostPath
`/var/lib/mt5/prefix` inside the node) at `/opt/mt5`. It carries the MT5
install, the login state and the EA profile across mode switches, and it is
**single-writer**: dev and prod must never run at the same time. The
`Recreate` strategy on the single Deployment enforces that structurally — the
old pod is fully gone before the new one mounts the PVC.

The prefix host directory must not live on exFAT: Wine maps built-in DLLs with
UNIX symlinks, and a prefix on exFAT fails with `STATUS_DLL_NOT_FOUND`
(`c0000135`). `MT5_DATA_DIR` defaults to `$HOME/mt5-data`.

## Quickstart

```bash
# Build + deploy one mode onto the local kind cluster (default: dev).
./scripts/kind-up.sh --mode dev      # VNC UI -> http://localhost:3000
./scripts/kind-up.sh --mode prod     # headless, API on localhost:8001

# Delete the cluster; images and the Wine prefix are kept.
./scripts/kind-down.sh
```

`kind-up.sh` creates `deploy/base/secrets.env` from the selected mode's `.env`
on first run, builds the mode's image, loads it into kind and waits for the pod
to become Ready (a cold prefix installs Mono, Wine Python and MT5, so the first
rollout takes minutes).

Render a mode without a cluster:

```bash
cp deploy/base/secrets.env.example deploy/base/secrets.env   # once
kubectl kustomize deploy/overlays/kind-dev
kubectl kustomize deploy/overlays/kind-prod
```

## Secrets

`dev/.env`, `prod/.env` and `deploy/base/secrets.env` hold the MT5 credentials
and VNC user/password. They exist on disk only — all three are gitignored.
`deploy/base/secrets.env.example` documents the expected keys.

## Documentation

* [dev/README.md](dev/README.md) — dev mode: VNC, mt5linux, volumes, env vars.
* [prod/README.md](prod/README.md) — headless mode: quickstart, dynamic config.
* [prod/ARCHITECTURE.md](prod/ARCHITECTURE.md) — how dev and prod share one
  Wine prefix and differ.
* [deploy/README.md](deploy/README.md) — kustomize layout, prefix seeding,
  kind cluster, storage semantics, pins and deviations.
