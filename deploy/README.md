# Deployment (kustomize + kind/podman)

Two mutually exclusive MT5 modes on one local kind cluster:

| | **dev** | **prod** |
|---|---|---|
| Overlay | `overlays/kind-dev` | `overlays/kind-prod` |
| Image | `localhost/mt5-dev:dev` (built from `dev/Dockerfile`) | `localhost/mt5-prod:prod` (built from `prod/Dockerfile`) |
| Base image | `gmag11/metatrader5_vnc` (~8.8 GB) | `tobix/wine:stable` (~0.8 GB) |
| UI | KasmVNC on <http://localhost:3000> | none — `Xvfb :99`, headless |
| `HEADLESS` | `false` | `true` |
| API | `localhost:8001` (mt5linux) | `localhost:8001` (mt5linux) |
| Resources | requests 250m / 512Mi, limit 2Gi | requests 100m / 256Mi, limits 1 CPU / 1Gi |
| MQL5 source | `git clone` of this repo at `MQL5_GIT_REF` → pod `emptyDir` | same |

Both modes are the **same `Deployment/mt5`** in namespace `mt5`, mounting the
same Wine-prefix PVC and the same MQL5 tree. They differ only in image,
`HEADLESS` and resources, so a mode switch is an in-place update, not a second
workload.

## Layout

```
deploy/
├── base/                      # environment-agnostic resources
│   ├── namespace.yaml         # Namespace mt5
│   ├── configmap.yaml         # mt5-env: non-secret env
│   ├── deployment.yaml        # Deployment mt5: Recreate, prefix PVC, shm, probes
│   ├── service.yaml           # Service mt5: ClusterIP, vnc 3000 + mt5linux 8001
│   ├── kustomization.yaml     # namespace mt5 + resources (no secretGenerator)
│   └── secrets.env.example    # CUSTOM_USER/PASSWORD, MT5_SERVER/ACCOUNT/PASSWORD
├── components/
│   ├── kind-nodeports/
│   │   └── kustomization.yaml # Service NodePort 30300/30801 (shared by both modes)
│   └── prod-headless/
│       └── kustomization.yaml # HEADLESS=true + tini entrypoint + lean resources
├── overlays/
│   ├── kind-dev/
│   │   ├── kustomization.yaml # image :dev, secretGenerator + kind-nodeports
│   │   └── storage.yaml       # PV mt5-prefix-pv + PVC mt5-prefix
│   ├── kind-prod/
│   │   ├── kustomization.yaml # image :prod, prod-headless + kind-nodeports components
│   │   └── storage.yaml
│   └── homelab/               # prod on the real (Talos) cluster — NOT applied yet
│       ├── kustomization.yaml # image markram92/mt5-prod:1.0.0, NodePort 30801 only
│       ├── storage.yaml       # PVC mt5-prefix on StorageClass local-path
│       └── externalsecret.yaml # mt5-secrets from Vault secret/mt5/prod
├── clusters/
│   └── base/
│       └── kustomization.yaml # Flux entry point -> ../../overlays/homelab
├── kind-cluster.yaml.tmpl     # kind Cluster (placeholders @REPO_ROOT@ / @DATA_DIR@)
├── registries.conf            # short-name aliases (host has no /etc/containers/registries.conf)
└── README.md
scripts/
├── kind-up.sh                 # --mode dev|prod: build, load, apply, wait
├── kind-down.sh
└── push-image.sh              # build prod/ and push markram92/mt5-prod:<tag>
```

## Usage

```bash
./scripts/kind-up.sh --mode dev     # or: ./scripts/kind-up.sh
# ... use the VNC UI on http://localhost:3000
./scripts/kind-up.sh --mode prod    # replaces the dev pod with the headless one
./scripts/kind-down.sh              # deletes the cluster, keeps images + prefix data
```

`kind-up.sh` re-executes itself under
`systemd-run --user --scope --property=Delegate=yes` (rootless podman needs a
delegated cgroup scope), exports `KIND_EXPERIMENTAL_PROVIDER=podman`, creates
the cluster if it is missing, builds the mode's image from `dev/` or `prod/`,
imports it with `podman save` + `kind load image-archive` (kind 0.33 relies on
`RepoTags` that podman 6 no longer reports, so `kind load docker-image` cannot
work), applies the overlay, then waits for the PVC to bind and the pod to become
Ready.

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

### Cross-mode prefix updates (`prepare-prefix`)

