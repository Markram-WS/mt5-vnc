# Deployment (kustomize + kind/podman)

Two environments, one per cluster — **dev on the local kind cluster**, **prod on
the Talos cluster**:

| | **dev** | **prod** |
|---|---|---|
| Cluster | local kind `mt5` | homelab Talos (single node) |
| Overlay | `overlays/kind-dev` | `overlays/talos-prod` |
| Image | `localhost/mt5-dev:dev` (built from `dev/Dockerfile`, loaded into kind) | `markram92/mt5-prod:1.0.0` (Docker Hub, built from `prod/Dockerfile`) |
| Base image | `gmag11/metatrader5_vnc` (~8.8 GB) | `tobix/wine:stable` (~0.8 GB) |
| UI | KasmVNC on <http://localhost:3000> | none — `Xvfb :99`, headless |
| `HEADLESS` | `false` | `true` |
| API | `localhost:8001` (mt5linux) | `<node-ip>:30801` (mt5linux) |
| Resources | requests 250m / 512Mi, limit 2Gi | requests 100m / 256Mi, limits 1 CPU / 1Gi |
| MQL5 source | `git clone` of this repo at `MQL5_GIT_REF` → pod `emptyDir` | same |
| MT5 login | host dir `$MT5_DATA_DIR/profile/dev/Config` mounted rw over `…/MetaTrader 5/Config` | `fetch-profile` seeds `Config` from MinIO (bucket `mt5`, prefix `prod-demo`) on first start |
| MT5 credentials in env | none (`MT5_*` empty) | none (`MT5_*` empty) |
| MinIO credentials | not needed | `ExternalSecret mt5-minio` from Vault `secret/mt5` |
| Storage | PV/PVC on node `hostPath /var/lib/mt5/prefix` | PVC on `StorageClass local-path` |

Both environments are the **same `Deployment/mt5`** in namespace `mt5` and mount
the same MQL5 tree; they differ in image, `HEADLESS`, resources, storage and
where the login profile comes from. There is exactly one apply target per
cluster, so there is no switch between them on a single cluster.

## Layout

```
deploy/
├── base/                      # environment-agnostic resources
│   ├── namespace.yaml         # Namespace mt5
│   ├── configmap.yaml         # mt5-env: non-secret env
│   ├── deployment.yaml        # Deployment mt5: Recreate, prefix PVC, shm, probes
│   ├── service.yaml           # Service mt5: ClusterIP, vnc 3000 + mt5linux 8001
│   └── kustomization.yaml     # namespace mt5 + resources (no Secret here)
├── components/
│   ├── kind-nodeports/
│   │   └── kustomization.yaml # Service NodePort 30300/30801 (dev only)
│   ├── prod-headless/
│   │   └── kustomization.yaml # HEADLESS=true + tini entrypoint + lean resources
│   └── fetch-profile/
│       └── kustomization.yaml # initContainer: seed login Config from MinIO (prod)
├── apps/
│   └── postgrest/             # PostgREST test stack, namespace mt5-data
│       ├── namespace.yaml     # Namespace mt5-data (separate from mt5)
│       ├── configmap.yaml     # postgres-conn: host/port/db + PostgREST URL
│       ├── postgres.yaml      # ephemeral postgres:16-alpine + init.sql (emptyDir)
│       ├── postgrest.yaml     # postgrest v12.2.3 + Service postgrest:3000
│       └── talos-prod/        # ExternalSecret postgrest-db (Vault secret/mt5)
├── overlays/
│   ├── kind-dev/              # DEV: the local kind cluster
│   │   ├── kustomization.yaml # image :dev + kind-nodeports (no secretGenerator)
│   │   ├── profile-volume.yaml # hostPath $MT5_DATA_DIR/profile/dev/Config -> Config (rw)
│   │   └── storage.yaml       # PV mt5-prefix-pv + PVC mt5-prefix
│   └── talos-prod/            # PROD: the Talos cluster — NOT applied yet
│       ├── kustomization.yaml # image markram92/mt5-prod:1.0.0, NodePort 30801 only
│       ├── storage.yaml       # PVC mt5-prefix on StorageClass local-path
│       └── externalsecret.yaml # mt5-minio from Vault secret/mt5
├── clusters/
│   └── base/
│       └── kustomization.yaml # Flux entry point -> ../../overlays/talos-prod
├── kind-cluster.yaml.tmpl     # kind Cluster (placeholders @REPO_ROOT@ / @DATA_DIR@)
├── registries.conf            # short-name aliases (host has no /etc/containers/registries.conf)
└── README.md
scripts/
├── kind-up.sh                 # dev only: build, load, secrets apply, apply, wait
├── kind-down.sh
├── push-image.sh              # build prod/ and push markram92/mt5-prod:<tag>
└── secrets.sh                 # .env -> Secrets mt5-secrets + postgrest-db (dev)
docs/
└── secrets.md                 # the one page about credentials
```

The repo root also holds `.env.example` (template for the gitignored `.env`, the
single local secret source — see [../docs/secrets.md](../docs/secrets.md)) and
`CONTEXT.md` (glossary).

## Usage

```bash
./scripts/kind-up.sh                # builds dev/, loads it, applies overlays/kind-dev
# ... use the VNC UI on http://localhost:3000
./scripts/kind-down.sh              # deletes the cluster, keeps image + prefix data
```

`kind-up.sh` takes no options: the kind cluster is dev-only, so there is nothing
to select. It re-executes itself under
`systemd-run --user --scope --property=Delegate=yes` (rootless podman needs a
delegated cgroup scope), exports `KIND_EXPERIMENTAL_PROVIDER=podman`, creates
the cluster if it is missing, builds `localhost/mt5-dev:dev` from `dev/`,
imports it with `podman save` + `kind load image-archive` (kind 0.33 relies on
`RepoTags` that podman 6 no longer reports, so `kind load docker-image` cannot
work), creates the cluster Secrets with `scripts/secrets.sh apply`, applies
`deploy/overlays/kind-dev`, then waits for the PVC to bind and the pod to become
Ready.

The Secrets step is separate on purpose and must come first: the overlay
contains no `secretGenerator`, so `kubectl apply -k` never reads a local file.
Applying by hand is the same two commands:

```bash
./scripts/secrets.sh apply             # reads .env, needs a kind-* context
kubectl apply -k deploy/overlays/kind-dev
```

