# mt5-vnc

MetaTrader 5 running under Wine, in two container images — an interactive **dev**
one and a headless **prod** one — each with its own environment: **dev runs on
the local kind cluster**, **prod runs on the Talos cluster**. Both use the same
demo account (`26435893` on `VantageMarkets-Demo`).

<https://github.com/Markram-WS/mt5-vnc>

## Layout

```
.
├── mql5/         # the one MQL5 tree, fetched by both environments
├── dev/          # interactive image: KasmVNC UI + mt5linux API (local kind)
├── prod/         # headless image: mt5linux API only (Talos, Docker Hub)
├── deploy/       # kustomize base + kind-dev / talos-prod overlays
├── docs/         # secrets.md: the one page about credentials
├── scripts/      # kind-up.sh, kind-down.sh, push-image.sh, secrets.sh
└── .env.example  # template for the local secret source (copy to .env)
```

| | **dev** | **prod** |
|---|---|---|
| Runs on | local kind cluster (`mt5`) | Talos cluster |
| Overlay | `deploy/overlays/kind-dev` | `deploy/overlays/talos-prod` |
| Image | `localhost/mt5-dev:dev` (built from `dev/`) | `markram92/mt5-prod:1.0.0` (Docker Hub, built from `prod/`) |
| Base image | `gmag11/metatrader5_vnc` (~8.8 GB) | `tobix/wine:stable` (~0.8 GB base) |
| UI | KasmVNC on `:3000` | none — `Xvfb :99` |
| API | `:8001` | `:8001` (NodePort `30801`) |
| Login profile | host-mounted `$MT5_DATA_DIR/profile/dev/Config` | `fetch-profile` seeds it from MinIO once |
| MinIO / Vault | not needed | MinIO in-cluster + Vault `ExternalSecret` |

Both images use the **same** `mql5/` tree; neither image bakes MQL5 in. The pod
fetches it itself: the `fetch-mql5` init container clones this repo at
`MQL5_GIT_REF` (ConfigMap `mt5-env`, pinned to the tag `mql5-v1`) into an
`emptyDir` mounted at `.../MetaTrader 5/MQL5`. The tree holds `mql5/Include`, the
authored `mql5/Experts/TestAutoStartEA.{mq5,ex5}` and `mql5/Profiles`, and both
environments auto-start the EA the same way:
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

`deploy/` is one `Deployment/mt5` in namespace `mt5`, rendered by one overlay per
environment — `kind-dev` for the local dev cluster, `talos-prod` for prod:

* `deploy/base/` — namespace, ConfigMap `mt5-env`, Deployment, Service
  (ClusterIP, VNC 3000 + mt5linux 8001). No secret: it has to render from
  committed files alone.
* `deploy/components/prod-headless` — the prod deltas (`HEADLESS=true`,
  `tini` entrypoint, lean requests/limits), used by the Talos overlay.
* `deploy/components/fetch-profile` — the prod init container that seeds the
  MT5 login profile from MinIO (bucket `mt5`, prefix `prod-demo`) on the first
  start, then never touches it again.
* `deploy/overlays/kind-dev` — **dev**: image `localhost/mt5-dev:dev`, UI
  enabled, NodePorts `30300`/`30801`, Secrets applied out-of-band by
  `scripts/secrets.sh` from `/.env`, and the host dir
  `$MT5_DATA_DIR/profile/dev/Config` mounted read-write over the terminal's
  `Config`.