The two images ship **different Wine vintages** (dev: winehq-devel 11.10
installed over `gmag11/metatrader5_vnc`, prod: wine 11.0 from
`tobix/wine:stable`) and share one prefix — a dev/prod patch-level difference
only. Whichever mode starts after the other therefore finds a stale prefix, and
the first Wine command in `start.sh` (`wine reg add ...Wine Updater...`) triggers
`wineboot --init`, which pops the **interactive** "install Wine Mono" dialog
(`control.exe appwiz.cpl install_mono`) and hangs the container (observed on the
dev→prod switch; it would equally hang on prod→dev).

The second init container, `prepare-prefix`, mounts the PVC at `/opt/mt5` and
completes that pending update non-interactively before `start.sh` runs:

```sh
export WINEDLLOVERRIDES="mscoree=d;mshtml=d"   # wineboot never prompts for Mono
xvfb-run -a wineboot -u                        # finish the prefix update silently
```

`mscoree=d` only suppresses the .NET/Mono bootstrap prompt; MT5 itself does not
depend on Mono for its core, and the Mono that the dev image already installed
stays in the prefix. A mode switch costs a few seconds here and nothing
afterwards (an up-to-date prefix makes `wineboot -u` a no-op).

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
* `30300 -> 3000` (VNC) and `30801 -> 8001` (API) host port mappings — identical
  in both modes because the modes never run simultaneously; in prod nothing
  ever listens on 3000;
* extraMounts: `@DATA_DIR@` → `/var/lib/mt5` only. The MQL5 tree is not a host
  mount any more — the pod clones it itself (see below), so the node never needs
  to see the repo checkout.

`$MT5_DATA_DIR` defaults to `$HOME/mt5-data` and **must be on a non-exFAT
filesystem**: Wine maps built-in DLLs with UNIX symlinks, so a prefix on exFAT
fails with `STATUS_DLL_NOT_FOUND` (`c0000135`). The script creates
`$MT5_DATA_DIR/prefix` before creating the cluster, because kind refuses
extraMounts whose host path does not exist.

## Storage semantics

* One PV `mt5-prefix-pv` (hostPath `/var/lib/mt5/prefix` inside the node, which
  is the extraMount of `$MT5_DATA_DIR`), `Retain`, `storageClassName: ""`,
  20Gi, statically bound to `PVC mt5-prefix` via `volumeName`. No StorageClass:
  kind ships no default provisioner and binding must be deterministic.
* The same PV/PVC pair is defined in both overlays, so either mode can be
  applied to a fresh cluster and a mode switch re-uses — never re-creates — the
  prefix. That is what carries the MT5 install, the login state and the EA
  profile from dev to prod.
* `Retain` means deleting the PVC never deletes the prefix; `kind-down.sh`
  likewise keeps `$MT5_DATA_DIR`.
* **The prefix is single-writer.** dev and prod must not run simultaneously;
  `strategy: Recreate` plus one Deployment enforces that structurally (the old
  pod is fully gone before the new one mounts the PVC).
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
* `hostAliases` maps `update.mql5.com` / `updates.mql5.com` to 127.0.0.1; k8s
  regenerates `/etc/hosts`, so this is the only way to keep MT5 LiveUpdate
  blocked.

`mql5/` carries the stock MT5 `.gitignore` (`*`, `*/`, `!.gitignore`), so MQL5
files must be added with `git add -f`. `mql5/Profiles` is tracked deliberately:
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
`kubectl apply -k deploy/overlays/kind-prod` (or `kind-dev`) →
`kubectl -n mt5 rollout restart deploy/mt5`. A rollback repeats those steps with
the previous tag. Runtime MQL5 state (logs, `experts.dat`, rewritten `Profiles`)
exists only in the `emptyDir` and is lost on restart.

## Secrets

There are two backends, chosen by the overlay:

* **`kind-dev` / `kind-prod`** — a `secretGenerator` (`mt5-secrets`,
  `disableNameSuffixHash: true`) reads a `secrets.env` that sits **inside the
  overlay** (`deploy/overlays/kind-dev/secrets.env`,
  `deploy/overlays/kind-prod/secrets.env`). It is not in `base/` because
  kustomize refuses an env file outside the kustomization root
  (`security; file … is not in or below …`), and because the base must render
  from committed files alone so the homelab overlay can replace the Secret with
  an `ExternalSecret`.
* **`homelab`** — the same Secret name is produced from Vault by an
  `ExternalSecret`; see "Homelab (prod) overlay" below.

`kind-up.sh` creates the overlay's `secrets.env` on first run from that mode's
`.env` (`dev/.env` for dev, `prod/.env` for prod) by reading
`MT5_VNC_USER`, `MT5_VNC_PASSWORD`, `MT5_SERVER`, `MT5_ACCOUNT`,
`MT5_PASSWORD` with `grep`/`cut` — the file is never `source`d — and writes it:

| secrets.env key | Source `.env` key | Consumed as |
|---|---|---|
| `CUSTOM_USER` | `MT5_VNC_USER` | KasmVNC user |
| `PASSWORD` | `MT5_VNC_PASSWORD` | KasmVNC password |
| `MT5_SERVER` | `MT5_SERVER` | MT5 `/login` server |
| `MT5_ACCOUNT` | `MT5_ACCOUNT` | MT5 `/login` account |
| `MT5_PASSWORD` | `MT5_PASSWORD` | MT5 `/login` password |

If the mode's `.env` does not exist either, the script copies
`base/secrets.env.example` to the overlay's `secrets.env`, exits `1` and tells
you to fill it in. Empty `MT5_*` values are acceptable — `start.sh` then
launches MT5 without `/login` arguments.

Each overlay's `secrets.env` is generated **only when absent**, so dev and prod
keep independent credentials and re-running `kind-up.sh` never overwrites a file
you already filled in. Delete `deploy/overlays/<mode>/secrets.env` to regenerate
it from that mode's `.env`.

Because this checkout is on **exFAT**, which stores no POSIX modes, `chmod 600`
on those files is a no-op; the script verifies the mode and prints a warning
instead of pretending the file is private. Do not put production credentials in
an exFAT checkout.

Non-secret configuration lives in `ConfigMap mt5-env` in `base/configmap.yaml`:
`MQL5_GIT_URL`/`MQL5_GIT_REF`, `VNC_RESOLUTION`, `COMPANY_ENV`,
`COMPANY_REGION`, `MT5_BROKER_SERVER`, `MT5_BROKER_PORT`,
`ENABLE_MT5LINUX_API`, `MT5_AUTO_START_EA/SYMBOL/PERIOD`,
`LOG_RETENTION_DAYS`, `LOG_RETENTION_INTERVAL`, `HEADLESS`, `WINEPREFIX`,
`LSIO_NON_ROOT_USER`.

## Homelab (prod) overlay

`deploy/overlays/homelab` is the same headless workload as `kind-prod`, but
running on the real single-node Talos cluster (`admin@homelab-cluster`, ~4 CPU /
~8 GB RAM) instead of kind. It shares the base and the `prod-headless`
component, so `HEADLESS=true`, the `tini` entrypoint and the lean resources are
byte-identical to `kind-prod`; only image, storage, secret source and Service
ports differ.

**It has not been applied.** Everything below is the procedure for the first
apply.

### 1. Registry: build and push the image

The overlay pins `markram92/mt5-prod:1.0.0` (Docker Hub), so the image has to
exist in the registry before the pod can start:

```bash
podman login docker.io                 # once; the auth store has no docker.io entry yet
./scripts/push-image.sh                # builds prod/ and pushes tag 1.0.0
./scripts/push-image.sh 1.0.1         # explicit tag (edit the overlay's newTag to match)
./scripts/push-image.sh 1.0.0 --build-only   # build + tag locally, no push, no auth needed
```

`push-image.sh` stages the build context under `$TMPDIR` (this checkout is on
exFAT, where buildah cannot mount its overlay), tags `markram92/mt5-prod:<tag>`
and pushes. It refuses with a non-zero exit **before** building when
`~/.config/containers/auth.json` is missing or holds no `docker.io` entry, and
it never prints credentials — it only inspects the registry key names in the
auth store. A pushed tag has to match the overlay's `newTag`; re-pushing an
existing tag does not update a running pod (the Deployment is
`imagePullPolicy: IfNotPresent`), so use a new tag or `kubectl rollout restart`.

### 2. Vault: write the five keys

The homelab overlay has **no `secretGenerator`**. `externalsecret.yaml` asks the
external-secrets operator (ClusterSecretStore `vault-backend`, the fleet
convention) to materialize Secret `mt5-secrets` from Vault:

| key | consumer |
|---|---|
| `CUSTOM_USER` | KasmVNC user (unused in headless, still required by `start.sh`) |
| `PASSWORD` | KasmVNC password (unused in headless) |
| `MT5_SERVER` | MT5 `/login` server |
| `MT5_ACCOUNT` | MT5 `/login` account |
| `MT5_PASSWORD` | MT5 `/login` password |

Vault path: **`secret/mt5/prod`**, one property per key, `refreshInterval: 1h`.
Write it before applying:

```bash
vault kv put secret/mt5/prod \
  CUSTOM_USER=... PASSWORD=... MT5_SERVER=... MT5_ACCOUNT=... MT5_PASSWORD=...
```

Until the path exists, the ExternalSecret reports `SecretSyncedError` and the
pod sits in `CreateContainerConfigError` (Secret `mt5-secrets` absent). Nothing
in the repo holds these values.