Prod is not deployed from this script at all: build and push the image with
`./scripts/push-image.sh <tag>`, then apply `deploy/overlays/talos-prod` to the Talos
cluster (or let Flux do it via `deploy/clusters/base`).

## Login profile lifecycle (no MT5 credentials)

MT5 logs in from its **login profile**, not from environment variables: the
`Config` directory (`accounts.dat`, `common.ini`, `servers.dat`, `hotkeys.ini`,
`assistant.ini`, `certificates/`) that MT5 rewrites when you log in once.
`MT5_SERVER`, `MT5_ACCOUNT` and `MT5_PASSWORD` no longer exist anywhere — not
in the ConfigMap, not in the Secret, not in `.env` — so no `/login:… /password:…`
ever appears on the terminal command line or in the pod's process list. Secret
`mt5-secrets` carries only the VNC pair.

| environment | where `Config` comes from |
|---|---|
| **dev** (kind) | host dir `$MT5_DATA_DIR/profile/dev/Config` (= `/var/lib/mt5/profile/dev/Config` in the node), mounted **read-write** over `/opt/mt5/drive_c/Program Files/MetaTrader 5/Config`. `kind-up.sh` creates it and, only while it is empty, seeds it from the shared prefix's `Config` file set. |
| **prod** (Talos) | the `fetch-profile` init container copies `Config` from MinIO (bucket `mt5`, prefix `prod-demo`) on the first start of a prefix that has no `accounts.dat`. |

The flow is one-way and one-time: log in manually in dev once → the profile is
on the host → copy it to MinIO once → every prod pod seeds from it and logs in
by itself. Nothing in this repo uploads to MinIO, and there is no scheduled or
periodic sync. Both environments use the **same demo account**, so run only one
of them logged in at a time.

### Copying the login profile to MinIO (one-time operator step)

This is a **one-time bootstrap**, not a sync job: run it once per environment /
profile version. It has already been done for the current account (bucket
`mt5`, prefix `prod-demo`), so prod pods only seed from MinIO.

Prerequisites:

* `rclone` on the operator machine (the same client the init container uses).
* `.env` at the repo root with the two MinIO keys filled in (`MINIO_ACCESS_KEY`,
  `MINIO_SECRET_KEY` — the same pair Vault `secret/mt5` holds for prod). It is
  gitignored: **never commit it**, and keep bucket `mt5` private —
  `accounts.dat` is enough to open the terminal on that account.
* A reachable MinIO endpoint. From this host and from kind pods:
  `http://minio.tailb297d3.ts.net:9000` (tailnet). A local port-forward works
  too, so pass the endpoint explicitly.

1. Create the rclone remote once, without writing secrets into the repo:

   ```bash
   rclone config create mt5 s3 \
     provider Minio \
     endpoint "http://minio.tailb297d3.ts.net:9000" \
     access_key_id "$(grep -E '^MINIO_ACCESS_KEY=' .env | cut -d= -f2-)" \
     secret_access_key "$(grep -E '^MINIO_SECRET_KEY=' .env | cut -d= -f2-)"
   ```

2. Copy the dev profile (whole directory: `Config/` and `Terminal/`):

   ```bash
   rclone copy ~/mt5-data/profile/dev/ mt5:mt5/prod-demo/ -v
   ```

   Expected tree afterwards:

   ```
   prod-demo/
   ├── Config/accounts.dat
   ├── Config/assistant.ini
   ├── Config/certificates/
   ├── Config/common.ini
   ├── Config/hotkeys.ini
   ├── Config/servers.dat
   └── Terminal/{origin.txt,portable.txt,startup.ini}
   ```

   Verify with `rclone lsf mt5:mt5/prod-demo/ -R`.

3. Done. The next prod pod start seeds `prod-demo/Config` into the PVC; the
   operator is not needed again.

The in-cluster equivalent of step 1 is entirely env-based (`fetch-profile`):
ConfigMap `mt5-env` supplies `MINIO_URL` / `MINIO_BUCKET` /
`MINIO_PROFILE_PREFIX`, Secret `mt5-minio` supplies `MINIO_ACCESS_KEY` /
`MINIO_SECRET_KEY`, and the init container maps them to
`RCLONE_CONFIG_SRC_*` before `rclone copy --ignore-existing
src:$MINIO_BUCKET/$MINIO_PROFILE_PREFIX/Config …`. No rclone config file and no
credential value is ever written to the PVC or the image.

### Rotation (the only exception)

A password or account change invalidates the stored profile. That is the one
case where the one-time copy is repeated:

1. log in again in dev via VNC — MT5 rewrites the mounted host `Config` dir;
2. re-run the `rclone copy` above;
3. force prod to re-seed: delete `Config/accounts.dat` from the PVC and restart,

   ```bash
   kubectl -n mt5 exec deploy/mt5 -- rm -f "/opt/mt5/drive_c/Program Files/MetaTrader 5/Config/accounts.dat"
   kubectl -n mt5 rollout restart deploy/mt5
   ```

   `fetch-profile` is seed-once (`accounts.dat` present → exit 0), so without
   that deletion it keeps the old profile.

Current identifiers: account **26435893**, server **VantageMarkets-Demo**
(balance 50,000 USD, demo). Local dev needs no MinIO at all — the profile lives
at `$MT5_DATA_DIR/profile/dev/Config` and is host-mounted.

### First-boot prefix seeding (why there is an initContainer)

Both images pre-initialize a Wine prefix at `/opt/mt5` during build, and the
`mt5-prefix` PVC mounts at that same path — so on an empty prefix the mount
hides the baked one. Docker's named volume used to paper over this by copying
image content into the fresh volume on first mount; a Kubernetes hostPath PV is
just an empty directory. Without seeding, `start.sh` finds no `system.reg`, runs
`wineboot`, and wineboot pops the **interactive** "install Wine Mono" dialog
(`control.exe appwiz.cpl install_mono`) and blocks forever — harmless only
because dev has a VNC UI, and fatal in headless prod.

`Deployment/mt5` therefore has one init container, `seed-prefix`, which mounts
the PVC at `/prefix` (leaving `/opt/mt5` showing the image content) and:

```sh
[ -f /prefix/system.reg ] && exit 0    # never touch an initialized prefix
cp -a /opt/mt5/. /prefix/              # one-time seed from the image
```

`cp -a` keeps symlinks and modes (Wine maps built-ins through symlinks), and the
target path is still `/opt/mt5`, so the paths recorded in the prefix registry
stay valid. After this, `start.sh` skips `wineboot`, installs Wine Mono
silently, and proceeds to install MT5.

