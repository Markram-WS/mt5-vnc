# Secrets

One local file, one script, two Secrets. This page is the whole subject:
what lives in `.env`, what each value becomes in each cluster, how to rotate it,
and what is deliberately *not* a secret.

Credentials are never in a manifest and never in a kustomize render. The
overlays carry no `secretGenerator`, so `kubectl kustomize` works on a clean
checkout, and a Secret can never appear in a diff, an image or a git object.

## The local source: `.env`

`.env` at the repo root is gitignored and is the **only** place local
credentials live; `.env.example` is the tracked template (`cp .env.example .env`,
then fill it in). `scripts/secrets.sh` reads it with `grep`/`cut` and never
`sources` it — the file is operator-editable and must not execute.

Exactly six keys:

| `.env` key | Becomes | Consumed by |
|---|---|---|
| `MT5_VNC_USER` | Secret `mt5/mt5-secrets` → `CUSTOM_USER` | KasmVNC login (dev image) |
| `MT5_VNC_PASSWORD` | Secret `mt5/mt5-secrets` → `PASSWORD` | KasmVNC login (dev image) |
| `POSTGRES_USER` | Secret `mt5-data/postgrest-db` → `POSTGRES_USER` | postgres role + `PGRST_DB_ANON_ROLE` |
| `POSTGRES_PASSWORD` | Secret `mt5-data/postgrest-db` → `POSTGRES_PASSWORD` | postgres entrypoint + `PGRST_DB_URI` |
| `MINIO_ACCESS_KEY` | Vault `secret/mt5` (prod); operator's rclone (local) | `fetch-profile`, profile upload |
| `MINIO_SECRET_KEY` | Vault `secret/mt5` (prod); operator's rclone (local) | `fetch-profile`, profile upload |

The two MinIO keys are not applied to the kind cluster: dev never talks to
MinIO. They live in `.env` so one file carries the local counterpart of Vault
`secret/mt5`, and so the one-time rclone copy can read them without a second
credential file.

`POSTGRES_USER` and the password must be URL-safe (hex is ideal): the password
is embedded verbatim in `PGRST_DB_URI`, so `/`, `:`, `@`, `?` or `#` would have
to be percent-encoded. `openssl rand -hex 32` is the intended generator.

Non-secret configuration is **not** here. `HEADLESS`, `LOG_RETENTION_*`,
`MT5_AUTO_START_*`, `MQL5_GIT_*`, `VNC_RESOLUTION`, `MINIO_URL` and friends live
in `deploy/base/configmap.yaml` (ConfigMap `mt5-env`), where they are readable
and reviewable.

## The dev adapter: `scripts/secrets.sh`

```
scripts/secrets.sh check  [--env-file PATH]   # validate .env, no cluster access
scripts/secrets.sh apply  [--env-file PATH]   # validate, then create the Secrets
scripts/secrets.sh apply  --context NAME      # dev cluster not named kind-*
scripts/secrets.sh --help
```

`check` requires all six keys to be present and non-empty and names the ones
that are missing (never the values) — an empty KasmVNC or Postgres password is
never what the operator meant.

`apply` runs `check`, then creates the two namespaces if needed and the two
Secrets:

| Secret | Namespace | Keys | Source `.env` keys |
|---|---|---|---|
| `mt5-secrets` | `mt5` | `CUSTOM_USER`, `PASSWORD` | `MT5_VNC_USER`, `MT5_VNC_PASSWORD` |
| `postgrest-db` | `mt5-data` | `POSTGRES_USER`, `POSTGRES_PASSWORD` | same names |

Both are created with `kubectl create secret generic … --dry-run=client -o yaml
| kubectl apply -f -`, so re-running is idempotent and the rendered Secret YAML
is never printed. Values reach kubectl through a private temporary env file, not
`--from-literal`, so they never appear on a command line that `/proc` exposes.

Three properties worth knowing:

* **`mt5-secrets` has exactly two keys.** `MT5_SERVER`, `MT5_ACCOUNT` and
  `MT5_PASSWORD` are gone for good — MT5 logs in from its login profile, not
  from environment variables. The base Deployment reads the Secret with
  `optional: true` and `start.sh` treats absent variables as empty, so a cluster
  with no `mt5-secrets` at all (prod) still runs.
* **The script refuses non-kind clusters.** It reads
  `kubectl config current-context` and exits 1 unless it starts with `kind-`,
  printing the context and the override. Prod Secrets are owned by the
  external-secrets operator; writing them by hand would be silently reverted on
  the next refresh. `--context NAME` is the explicit override for a dev cluster
  with a different name.
