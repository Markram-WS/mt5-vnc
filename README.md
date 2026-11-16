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
├── deploy/       # kustomize base + kind-dev / kind-prod / homelab overlays
└── scripts/      # kind-up.sh, kind-down.sh, push-image.sh
```

| Mode | Base image | UI | API | Notes |
|---|---|---|---|---|
| `dev/` | `gmag11/metatrader5_vnc` (~8.8 GB) | KasmVNC on `:3000` | `:8001` | `HEADLESS=false`, `mt5linux==1.0.11` pin, `xdotool` login fallback |
| `prod/` | `tobix/wine:stable` (~0.8 GB base) | none — `Xvfb :99` | `:8001` | `HEADLESS=true`, no xdotool, lower resource requests/limits |

Both modes use the **same** `mql5/` tree; neither image bakes MQL5 in. The pod
fetches it itself: the `fetch-mql5` init container clones this repo at
`MQL5_GIT_REF` (ConfigMap `mt5-env`, pinned to the tag `mql5-v1`) into an
`emptyDir` mounted at `.../MetaTrader 5/MQL5`. The tree holds `mql5/Include`, the
authored `mql5/Experts/TestAutoStartEA.{mq5,ex5}` and `mql5/Profiles`, and both
modes auto-start the EA the same way:
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
  (ClusterIP, VNC 3000 + mt5linux 8001). No secret: it has to render from
  committed files alone.
* `deploy/components/prod-headless` — the shared prod deltas (`HEADLESS=true`,
  `tini` entrypoint, lean requests/limits), used by every prod overlay.
* `deploy/overlays/kind-dev` — image `localhost/mt5-dev:dev`, UI enabled,
  NodePorts `30300`/`30801`, `secretGenerator` from its own `secrets.env`.
* `deploy/overlays/kind-prod` — image `localhost/mt5-prod:prod`, headless, lean
  requests/limits, same NodePorts.
* `deploy/overlays/homelab` — the same prod workload on the real cluster: image
  `markram92/mt5-prod:1.0.0`, `ExternalSecret` from Vault, `local-path` PVC, only
  the API on NodePort `30801`. **Not applied yet** — see
  [deploy/README.md](deploy/README.md#homelab-prod-overlay) for the registry,
  Vault, apply and Flux steps.

### Homelab (prod)

The same prod workload is prepared for the homelab Talos cluster as
`deploy/overlays/homelab` (Docker Hub image `markram92/mt5-prod:1.0.0`,
Vault-backed `mt5-secrets` via `ExternalSecret`, `local-path` PVC, API on
NodePort `30801`) and is **not applied yet**. The registry push
(`podman login docker.io` then `./scripts/push-image.sh <tag>`), the five Vault
keys under `secret/mt5/prod`, the manual apply and the Flux registration are all
documented in
[deploy/README.md](deploy/README.md#homelab-prod-overlay).

### MQL5 delivery and release

Pods never read this checkout: `fetch-mql5` clones `MQL5_GIT_URL` at
`MQL5_GIT_REF` — the annotated tag `mql5-v1`, ~295 files — into a per-pod
`emptyDir`. Release: commit (including the recompiled `.ex5`; a `.mq5` edit
alone changes nothing) → `git tag -a mql5-vN` → `git push --tags` → point
`MQL5_GIT_REF` at the new tag in `deploy/base/configmap.yaml` →
`kubectl apply -k deploy/overlays/kind-prod` (or `kind-dev`) →
`kubectl -n mt5 rollout restart deploy/mt5`. Rolling back is the same steps
with the previous tag. Runtime MQL5 state (logs, `experts.dat`, rewritten
`Profiles`) lives only in that `emptyDir` and is lost when the pod restarts.

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

`kind-up.sh` creates `deploy/overlays/<mode>/secrets.env` from the selected
mode's `.env` on first run, builds the mode's image, loads it into kind and
waits for the pod to become Ready (a cold prefix installs Mono, Wine Python and
MT5, so the first rollout takes minutes).

Render a mode without a cluster:

```bash
cp deploy/base/secrets.env.example deploy/overlays/kind-dev/secrets.env   # once per overlay
kubectl kustomize deploy/overlays/kind-dev
kubectl kustomize deploy/overlays/kind-prod
kubectl kustomize deploy/overlays/homelab        # no local secrets needed
```

## Secrets

`dev/.env`, `prod/.env` and `deploy/overlays/*/secrets.env` hold the MT5
credentials and VNC user/password. They exist on disk only — all of them are
gitignored, and `deploy/base/secrets.env.example` documents the expected keys.
The kind overlays generate the Secret from their own `secrets.env`; the homelab
overlay instead syncs the same Secret name from Vault
(`secret/mt5/prod`) through an `ExternalSecret`.

## Documentation

* [dev/README.md](dev/README.md) — dev mode: VNC, mt5linux, storage, env vars.
* [prod/README.md](prod/README.md) — headless mode: quickstart, dynamic config.
* [prod/ARCHITECTURE.md](prod/ARCHITECTURE.md) — how dev and prod share one
  Wine prefix and differ.
* [deploy/README.md](deploy/README.md) — kustomize layout, prefix seeding,
  kind cluster, storage semantics, pins and deviations.