The Talos prod overlay adds a third init container, `fetch-profile`, which **runs
last** by construction (the component appends it with a JSON patch — a strategic
merge patch would put it first, and then `seed-prefix` would overwrite the
seeded `Config/common.ini`/`servers.dat` with the image defaults). It only acts
when `Config/accounts.dat` is absent, so an initialized prefix is never touched.
The dev overlay has no `fetch-profile` at all: it mounts the host `Config`
directory instead.

### Prefix updates after a Wine change (`prepare-prefix`)

A prefix outlives the image that created it: `$MT5_DATA_DIR/prefix` on the dev
host and the `local-path` PVC on Talos both persist across image rebuilds. If a
new image ships a different Wine build than the one that initialized the prefix
(dev: winehq-devel 11.10 installed over `gmag11/metatrader5_vnc`; prod: wine 11.0
from `tobix/wine:stable`), the first Wine command in `start.sh`
(`wine reg add ...Wine Updater...`) triggers `wineboot --init`, which pops the
**interactive** "install Wine Mono" dialog (`control.exe appwiz.cpl install_mono`)
and hangs the container.

The second init container, `prepare-prefix`, mounts the PVC at `/opt/mt5` and
completes that pending update non-interactively before `start.sh` runs:

```sh
export WINEDLLOVERRIDES="mscoree=d;mshtml=d"   # wineboot never prompts for Mono
xvfb-run -a wineboot -u                        # finish the prefix update silently
```

`mscoree=d` only suppresses the .NET/Mono bootstrap prompt; MT5 itself does not
depend on Mono for its core, and the Mono that the dev image already installed
stays in the prefix. On an up-to-date prefix `wineboot -u` is a no-op, so the
normal cost is a few seconds per pod start.

Two filesystem details are load-bearing on this host:

* The repo (`/mnt/storage/mt5-dev`) is **exFAT**. buildah mounts an overlay over
  the build context, so the script stages the context under `$TMPDIR` first.
* `$TMPDIR` (`/tmp`) is a 7.5 GB tmpfs and `podman save` writes *uncompressed*
  layers (the dev image is ~8.8 GB), so image archives are staged in
  `$HOME/.cache/mt5-kind-image-tars` (`KIND_IMAGE_TMPDIR` overrides) and deleted
  after import.

This host also has no `/etc/containers/registries.conf` (podman on Arch ships it
in `containers-common`, which is not installed), so **unqualified image names do
not resolve at all**:

```
Error: short-name "gmag11/metatrader5_vnc:latest" did not resolve to an alias
       and no containers-registries.conf(5) was found
```

That breaks both `FROM` lines and kind's own `kindest/node` pull. Both scripts
therefore export `CONTAINERS_REGISTRIES_CONF=$REPO_ROOT/deploy/registries.conf`,
which maps every short name used here to exactly one `docker.io` reference
(`gmag11/metatrader5_vnc`, `tobix/wine`, `kindest/node`, `alpine`, `busybox`)
with `short-name-mode = "enforcing"`. If you ever install `containers-common`,
the file is harmless — but keep it, because the explicit aliases are what make
the resolution deterministic instead of search-order dependent.

## Cluster and networking

`deploy/kind-cluster.yaml.tmpl` is rendered by the script (it substitutes
`@REPO_ROOT@` and `@DATA_DIR@`) and passed to `kind create cluster --config`:

* cluster name `mt5`, one control-plane node;
* `30300 -> 3000` (VNC) and `30801 -> 8001` (API) host port mappings for the dev
  workload (dev is the only workload this cluster runs);
* extraMounts: `@DATA_DIR@` → `/var/lib/mt5` only. The MQL5 tree is not a host
  mount any more — the pod clones it itself (see below), so the node never needs
  to see the repo checkout.

`$MT5_DATA_DIR` defaults to `$HOME/mt5-data` and **must be on a non-exFAT
filesystem**: Wine maps built-in DLLs with UNIX symlinks, so a prefix on exFAT
fails with `STATUS_DLL_NOT_FOUND` (`c0000135`). The script creates
`$MT5_DATA_DIR/prefix` before creating the cluster, because kind refuses
extraMounts whose host path does not exist.

## Storage semantics

Dev and prod have their own storage; nothing is shared between the clusters.

* **dev (kind)** — one PV `mt5-prefix-pv` (hostPath `/var/lib/mt5/prefix` inside
  the node, which is the extraMount of `$MT5_DATA_DIR`), `Retain`,
  `storageClassName: ""`, 20Gi, statically bound to `PVC mt5-prefix` via
  `volumeName`. No StorageClass: kind ships no default provisioner and binding
  must be deterministic.
* **prod (Talos)** — `PVC mt5-prefix` requests 10Gi from `StorageClass
  local-path`; the provisioner creates the node-local volume on first bind (see
  "Talos (prod) overlay").
* `Retain` means deleting the dev PVC never deletes the prefix; `kind-down.sh`
  likewise keeps `$MT5_DATA_DIR`.
* **Each prefix is single-writer.** `strategy: Recreate` plus one Deployment
  enforces that structurally (the old pod is fully gone before the new one
  mounts the PVC). Across environments the real conflict is the **shared demo
  account**, not the storage: dev and prod mount different prefixes, but they
  log in as the same user, so only one should be running at a time.
* MQL5 is **fetched from git, not mounted and not baked**: the `fetch-mql5`
  init container clones `MQL5_GIT_URL` at `MQL5_GIT_REF` (ConfigMap `mt5-env`,
  pinned to the tag `mql5-v1`) and copies `mql5/.` into the pod's writable
  `emptyDir`, which the app container mounts at
  `/opt/mt5/drive_c/Program Files/MetaTrader 5/MQL5`. A tag means every pod
  start clones exactly one tree; a branch ref would take the latest push.
* Consequence: **changing MQL5 (EA source, `.ex5`, includes, profiles) needs no
  image build** — commit + push, then restart the workload:

  ```bash
  kubectl -n mt5 rollout restart deploy/mt5 && kubectl -n mt5 rollout status deploy/mt5
  ```

  MT5 runs the committed `.ex5`, so a `.mq5` edit only takes effect once the
  recompiled `.ex5` is committed too (MetaEditor inside the dev container
  compiles it into the same tree).
