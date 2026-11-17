# Context

The vocabulary this repo uses. Each term is a thing the deployment talks about,
not a file you have to open to understand.

**MT5 terminal.** The MetaTrader 5 Windows executable running under Wine in a
pod. It is a stateful desktop application, not a server: it keeps a writable
Wine prefix, logs in by itself from a stored login profile, and is driven
through either a VNC screen (dev) or the mt5linux Python API (both). Two
terminals on the same broker account fight over session state, so only one runs
at a time.

**Login profile.** The `Config` directory MT5 writes when an operator logs in —
`accounts.dat`, `servers.dat`, `common.ini`, certificates and the encrypted
WebRequest whitelist. It *is* the credential: a terminal that finds this
directory logs in with no password on a command line. Dev mounts a host
directory read-write so the login can be performed and inspected; prod seeds a
copy from object storage once, because a headless pod has no dialog to log in
with.

**MQL5 payload.** The authored trading code and the profiles/chart state that
make it run (`mql5/` in this repo), fetched by the pod at start into a
throwaway directory instead of being baked into the image. It is versioned by
git ref, so changing the code is a tag bump and a rollout, never an image
rebuild.

**Dev overlay.** `deploy/overlays/kind-dev`: the interactive workload on a local
kind cluster, with a VNC UI, published ports, the host login profile, and the
PostgREST fixture. Local secrets come from the checkout.

**Prod overlay.** `deploy/overlays/talos-prod`: the headless workload on the
Talos cluster, with no UI, a cluster StorageClass for the prefix, the MinIO
profile source, and credentials from Vault. It is the only prod deployment, and
Flux applies the same directory.

**Local secret source.** `/.env` at the repo root, gitignored, six keys: the
local counterpart of the prod secret store plus the dev-only VNC pair. It is
plain `KEY=VALUE` read by a script, never sourced, and it is the only place a
local credential may live.

**Secret contract.** The rule that both clusters expose the same Secret names
and keys (`mt5-secrets`, `postgrest-db`, `mt5-minio`) while *who creates them*
differs — a local script on kind, the external-secrets operator from Vault on
prod. Manifests reference the contract, never a source, which is why the
Deployments are identical in both environments. Coordinates (host, port,
database name) are not part of it: they live in a ConfigMap.

**PostgREST test fixture.** A disposable Postgres plus PostgREST in its own
`mt5-data` namespace, with a single `events` table, whose only purpose is to
prove the terminal can drive a real HTTP API from inside the cluster. The
database is on an `emptyDir` so every restart starts clean; it is a test
instrument, not a data service.