* `deploy/overlays/talos-prod` — **prod**: image `markram92/mt5-prod:1.0.0`,
  headless, `fetch-profile` enabled, `ExternalSecret` for the MinIO credentials,
  in-cluster MinIO endpoint, `local-path` PVC, only the API on NodePort `30801`.
  **Not applied yet** — see
  [deploy/README.md](deploy/README.md#talos-prod-overlay) for the registry,
  Vault, apply and Flux steps.
* `deploy/clusters/base` — the Flux entry point; it resolves to
  `deploy/overlays/talos-prod` (prod only).

### Login profile (no MT5 credentials)

MT5 logs in from its **login profile** (`Config/accounts.dat`, `common.ini`,
`servers.dat`, …), not from `MT5_SERVER`/`MT5_ACCOUNT`/`MT5_PASSWORD` — those are
empty everywhere. In **dev** the profile is the host directory
`$MT5_DATA_DIR/profile/dev/Config`, mounted read-write over the terminal's
`Config` dir, so you log in manually via VNC once and MT5 keeps using it; dev
needs no MinIO at all. In **prod** (Talos) the `fetch-profile` init container
copies `prod-demo/Config` from MinIO on the first start of an empty prefix, so
the pod auto-logs in with no credentials.

Both environments are the **same demo account**, so only one of them should be
logged in at a time: two terminals on one account fight over session state (and
the demo server's concurrent-session limit), so stop the dev pod before prod
logs in, and vice versa.

The host → MinIO copy is a **one-time operator step** (already done for account
`26435893` on `VantageMarkets-Demo`), not a sync: `rclone copy
~/mt5-data/profile/dev/ mt5:mt5/prod-demo/`. The complete copy-pasteable
procedure, the expected bucket layout, the in-cluster env-based rclone config
and the re-seed procedure for a password rotation are in
[deploy/README.md](deploy/README.md#copying-the-login-profile-to-minio-one-time-operator-step).

### Talos (prod)

Prod runs on the homelab Talos cluster as `deploy/overlays/talos-prod` (Docker Hub
image `markram92/mt5-prod:1.0.0`, `fetch-profile` against the in-cluster MinIO
Service, Vault-backed `mt5-minio` credentials via `ExternalSecret`,
`local-path` PVC, API on NodePort `30801`) and is **not applied yet**.

The image itself is already published: `markram92/mt5-prod:1.0.0`, 916 MB
compressed, digest
`sha256:bb489cd3c6cd4ec8f9925a2027fb5ac114c1625d0b3149e1edbb31295f56cb1a`,
pushed 2026-11-16. A rebuild is pushed with `./scripts/push-image.sh <tag>`
after `podman login docker.io`: the script reads the login store in podman's
order — `$REGISTRY_AUTH_FILE`, else
`$XDG_RUNTIME_DIR/containers/auth.json` (usually
`/run/user/<uid>/containers/auth.json`), else `~/.config/containers/auth.json` —
and the runtime-dir store is per-session, so it vanishes on logout/reboot and
the login has to be repeated (credentials are never printed).

Outstanding before the first apply: the two Vault properties under `secret/mt5`
(`MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`), then
`kubectl --context admin@homelab-cluster apply -k deploy/overlays/talos-prod` (or the
Flux registration). The one-time login-profile copy to MinIO (`mt5/prod-demo/`)
is already done, and because dev and prod use the **same demo account** the dev
pod must be stopped while prod runs. The manual apply and Flux steps are in
[deploy/README.md](deploy/README.md#talos-prod-overlay).

### MQL5 delivery and release

Pods never read this checkout: `fetch-mql5` clones `MQL5_GIT_URL` at
`MQL5_GIT_REF` — the annotated tag `mql5-v1`, ~295 files — into a per-pod
`emptyDir`. Release: commit (including the recompiled `.ex5`; a `.mq5` edit
alone changes nothing) → `git tag -a mql5-vN` → `git push --tags` → point
`MQL5_GIT_REF` at the new tag in `deploy/base/configmap.yaml` →
`kubectl apply -k deploy/overlays/kind-dev` (dev) or the Talos cluster's Flux
sync / `kubectl apply -k deploy/overlays/talos-prod` (prod) →
`kubectl -n mt5 rollout restart deploy/mt5`. Rolling back is the same steps
with the previous tag. Runtime MQL5 state (logs, `experts.dat`, rewritten
`Profiles`) lives only in that `emptyDir` and is lost when the pod restarts.

### Wine prefix and account separation

Dev and prod no longer share a Wine prefix: dev mounts the host directory
`$MT5_DATA_DIR` (node `hostPath /var/lib/mt5`) into the local kind cluster,
while prod owns a `local-path` PVC on the Talos node. Each prefix is
**single-writer** — `strategy: Recreate` on the single Deployment guarantees
the old pod is gone before a new one mounts it.

What the two environments *do* share is the **demo account** (`26435893` on
`VantageMarkets-Demo`), so do not keep both terminals logged in at once: the
broker limits concurrent sessions and two terminals would fight over the same
profile state. Run one at a time.

The prefix host directory must not live on exFAT: Wine maps built-in DLLs with
UNIX symlinks, and a prefix on exFAT fails with `STATUS_DLL_NOT_FOUND`
(`c0000135`). `MT5_DATA_DIR` defaults to `$HOME/mt5-data`.

## Quickstart

```bash
# Build + deploy dev onto the local kind cluster (there is no prod mode here).
./scripts/kind-up.sh                 # VNC UI -> http://localhost:3000

# Delete the cluster; the dev image and the Wine prefix are kept.
./scripts/kind-down.sh
```

`kind-up.sh` calls `scripts/secrets.sh apply` (which reads `.env` at the repo
root) before applying the overlay, builds `localhost/mt5-dev:dev`, loads it into
kind and waits for the pod to become Ready (a cold prefix installs Mono, Wine
Python and MT5, so the first rollout takes minutes). Prod is published
separately with `./scripts/push-image.sh <tag>` and applied on Talos.

Render an overlay without a cluster — no local secret file is needed, because
every overlay renders from committed files alone:

```bash
kubectl kustomize deploy/overlays/kind-dev
kubectl kustomize deploy/overlays/talos-prod
```

## Secrets

`/.env` (gitignored, template `.env.example`) is the only local secret source:
`scripts/secrets.sh apply` turns it into the two Secrets the dev overlay reads,
and prod gets the same Secret names from Vault through `ExternalSecret`. No
credential is ever in a manifest, so every overlay renders from committed files
alone. Everything else — key table, rotation, what is not a secret — is in
[docs/secrets.md](docs/secrets.md).

## Documentation

* [dev/README.md](dev/README.md) — dev image: VNC, mt5linux, storage, env vars.
* [prod/README.md](prod/README.md) — prod image: quickstart, dynamic config.
* [prod/ARCHITECTURE.md](prod/ARCHITECTURE.md) — how the dev and prod images
  differ and what they share.
* [docs/secrets.md](docs/secrets.md) — the one page about credentials: `.env`,
  the two Secrets, Vault, rotation.
* [deploy/README.md](deploy/README.md) — kustomize layout, prefix seeding,
  kind cluster, storage semantics, pins and deviations.
* [CONTEXT.md](CONTEXT.md) — glossary of the terms this repo deploys.