* The clone lives in an `emptyDir`, so MT5's runtime writes (Profiles rewrite,
  `experts.dat`, `MQL5/logs`) are per-pod: nothing lands in the git checkout and
  `git status` stays clean, but EA logs disappear with the pod — read them from
  `kubectl logs` (`monitor-mt5-logs.sh` streams every EA line to stdout) or from
  the pod directly. The prefix journal stays host-side under
  `$MT5_DATA_DIR/prefix/.../logs/`.
* `startup.ini` is **not** mounted: `start.sh` rewrites it from the
  `MT5_AUTO_START_*` env on every launch.
* `/dev/shm` is a 256Mi memory-backed emptyDir.
* **dev** mounts one extra host directory over the terminal's config:
  `/var/lib/mt5/profile/dev/Config` (host `$MT5_DATA_DIR/profile/dev/Config`,
  created by `kind-up.sh`) at
  `/opt/mt5/drive_c/Program Files/MetaTrader 5/Config`, read-write. It is inside
  the existing `@DATA_DIR@` extraMount, so adding it needs no cluster recreate.
  The mount sits *above* the prefix PVC for that one path: MT5's login state
  lives on the host, outside the Wine prefix, and prod gets the same file set
  from MinIO instead.
* **prod** has no such mount; `fetch-profile` copies `Config` from MinIO into the
  prefix PVC on the first start (seed-once).
* `hostAliases` maps `update.mql5.com` / `updates.mql5.com` to 127.0.0.1; k8s
  regenerates `/etc/hosts`, so this is the only way to keep MT5 LiveUpdate
  blocked.

`mql5/` carries the stock MT5 `.gitignore` (`*`, `*/`, `!.gitignore`), so
almost every MQL5 file is ignored. Programs that should be tracked are enabled
by explicit negations there (`!Experts/` plus one `!Experts/<Name>.mq5` /
`.ex5` per EA — currently `PostgrestTestEA`), so they commit through the normal
staged-worktree flow; force-add (`git add -f <file>`) is still the tool for a
one-off file outside that tracked set. `mql5/Profiles` is tracked deliberately:
`startup.ini`'s `[StartUp] Expert` attaches to the default chart profile, so
without it MT5 boots but never loads the expert. MT5 rewrites
`mql5/Profiles/Agents/metatrader-default.md` at runtime, so that file shows up
as modified after a session (`git checkout -- mql5/Profiles` restores it).

## MQL5 delivery and release

Pods clone `MQL5_GIT_REF` from `MQL5_GIT_URL` at start into a per-pod
`emptyDir` (~295 files); the repo checkout is never read by the cluster.
Release a tree with: commit (including the compiled
`.ex5` — a `.mq5` edit alone never changes behavior) → `git tag -a mql5-vN` →
`git push --tags` → update `MQL5_GIT_REF` in `deploy/base/configmap.yaml` →
`kubectl apply -k deploy/overlays/kind-dev` (dev) or `kubectl apply -k
deploy/overlays/talos-prod` (prod, or Flux via `deploy/clusters/base`) →
`kubectl -n mt5 rollout restart deploy/mt5`. A rollback repeats those steps with
the previous tag. Runtime MQL5 state (logs, `experts.dat`, rewritten `Profiles`)
exists only in the `emptyDir` and is lost on restart.

## PostgREST test service

A throwaway CRUD target that proves the terminal can drive a real HTTP API from
inside the cluster. `mql5/Experts/PostgrestTestEA.mq5` POSTs a row, PATCHes it,
GETs it back, DELETEs it, GETs again, and logs a single
`POSTGREST-TEST PASS`/`POSTGREST-TEST FAIL` line.

It lives in namespace **`mt5-data`**, deliberately separate from `mt5`: the
database is disposable, and nothing here may be confused with — or pruned
together with — the MT5 workload.

### What runs

| Object | Notes |
|---|---|
| `Namespace mt5-data` | the disposal unit: `kubectl delete namespace mt5-data` removes everything |
| `ConfigMap postgres-init` | `init.sql` creates `public.events` (`id` bigserial, `created_at`, `updated_at`, `source`, `action`, `payload jsonb`) and trigger `events_set_updated_at` |
| `Deployment postgres` | `postgres:16-alpine`, digest-pinned; **no PVC** — `PGDATA` is on an `emptyDir`, so every pod restart starts empty and re-runs `init.sql` |
| `Deployment postgrest` | `postgrest:v12.2.3`, digest-pinned; anon role = the Secret's `POSTGRES_USER`, schema `public`, **no JWT** and no row-level security |
| `Service postgrest` | port 3000, ClusterIP only |

Both workloads run tiny requests/limits (postgres 100m/128Mi → 500m/256Mi,
postgrest 25m/32Mi → 200m/128Mi) and both images are pinned by digest, so kind
and Talos run the same bytes. The manifests live in `deploy/apps/postgrest/`
and both overlays include that directory unchanged, so the Deployments cannot
drift between environments.

### Reachability

`http://postgrest.mt5-data.svc.cluster.local:3000` — in-cluster only. There is
no NodePort, no Ingress and no TLS: the EA runs in a pod in the same cluster, so
a Service name is all it needs. (Dev publishes the MT5 VNC/API ports through
`components/kind-nodeports`; the PostgREST Service is deliberately not part of
that component.)

### Secret `postgrest-db` and ConfigMap `postgres-conn`

The **contract** the two environments share: Secret `postgrest-db` carries only
**who** connects — `POSTGRES_USER` and `POSTGRES_PASSWORD` — and ConfigMap
`postgres-conn` carries only **where** the database is:

| Object | Namespace | Keys |
|---|---|---|
| Secret `postgrest-db` | `mt5-data` | `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| ConfigMap `postgres-conn` | `mt5-data` | `POSTGRES_HOST=postgres`, `POSTGRES_PORT=5432`, `POSTGRES_DB=mt5`, `POSTGREST_URL` |

A location is not a credential: it is the same in every environment, safe to
read in `kubectl describe`, and must never need a rotation. `postgrest.yaml`
declares the three coordinates *before* the URI (Kubernetes only expands
`$(VAR)` to variables declared earlier):

```
PGRST_DB_URI=postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)
```

Both Secret keys are consumed everywhere: the postgres entrypoint creates that
role (and runs `init.sql` as it, so it owns the schema/table/sequence), while
PostgREST connects as it and expands it into `PGRST_DB_ANON_ROLE`. The user must
therefore be the **same value everywhere** — Vault, `.env`, and whatever the pods
already hold.

* **kind-dev** — `scripts/secrets.sh apply` creates the Secret from the
  repo-root `.env` (`POSTGRES_USER` and `POSTGRES_PASSWORD`, idempotent, values
  never printed), before the overlay is applied. The overlay itself contains no
  `secretGenerator`.
* **talos-prod** — `ExternalSecret postgrest-db`
  (`deploy/apps/postgrest/talos-prod/externalsecret.yaml`) pulls properties
  `POSTGRES_USER` and `POSTGRES_PASSWORD` from Vault `secret/mt5`. Both must
  exist **before** applying the overlay; otherwise the ExternalSecret reports
  `SecretSyncedError` and both pods sit in `CreateContainerConfigError`.

The password is hex on purpose: it is embedded verbatim in `PGRST_DB_URI`
(`postgres://<user>:<pw>@<host>:<port>/<db>`), so `/`, `:` or `@` would have to
be percent-encoded inside the URI. Generate it with `openssl rand -hex 32`.

### Operator prerequisite: the WebRequest whitelist

MT5 only lets an EA reach a URL listed under **Tools > Options > Expert Advisors
> Allow WebRequest for listed URL**. The terminal stores that list
**encrypted** in `Config/common.ini` (`[Experts]` / `WebRequestUrl=<hex>`): an
opaque hex blob, written only by the terminal. It therefore cannot be committed
or hand-written from this repo, and adding the URL once through the Options
dialog is the only supported way. Do it in the profile the pod will actually
read:

* **dev** — add `http://postgrest.mt5-data.svc.cluster.local:3000` over VNC. The
  terminal writes into the **host-mounted** profile
  (`$MT5_DATA_DIR/profile/dev/Config`), which is the directory the pod mounts.