* **Never printed.** One line per Secret created or updated; failures print
  kubectl's message, never a value.

`scripts/kind-up.sh` calls `apply` after the cluster exists and before
`kubectl apply -k deploy/overlays/kind-dev`, which is the only ordering that
works: the namespaces come from the overlay, the Secrets from the script.

**Mode caveat.** This checkout is on exFAT, which stores no POSIX modes, so
`umask 077` and `chmod 600` are no-ops there: `.env` shows as `0755`. Keep real
credentials out of an exFAT checkout, or move the checkout to ext4.

## The prod adapter: Vault

Talos has no local secret file at all. The overlay ships `ExternalSecret`
objects that materialize the **same Secret names and keys** from Vault
(`ClusterSecretStore vault-backend`, KV v2 path `secret/mt5`), so neither the
Deployments nor their references differ between environments.

| Vault `secret/mt5` property | Secret | Namespace | Key |
|---|---|---|---|
| `MINIO_ACCESS_KEY` | `mt5-minio` | `mt5` | `MINIO_ACCESS_KEY` |
| `MINIO_SECRET_KEY` | `mt5-minio` | `mt5` | `MINIO_SECRET_KEY` |
| `POSTGRES_USER` | `postgrest-db` | `mt5-data` | `POSTGRES_USER` |
| `POSTGRES_PASSWORD` | `postgrest-db` | `mt5-data` | `POSTGRES_PASSWORD` |

Both properties of a pair must exist **before** the overlay is applied:
otherwise the ExternalSecret reports `SecretSyncedError` and the pods sit in
`CreateContainerConfigError`. Write them with `kv patch` (not `kv put`, which
replaces the whole secret):

```bash
vault kv patch secret/mt5 POSTGRES_USER=mt5 POSTGRES_PASSWORD="$(openssl rand -hex 32)"
```

## Credentials vs coordinates

The seam is deliberate: a Secret says **who** connects, a ConfigMap says
**where**.

* Secret `postgrest-db` — `POSTGRES_USER`, `POSTGRES_PASSWORD` only.
* ConfigMap `postgres-conn` (`deploy/apps/postgrest/configmap.yaml`) —
  `POSTGRES_HOST=postgres`, `POSTGRES_PORT=5432`, `POSTGRES_DB=mt5`,
  `POSTGREST_URL=http://postgrest.mt5-data.svc.cluster.local:3000`.

A location is not a credential: it is identical in every environment, safe to
read in `kubectl describe`, and must never need a rotation. `postgrest.yaml`
declares the coordinates *before* the URI because Kubernetes only expands
`$(VAR)` references to variables declared earlier in the list:

```
PGRST_DB_URI=postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)
```

Changing the database name or port is therefore one edit in `postgres-conn`,
not a secret rotation.

## Rotation

**VNC (kind).** Edit `MT5_VNC_PASSWORD` in `.env`, run `scripts/secrets.sh
apply`, then `kubectl -n mt5 rollout restart deploy/mt5` — KasmVNC reads the
Secret only at container start.

**Postgres (kind).** Edit `POSTGRES_PASSWORD` in `.env`, run `scripts/secrets.sh
apply`, then delete both fixture pods:

```bash
kubectl -n mt5-data delete pod -l app.kubernetes.io/part-of=postgrest-test
```

The role's password is set by `initdb` on first boot only, and `PGDATA` is an
`emptyDir`, so a fresh pod is how the new password takes effect (and the test
database is disposable by design).

**Prod.** `vault kv patch secret/mt5 …` and either wait for `refreshInterval:
1h` or force a sync. External secrets are the only writer: never `kubectl edit`
those Secrets.

**MinIO.** Rotating the pair means updating Vault *and* the operator's rclone
remote before the next `fetch-profile` run; an already-seeded PVC keeps working
until it is reset.

The login profile itself (bucket `mt5`, prefix `prod-demo`) is the one secret
that is not a Secret: `accounts.dat` is enough to open the terminal on the
account, so the bucket stays private and the profile is copied, never committed.

## Deliberately not a secret

* Every key in ConfigMap `mt5-env`: they are configuration, not credentials.
* ConfigMap `postgres-conn`: host, port, database name, PostgREST URL.
* The `events` table, the digest-pinned images and the Service ports.
* The repo itself: no credential is ever committed — `git grep` must stay
  clean, and `.env` is the single ignored file.