### 3. Apply

```bash
# NOT run yet — this is the manual path.
kubectl --context admin@homelab-cluster apply -k deploy/overlays/homelab
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
`deploy/overlays/homelab`. Nothing under `talos/` is modified by this repo.

### Cluster-specific differences from kind

* **Storage.** `PVC mt5-prefix` requests 10Gi from `StorageClass local-path`
  (no PV manifest: the provisioner creates a hostPath volume on the single
  node on first bind). The Wine prefix, the MT5 install, the login state and the
  EA profile therefore survive pod restarts and rescheduling **on that node**,
  but not node reprovisioning or cluster rebuild.
* **Service.** Only the `mt5linux` API is published — `NodePort 30801`
  (`<node-ip>:30801`), the same port the kind overlays use. There is no VNC
  port: prod is headless. The container still *declares* `containerPort 3000`
  from base; nothing listens on it.
* **Resources.** Limits 1 CPU / 1Gi, requests 100m / 256Mi — a deliberate cap on
  a ~8 GB node shared with the rest of the homelab. The image is pulled once
  (`imagePullPolicy: IfNotPresent`).
* **MQL5.** Unchanged: the `fetch-mql5` init container clones this repo at the
  pinned tag `mql5-v1` (`ConfigMap mt5-env`) into a per-pod `emptyDir`; the
  image carries no MQL5.
* **Namespace.** `Namespace mt5` is part of the render, so the first real apply
  creates it. A `--dry-run=server` run still fails on the namespaced objects
  until it exists (dry-run never persists the namespace), which is expected and
  not a manifest problem — verify with `--dry-run=client` instead.

## Security notes

* **MT5 credentials are visible in the pod.** `start.sh` passes them on the
  `terminal64.exe` command line, so they appear in the pod's process list
  (`kubectl -n mt5 exec deploy/mt5 -- ps aux` → `/login:<account>
  /password:<password> /server:<server>`) and in the container log line that
  echoes the server and account. Anyone who can `exec` into the pod or read its
  logs can read them: restrict `pods/exec` and `pods/log` RBAC (and local
  `kubectl` access to the cluster) accordingly. This is inherited from
  `start.sh`, not introduced by the manifests.
* **The kind overlays' `secrets.env` sit on exFAT**, where `chmod 600` is a
  no-op, so those files are readable by any local user who can read the
  checkout. `kind-up.sh` verifies the mode and warns instead of implying the
  file is private; keep real credentials out of this checkout (or move
  `deploy/` to a POSIX filesystem). The homelab overlay avoids the problem
  entirely: its credentials are materialized into the cluster from Vault by the
  ExternalSecret and never exist as a file here.
* The KasmVNC UI (dev mode only) is published on host `:3000` with the
  `CUSTOM_USER`/`PASSWORD` pair from that file; prod exposes only the mt5linux
  API on `:8001`, with no authentication of its own.

## Probes and limits

`start.sh` starts the mt5linux API on 8001 *before* launching MT5, so 8001 is
the stable readiness signal in both modes (dev's VNC comes up earlier; prod has
no VNC at all):

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
  `prepare-prefix`)** — see "First-boot prefix seeding" and "Cross-mode prefix
  updates" above. `seed-prefix` exists because a Kubernetes hostPath PV does not
  get populated from the image the way a Docker named volume did;
  `prepare-prefix` because the dev and prod images ship different Wine vintages
  over one shared prefix.
* **`deploy/registries.conf` + `CONTAINERS_REGISTRIES_CONF`** — see the
  short-name note above; needed because this host has no
  `/etc/containers/registries.conf`.

## Verifying a render without a cluster

```bash
kubectl kustomize deploy/base                    > /dev/null   # no local secrets needed
kubectl kustomize deploy/overlays/kind-dev       > /dev/null   # needs overlays/kind-dev/secrets.env
kubectl kustomize deploy/overlays/kind-prod      > /dev/null   # needs overlays/kind-prod/secrets.env
kubectl kustomize deploy/overlays/homelab        > /dev/null   # no local secrets needed
kubectl kustomize deploy/clusters/base           > /dev/null   # Flux entry point
kubectl --context admin@homelab-cluster apply --dry-run=client -k deploy/overlays/homelab
bash -n scripts/kind-up.sh && bash -n scripts/kind-down.sh && bash -n scripts/push-image.sh
```

The kind overlays each need their own `secrets.env` (run `kind-up.sh` once for
that mode, or copy `deploy/base/secrets.env.example` next to the overlay's
`kustomization.yaml`). `deploy/base` and `deploy/overlays/homelab` render from
committed files alone — that is the point of keeping the `secretGenerator` out
of base.