* **prod** — the profile has to be opened by a terminal, the URL added, and that
  tree uploaded to MinIO **before** it is used (see "Copying the login profile
  to MinIO"); `fetch-profile` then seeds a `Config` that already contains the
  entry.

**Prod risk (unverified).** The prod overlay is headless
(`components/prod-headless`: no KasmVNC, no nginx, no s6), so the dialog step
**cannot be performed inside the prod pod at all**: prod depends entirely on the
encrypted blob inside the seeded `Config` being accepted by the prod terminal.
Whether it is accepted there has **not** been tested — the blob may be tied to
something we cannot reproduce, and no run has yet shown a prod terminal
answering a whitelisted `WebRequest`. Treat it as unknown until measured. The
check is the EA's own log line: `WebRequest ... error 4060`/`4014` means the URL
was not accepted. If that happens, the EA's HTTP test cannot run in prod without
a one-off UI-capable run (a KasmVNC-capable MT5 pod or a local terminal) to
whitelist the URL in the profile that is later uploaded.

Without the entry `WebRequest()` returns `-1` with `GetLastError()` `4060` or
`4014`, and the EA logs exactly that. Raw MQL5 sockets are **not** a workaround:
measured on build 6320, a plain TCP connect to the same host:port returned
`false` with error `4014` while `WebRequest` to the same URL answered `200` from
the same terminal with the same whitelist entry. That is why the EA uses the
7-argument `WebRequest()` and carries no HTTP framing of its own — `WebRequest`
handles `Content-Length`, chunked responses and connection setup.

### Running the test

Start from an empty database, so a leaked row cannot mask a failure. The
Postgres `emptyDir` dies with its pod:

```bash
# both Deployments carry app.kubernetes.io/part-of=postgrest-test
kubectl -n mt5-data delete pod -l app.kubernetes.io/part-of=postgrest-test
kubectl -n mt5-data rollout status deploy/postgres
kubectl -n mt5-data rollout status deploy/postgrest
```

Two `-l` flags on one `kubectl delete pod` are an **AND**, not an OR, so
`-l app.kubernetes.io/name=postgres -l app.kubernetes.io/name=postgrest`
matches nothing. Either use the single shared label as above, or delete the two
pods one by one (postgres first).

Then get the EA onto a chart. MT5 builds the Navigator's expert list at startup
and refuses to attach an EA whose `.ex5` was compiled after the terminal
started, so a restart is required before the first attach. The verified path is
the Navigator, not the auto-start variable:

1. Restart the terminal so the Navigator rescans `MQL5/Experts`. Restarting the
   whole MT5 pod also rescans it, but re-clones `MQL5_GIT_REF` into the
   `emptyDir`, so `PostgrestTestEA.ex5` must then be part of the released tree
   (see "MQL5 delivery and release").
2. Over VNC: **Navigator > Expert Advisors**, double-click `PostgrestTestEA`.
3. Accept the attach dialog with **Allow Algo Trading** checked.

```bash
kubectl -n mt5 logs -f deployment/mt5 -c mt5 | grep POSTGREST
```

Measured caveat: writing `MT5_AUTO_START_EA=PostgrestTestEA` into both
`startup.ini` locations (the install root and the terminal UUID directory
`D0E8209F77C8CF37AD8BF550E51FF075`) did **not** decide the attachment in this
test — the terminal still attached `TestAutoStartEA`. So attach via the
Navigator as above. What attaches an EA when the shipped profile loads is the
chart profile: `mql5/Profiles/Charts/Default/chart01.chr` carries an
`<expert>` block (`name=` / `path=Experts\TestAutoStartEA.ex5`) naming the EA
attached on boot, currently `TestAutoStartEA`.

The same lines appear in the terminal journal and in `MQL5/logs/YYYYMMDD.log`
inside the pod.

Each step prints its method, URL, status and a body snippet:

```
POSTGREST POST http://postgrest.mt5-data.svc.cluster.local:3000/events -> HTTP 201 | [...]
POSTGREST PATCH .../events?id=eq.<id> -> HTTP 200 | [...]
POSTGREST GET .../events?id=eq.<id> -> HTTP 200 | [...]
POSTGREST DELETE .../events?id=eq.<id> -> HTTP 204
POSTGREST GET .../events?id=eq.<id> (after delete) -> HTTP 200 | []
POSTGREST-TEST PASS: create/update/read/delete/read on http://postgrest.mt5-data.svc.cluster.local:3000/events (id=<id>, 0 rows left)
```

`POSTGREST-TEST FAIL: WebRequest(...) error 4060` means the whitelist step above
was skipped for this profile. The table must be empty afterwards — `curl` exists
in the dev image:

```bash
kubectl -n mt5 exec deploy/mt5 -c mt5 -- \
  curl -s 'http://postgrest.mt5-data.svc.cluster.local:3000/events'
# -> []
```

### Teardown

```bash
kubectl delete namespace mt5-data
```

Nothing is persisted (`PGDATA` is an `emptyDir`), so deleting the two pods is
already a full reset.

## Secrets

Short version: the repo-root `.env` is the only local secret source, and
`scripts/secrets.sh apply` turns it into the two Secrets the dev overlay reads
(`mt5-secrets` in `mt5`, `postgrest-db` in `mt5-data`); prod gets the same
Secret names from Vault through `ExternalSecret`. The overlays contain no
`secretGenerator`, so `kubectl apply -k` never reads a local file and every
overlay renders on a clean checkout.

The key table, the Vault mapping, the credential/coordinate seam and rotation
are in one place: [../docs/secrets.md](../docs/secrets.md). Do not duplicate
them here.

This checkout is on **exFAT**, which stores no POSIX modes: `chmod 600` on `.env`
is a no-op and the file shows as `0755`. Keep real credentials out of an exFAT
checkout, or move it to ext4.

Non-secret configuration lives in `ConfigMap mt5-env` in `base/configmap.yaml`:
`MQL5_GIT_URL`/`MQL5_GIT_REF`, `MINIO_URL`/`MINIO_BUCKET`/
`MINIO_PROFILE_PREFIX` (login-profile source for `fetch-profile`),
`VNC_RESOLUTION`, `COMPANY_ENV`,
`COMPANY_REGION`, `MT5_BROKER_SERVER`, `MT5_BROKER_PORT`,
`ENABLE_MT5LINUX_API`, `MT5_AUTO_START_EA/SYMBOL/PERIOD`,
`LOG_RETENTION_DAYS`, `LOG_RETENTION_INTERVAL`, `HEADLESS`, `WINEPREFIX`,
`LSIO_NON_ROOT_USER`.

## Talos (prod) overlay

`deploy/overlays/talos-prod` is the prod workload — the headless image — running on
the single-node Talos cluster (`admin@homelab-cluster`, ~4 CPU / ~8 GB RAM).
This is the only prod environment; the local kind cluster is dev-only. It shares
the base and the `prod-headless` component, so `HEADLESS=true`, the `tini`
entrypoint and the lean resources are identical to any other prod render; only
image, storage, secret source and Service ports are cluster-specific.

**It has not been applied.** Everything below is the procedure for the first
apply; these pieces already exist:

* the image `markram92/mt5-prod:1.0.0` is **pushed to Docker Hub** — 916 MB
  compressed, digest
  `sha256:bb489cd3c6cd4ec8f9925a2027fb5ac114c1625d0b3149e1edbb31295f56cb1a`,
  pushed 2026-11-16;
* the one-time login-profile copy to MinIO (bucket `mt5`, prefix `prod-demo`)
  is **done**;
* everything else — the Vault keys, the apply itself and the Flux registration —
  is still outstanding.

Preconditions for the first apply, in order:

1. Vault `secret/mt5` exists with `MINIO_ACCESS_KEY` and `MINIO_SECRET_KEY`
   (otherwise the `ExternalSecret` fails and the pod never starts) — see
   "Vault: write the MinIO keys".
2. `prod-demo/` is present in bucket `mt5` (already done) — see "Copying the
   login profile to MinIO".
3. The dev pod is **stopped**: both environments log in to the same demo
   account (`26435893` on `VantageMarkets-Demo`), so never run dev and prod
   concurrently.
4. Then `kubectl --context admin@homelab-cluster apply -k deploy/overlays/talos-prod`
   ("Apply"), or the Flux path ("Flux alternative").

### 1. Registry: build and push the image

The overlay pins `markram92/mt5-prod:1.0.0` (Docker Hub), so the image has to
exist in the registry before the pod can start. Tag `1.0.0` is already pushed
(916 MB compressed, digest
`sha256:bb489cd3c6cd4ec8f9925a2027fb5ac114c1625d0b3149e1edbb31295f56cb1a`,
pushed 2026-11-16), so re-run this only for a rebuild or a new tag:

```bash
podman login docker.io                 # once per login session (see auth store note)
./scripts/push-image.sh                # builds prod/ and pushes tag 1.0.0
./scripts/push-image.sh 1.0.1         # explicit tag (edit the overlay's newTag to match)
./scripts/push-image.sh 1.0.0 --build-only   # build + tag locally, no push, no auth needed
```

`push-image.sh` stages the build context under `$TMPDIR` (this checkout is on
exFAT, where buildah cannot mount its overlay), tags `markram92/mt5-prod:<tag>`
and pushes. It looks for the podman login store in **podman's own order** —
`$REGISTRY_AUTH_FILE` if set, else
`$XDG_RUNTIME_DIR/containers/auth.json` (usually
`/run/user/<uid>/containers/auth.json`), else `~/.config/containers/auth.json` —
and refuses with a non-zero exit **before** building when none of those exists
or the one it found holds no `docker.io` entry; the message names the paths it
searched. Only `~/.config` used to be checked, which produced a false "not
logged in" on hosts where `podman login` had written the runtime-dir store.

The runtime-dir store is per-login-session state: it **disappears on logout or
reboot**, so after either, `podman login docker.io` has to be run again before
a push. The script never prints credentials — it only inspects the registry key
names in the auth store. A pushed tag has to match the overlay's `newTag`;
re-pushing an existing tag does not update a running pod (the Deployment is
`imagePullPolicy: IfNotPresent`), so use a new tag or `kubectl rollout restart`.

### 2. Vault: write the MinIO keys

The Talos overlay has **no `secretGenerator`** and no MT5 credential Secret:
MT5 logs in from the profile in MinIO, and dev logs in from its host profile.
`externalsecret.yaml` asks the external-secrets operator (ClusterSecretStore
`vault-backend`, the fleet convention) to materialize Secret **`mt5-minio`**,
which only the `fetch-profile` init container reads. The Vault properties use
the same names as the Secret keys:

| Secret key | Vault property | consumer |
|---|---|---|
| `MINIO_ACCESS_KEY` | `MINIO_ACCESS_KEY` | `fetch-profile` → `RCLONE_CONFIG_SRC_ACCESS_KEY_ID` |
| `MINIO_SECRET_KEY` | `MINIO_SECRET_KEY` | `fetch-profile` → `RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY` |
| `POSTGRES_USER` | `POSTGRES_USER` | Secret `postgrest-db` (`deploy/apps/postgrest/talos-prod/`) → the `postgres` and `postgrest` pods of the test stack (role + anon role) |
| `POSTGRES_PASSWORD` | `POSTGRES_PASSWORD` | Secret `postgrest-db` (`deploy/apps/postgrest/talos-prod/`) → the `postgres` and `postgrest` pods of the test stack |

Vault KV v2 path: **`secret/mt5`** (API path `/v1/secret/data/mt5`),
`refreshInterval: 1h`. Write it before applying:

```bash
vault kv put secret/mt5 MINIO_ACCESS_KEY=... MINIO_SECRET_KEY=...
# add the PostgREST test database credentials to the SAME path (do not re-put
# the keys above with empty values — kv put replaces the whole secret)
vault kv patch secret/mt5 POSTGRES_USER=mt5 POSTGRES_PASSWORD="$(openssl rand -hex 32)"
```

`POSTGRES_USER` must be the same role everywhere (Vault, the kind env file) —
the postgres entrypoint creates it and PostgREST connects as it.
`POSTGRES_PASSWORD` must be URL-safe hex (or base64url): it is embedded verbatim
in `PGRST_DB_URI`, so `/`, `:` or `@` would have to be percent-encoded.

Until the path exists, the ExternalSecret reports `SecretSyncedError` and the
pod sits in `CreateContainerConfigError` (Secret `mt5-minio` absent). Nothing in
the repo holds these values. Bucket `mt5`, prefix `prod-demo` and the in-cluster
endpoint (`http://minio.minio.svc.cluster.local:9000`, patched over the base
`MINIO_URL`) come from ConfigMap `mt5-env`; the profile itself must already be
uploaded (see "Copying the login profile to MinIO").

### 3. Apply

```bash
# NOT run yet — this is the manual path.
kubectl --context admin@homelab-cluster apply -k deploy/overlays/talos-prod
```

The overlay creates `Namespace mt5`, `ConfigMap mt5-env`, the Deployment, the
Service, the PVC and the ExternalSecret. Expect the first rollout to take many
minutes: the PVC starts empty, so `seed-prefix` copies the baked Wine prefix,
`prepare-prefix` completes the pending Wine update and MT5 installs itself
inside the pod (the base `startupProbe` allows 20 minutes; the Deployment's
`progressDeadlineSeconds` is 1800).

### 4. Flux alternative

Fleet convention: app repos are registered in
`/mnt/storage/talos/terraform/terraform.tfvars` with
`path = "./deploy/clusters/base"` (the other fleet apps use `./clusters/base`,
so this repo keeps the entry point under `deploy/` and the tfvars value points
at it). Then `terraform apply` from the infra repo; Flux clones the repo and
kustomize-builds that one directory, which resolves to
`deploy/overlays/talos-prod`. Nothing under `talos/` is modified by this repo.

### Cluster-specific differences from kind

* **Storage.** `PVC mt5-prefix` requests 10Gi from `StorageClass local-path`
  (no PV manifest: the provisioner creates a hostPath volume on the single
  node on first bind). The Wine prefix, the MT5 install, the login state and the
  EA profile therefore survive pod restarts and rescheduling **on that node**,
  but not node reprovisioning or cluster rebuild.
* **Service.** Only the `mt5linux` API is published — `NodePort 30801`
  (`<node-ip>:30801`), the same API port the dev kind cluster uses. There is no
  VNC port: prod is headless. The container still *declares* `containerPort 3000`
  from base; nothing listens on it.
* **Resources.** Limits 1 CPU / 1Gi, requests 100m / 256Mi — a deliberate cap on
  a ~8 GB node shared with the rest of the homelab. The image is pulled once
  (`imagePullPolicy: IfNotPresent`).
* **MQL5.** Unchanged: the `fetch-mql5` init container clones this repo at the
  pinned tag `mql5-v1` (`ConfigMap mt5-env`) into a per-pod `emptyDir`; the
  image carries no MQL5.
* **Login profile.** The `fetch-profile` component seeds it, with `MINIO_URL`
  patched to the in-cluster Service
  `http://minio.minio.svc.cluster.local:9000` (bucket `mt5`, prefix
  `prod-demo`). Credentials come from Vault via the `mt5-minio` `ExternalSecret`,
  never from a file. Because the PVC starts empty, the first rollout seeds both
  the Wine prefix and the login profile; MT5 then logs in with no credentials at
  all. Dev never touches MinIO.
* **Namespace.** `Namespace mt5` is part of the render, so the first real apply
  creates it. A `--dry-run=server` run still fails on the namespaced objects
  until it exists (dry-run never persists the namespace), which is expected and
  not a manifest problem — verify with `--dry-run=client` instead.

## Security notes

* **MT5 never puts credentials on a command line.** There is no MT5 account
  variable anywhere, so `ps aux` inside the pod shows no `/login:/password:` —
  MT5 logs in from `Config/accounts.dat`.
* **The profile is the credential now.** `accounts.dat` is enough to open the
  terminal on that account, so treat it as a secret: keep bucket `mt5` private,
  never commit the profile, and restrict `pods/exec`/`pods/log` (and local
  `kubectl` access) on the `mt5` namespace. Anyone who can read the PVC, the dev
  host dir (`$MT5_DATA_DIR/profile/dev/Config`) or the MinIO bucket can use the
  account.
* **MinIO credentials never enter the repo.** The Talos path materializes Secret
  `mt5-minio` from Vault (`secret/mt5`); no value is printed or committed. The
  operator's one-time upload reads the same pair from the gitignored `.env` with
  `grep`/`cut` and never applies a credential file to a cluster.
* **`.env` sits on exFAT**, where `chmod 600` is a no-op, so the file is
  readable by any local user who can read the checkout. It holds the VNC pair,
  the Postgres role and the MinIO keys. Keep real credentials out of this
  checkout, or move it to a POSIX filesystem.
* The KasmVNC UI (dev only) is published on host `:3000` with the
  `CUSTOM_USER`/`PASSWORD` pair from `Secret mt5-secrets`; prod exposes only the
  mt5linux API on `:8001` (`NodePort 30801`), with no authentication of its own.

## Probes and limits

`start.sh` starts the mt5linux API on 8001 *before* launching MT5, so 8001 is
the stable readiness signal in both environments (dev's VNC comes up earlier;
prod has no VNC at all):

```yaml
startupProbe:   tcpSocket 8001  period 10  failureThreshold 120   # 20 min first-boot budget
readinessProbe: tcpSocket 8001  period 10  failureThreshold 6
livenessProbe:  tcpSocket 8001  period 30  failureThreshold 6
```

A cold prefix installs Mono, Wine Python and MetaTrader 5 inside the pod, so the
first rollout legitimately takes many minutes. `kind-up.sh` waits up to 1800s;
if it times out, watch progress with `kubectl -n mt5 logs deploy/mt5 -f`.

## Known deviations and pins

* **dev image pins `winehq-devel=11.10~bookworm-1` (`dev/Dockerfile`).** The
  `gmag11/metatrader5_vnc` base ships `winehq-stable` **10.0**, where MT5's
  anti-debug check misfires: a modal "A debugger has been found running in your
  system" appears, its OK button terminates `terminal64.exe`, and the container
  ends up with no terminal, no EA and no journal. Reproduced with both a fresh
  wine-10 prefix and a copy of the prod prefix, so it is Wine-version-specific,
  not prefix-specific. `dev/Dockerfile` now purges the stable packages, adds
  `i386`, and installs winehq-devel 11 pinned to an exact version (no floating
  tag) before the `wineboot`/Mono steps. `11.11` publishes no i386 half, so
  `11.10` is the newest installable full pair. `prod/Dockerfile` already ships
  wine 11 from `tobix/wine:stable` and is unchanged.
* **dev image pins `mt5linux==1.0.11` (`dev/Dockerfile`).** `mt5linux` >= 1.1.0
  uses PEP 701 multi-line f-string expressions in `mt5linux/metatrader5.py`,
  which require **Python >= 3.12**; the `gmag11/metatrader5_vnc` base image ships
  **Python 3.11.2**. With an unpinned install, step `[6/7]` of `start.sh` dies
  with `SyntaxError: unterminated string literal` and the API never binds 8001,
  which keeps the pod permanently `NotReady` and empties the Service endpoints.
  Verified in the dev image: `1.1.1` and `1.1.0` fail, `1.0.11` imports cleanly.
  `prod/Dockerfile` is untouched — `tobix/wine` is Debian trixie with Python 3.13,
  where the unpinned install works. Remove the pin once the dev base image moves
  to Python 3.12+ (or publish a 3.11-compatible mt5linux).
* **`Deployment/mt5` has two init containers (`seed-prefix` and
  `prepare-prefix`)** — see "First-boot prefix seeding" and "Prefix updates
  after a Wine change" above. `seed-prefix` exists because a Kubernetes hostPath
  PV/PVC does not get populated from the image the way a Docker named volume
  did; `prepare-prefix` completes a pending Wine update non-interactively when a
  prefix predates the image's Wine build.
* **`deploy/registries.conf` + `CONTAINERS_REGISTRIES_CONF`** — see the
  short-name note above; needed because this host has no
  `/etc/containers/registries.conf`.
* **Login profile is served by `rclone/rclone:1.76.0`, not `minio/mc`.** MinIO
  withdrew `minio/mc` and `minio/minio` from Docker Hub (all tags are
  pull-denied; upstream fallout: ClickHouse #120459) and quay.io requires auth,
  so the `mc` image cannot be pulled. The Chainguard replacement is distroless
  (no `/bin/sh`, so the seed-once conditional cannot run) and the Bitnami legacy
  image runs as uid 1001, which cannot write the root-owned prefix. `rclone`
  runs as root, has `/bin/sh`, speaks the same S3/MinIO API, and is already the
  client the operator uses for the one-time upload. Tag `1.76.0` matches the
  host binary; it is pinned, never `:latest`.

## Verifying a render without a cluster

Every overlay renders from committed files alone — no local secret file is
needed for any of them:

```bash
kubectl kustomize deploy/base                    > /dev/null
kubectl kustomize deploy/overlays/kind-dev       > /dev/null
kubectl kustomize deploy/overlays/talos-prod     > /dev/null
kubectl kustomize deploy/clusters/base           > /dev/null   # Flux entry point
kubectl --context admin@homelab-cluster apply --dry-run=client -k deploy/overlays/talos-prod
bash -n scripts/kind-up.sh && bash -n scripts/kind-down.sh \
  && bash -n scripts/push-image.sh && bash -n scripts/secrets.sh
```

Assert the secret seam itself:

```bash
# No overlay bakes a Secret any more: credentials are applied out-of-band
# (scripts/secrets.sh on kind, Vault on Talos).
for d in deploy/base deploy/overlays/kind-dev deploy/overlays/talos-prod deploy/clusters/base; do
  test "$(kubectl kustomize "$d" | grep -c 'kind: Secret')" -eq 0
done
kubectl kustomize deploy/overlays/talos-prod | grep -c 'kind: ExternalSecret'   # 2

# Coordinates are a ConfigMap, and the URI references them instead of literals
kubectl kustomize deploy/overlays/talos-prod | grep -q 'name: postgres-conn'
kubectl kustomize deploy/overlays/kind-dev \
  | grep -F 'value: postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)'
```

Profile wiring is part of that check:

```bash
# dev: hostPath Config mount, and NO fetch-profile
kubectl kustomize deploy/overlays/kind-dev \
  | grep -A3 'hostPath:' | grep -q '/var/lib/mt5/profile/dev/Config'
kubectl kustomize deploy/overlays/kind-dev | grep -c fetch-profile   # must be 0

# prod: fetch-profile runs LAST (after seed-prefix/prepare-prefix) with the
# expected bucket/prefix and the in-cluster endpoint
kubectl kustomize deploy/overlays/talos-prod | grep -A2 'name: fetch-profile'
kubectl kustomize deploy/overlays/talos-prod | grep 'MINIO_URL:'
```

The PostgREST test stack renders in both overlays and keeps its own namespace:

```bash
kubectl kustomize deploy/overlays/talos-prod | grep -c 'name: postgrest'   # 14: stack + ExternalSecret
# kind-dev: no overlay-level namespace, the included roots bring their own
kubectl kustomize deploy/overlays/kind-dev | grep -q 'namespace: mt5-data'
```

Applying needs both steps in this order, because the Secrets are not in the
render:

```bash
./scripts/secrets.sh apply                      # .env -> Secret mt5-secrets, postgrest-db
kubectl apply -k deploy/overlays/kind-dev
```
