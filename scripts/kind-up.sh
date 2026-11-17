#!/usr/bin/env bash
# Bring up the local mt5 kind cluster and deploy the DEV workload onto it.
#
#   ./scripts/kind-up.sh
#
# The local kind cluster is DEV ONLY: image localhost/mt5-dev:dev (gmag11 base,
# KasmVNC UI on :3000, HEADLESS=false) applied from deploy/overlays/kind-dev.
# Prod does not run here at all — it runs on the Talos cluster from
# deploy/overlays/talos-prod with the published markram92/mt5-prod image.
#
# Both environments use the same demo account (26435893 on VantageMarkets-Demo),
# but dev logs in from the HOST-mounted profile ($MT5_DATA_DIR/profile/dev/Config)
# and needs no MinIO, while prod seeds the same profile from MinIO once.
#
# Credentials: the repo-root .env is the single local source. This script no
# longer generates per-overlay secret env files — it calls scripts/secrets.sh,
# which reads .env and creates the two Secrets before the overlay is applied.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./scripts/kind-up.sh [-h|--help]

Brings up (if needed) the local kind cluster, builds localhost/mt5-dev:dev from
dev/, loads it into the node and applies deploy/overlays/kind-dev. There is no
mode switch: this cluster runs dev only.

Requires .env at the repo root (copy .env.example and fill it in):
scripts/secrets.sh creates the cluster Secrets from it.

Environment:
  MT5_DATA_DIR        host directory for the Wine prefix (default: $HOME/mt5-data)
  KIND_IMAGE_TMPDIR   where image archives are staged (default: ~/.cache/mt5-kind-image-tars)
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1 (this script takes no options; the kind cluster is dev-only)" >&2
            usage >&2
            exit 2
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Rootless podman requires a delegated systemd scope; re-exec inside one.
if [ -z "${KIND_IN_DELEGATED_SCOPE:-}" ] && [ "$(id -u)" -ne 0 ]; then
    export KIND_IN_DELEGATED_SCOPE=1
    if command -v systemd-run >/dev/null 2>&1; then
        exec systemd-run --user --scope --quiet --collect --property=Delegate=yes -- "$0" "$@"
    fi
    echo "ERROR: rootless kind needs a delegated systemd scope and systemd-run is missing." >&2
    echo "       Either install systemd, or create /etc/systemd/user@.service.d/delegate.conf with [Service] Delegate=yes" >&2
    exit 1
fi

CLUSTER_NAME="mt5"
KIND_CONFIG_TMPL="deploy/kind-cluster.yaml.tmpl"
DATA_DIR="${MT5_DATA_DIR:-$HOME/mt5-data}"
# The Wine prefix must live on a real filesystem: Wine maps built-in DLLs with
# UNIX symlinks, which exFAT cannot store (the repo itself is on exFAT).
DATA_DIR="${DATA_DIR%/}"

IMAGE="localhost/mt5-dev:dev"
BUILD_CONTEXT="dev"
OVERLAY="deploy/overlays/kind-dev"

# dev login profile: the host directory mounted (read-write) over the terminal's
# Config dir. It is inside $DATA_DIR, which the kind node already extraMounts at
# /var/lib/mt5, so adding it needs no cluster recreation. MT5 writes
# accounts.dat/servers.dat here on login; this is also the exact tree the
# operator copies to MinIO for prod to seed from (deploy/README.md).
PROFILE_DEV_DIR="$DATA_DIR/profile/dev/Config"
PREFIX_PROFILE_DIR="$DATA_DIR/prefix/drive_c/Program Files/MetaTrader 5/Config"

# Secrets are not part of this overlay any more: scripts/secrets.sh reads the
# repo-root .env and creates them out-of-band (see the "Applying" step below).
# The overlay therefore renders from committed files alone — no secret env file
# has to exist next to its kustomization.

# `podman save` writes uncompressed layers (dev image is ~8.8GB), so the
# archive must NOT go to $TMPDIR — on this host /tmp is a 7.5GB tmpfs.
IMAGE_TMPDIR="${KIND_IMAGE_TMPDIR:-$HOME/.cache/mt5-kind-image-tars}"
RENDERED_CONFIG="${TMPDIR:-/tmp}/kind-mt5-cluster.yaml"

trap 'echo "ERROR: command failed on line $LINENO: $BASH_COMMAND" >&2' ERR

cleanup() {
    rm -f "$RENDERED_CONFIG"
    rm -f "${IMAGE_TMPDIR}"/kind-image-*.tar
    rm -rf "${TMPDIR:-/tmp}"/kind-build-mt5-dev
}
trap 'status=$?; cleanup; exit $status' EXIT

echo "==> Image: $IMAGE (dev overlay $OVERLAY)"

echo "==> Checking required tools"
missing=()
for tool in podman kind kubectl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing+=("$tool")
    fi
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: missing required tool(s): ${missing[*]}" >&2
    echo "Install with: pacman -S podman kind kubectl" >&2
    exit 1
fi

export KIND_EXPERIMENTAL_PROVIDER=podman
echo "==> Using podman as the kind provider (KIND_EXPERIMENTAL_PROVIDER=podman)"

# This host has no /etc/containers/registries.conf, so unqualified image names
# do not resolve at all ("short-name ... did not resolve to an alias"). Both
# Dockerfiles and kind itself use short names, so point podman/buildah at the
# repo-local alias table.
export CONTAINERS_REGISTRIES_CONF="$REPO_ROOT/deploy/registries.conf"

# buildah mounts an overlay over the build context; exFAT cannot host one.
# Stage the context on a native filesystem when that is the case.
stage_context() {
    local src="$1" name="$2" fs dst
    fs="$(stat -f -c %T "$src" 2>/dev/null || echo unknown)"
    if [ "$fs" != "exfat" ]; then
        printf '%s\n' "$src"
        return 0
    fi
    dst="${TMPDIR:-/tmp}/kind-build-$name"
    echo "==> Staging build context '$src' (on $fs) to '$dst'" >&2
    rm -rf "$dst"
    mkdir -p "$dst"
    tar -C "$src" --exclude=.git --exclude=local --exclude=.gitignore -cf - . | tar -C "$dst" -xf -
    printf '%s\n' "$dst"
}

# kind 0.33 relies on RepoTags that podman 6 no longer reports, so
# `kind load docker-image` is unusable: export an archive and import that.
load_image() {
    local ref="$1"
    local tar="${IMAGE_TMPDIR}/kind-image-$(printf '%s' "$ref" | tr '/:' '__').tar"
    mkdir -p "$IMAGE_TMPDIR"
    echo "==> Loading $ref into kind cluster '$CLUSTER_NAME'"
    podman save -q -o "$tar" "$ref"
    kind load image-archive --name "$CLUSTER_NAME" "$tar"
    rm -f "$tar"
}

# MT5 does not take credentials from the environment: dev logs in from the
# host-mounted Config directory, so the only Secret the pod reads is the VNC
# pair. scripts/secrets.sh turns the repo-root .env into both Secrets later,
# once the cluster exists (this script never writes per-overlay env files).
echo "==> dev logs in from the mounted profile at $PROFILE_DEV_DIR (no MT5 credentials)."
echo "    Log in manually via VNC only when that profile is first created."

echo "==> Ensuring prefix data dir '$DATA_DIR' exists"
mkdir -p "$DATA_DIR/prefix"

# The dev overlay mounts this host directory (hostPath type Directory) over the
# terminal's Config dir, so it must exist before the cluster config is rendered
# / the pod starts. Seed it ONCE from the shared prefix's Config file set (not
# the whole prefix) when it is still empty; after that MT5 owns it.
echo "==> Ensuring dev login-profile dir '$PROFILE_DEV_DIR' exists"
mkdir -p "$PROFILE_DEV_DIR"
if [ -z "$(find "$PROFILE_DEV_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    if [ -d "$PREFIX_PROFILE_DIR" ]; then
        echo "==> Seeding the empty dev profile dir from the prefix Config file set"
        cp -a "$PREFIX_PROFILE_DIR"/. "$PROFILE_DEV_DIR"/
    else
        echo "==> No prefix Config to seed from yet; log in once via VNC to create the profile"
    fi
fi

echo "==> Rendering kind cluster config from $KIND_CONFIG_TMPL"
sed -e "s|@REPO_ROOT@|$REPO_ROOT|g" -e "s|@DATA_DIR@|$DATA_DIR|g" "$KIND_CONFIG_TMPL" > "$RENDERED_CONFIG"

echo "==> Ensuring kind cluster '$CLUSTER_NAME' exists"
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    kind create cluster --name "$CLUSTER_NAME" --config "$RENDERED_CONFIG"
else
    echo "Cluster '$CLUSTER_NAME' already exists (extraMounts/port mappings are fixed at creation;"
    echo "run scripts/kind-down.sh first if $DATA_DIR or $REPO_ROOT moved)."
fi

echo "==> Building $IMAGE from $BUILD_CONTEXT/"
BUILD_CTX="$(stage_context "$BUILD_CONTEXT" "mt5-dev")"
podman build -t "$IMAGE" "$BUILD_CTX"

load_image "$IMAGE"

echo "==> Verifying the image is present in the node"
NODE_NAME="$(kind get nodes --name "$CLUSTER_NAME" | head -n 1)"
if ! podman exec "$NODE_NAME" crictl images --quiet "$IMAGE" | grep -q .; then
    echo "ERROR: image $IMAGE is missing from node $NODE_NAME after import." >&2
    exit 1
fi
podman exec "$NODE_NAME" crictl images "$IMAGE"

echo "==> Applying kustomize overlay $OVERLAY"
# The overlay carries no secretGenerator, so the Secrets must exist first: this
# is the only step that turns .env into cluster Secrets, and it refuses a
# non-kind context (prod Secrets come from Vault).
"$SCRIPT_DIR/secrets.sh" apply
kubectl apply -k "$OVERLAY"

echo "==> Enforcing single-Deployment exclusivity"
deployments="$(kubectl -n mt5 get deployment -o name | sort)"
if [ "$deployments" != "deployment.apps/mt5" ]; then
    echo "ERROR: namespace mt5 must contain exactly one Deployment named mt5, found:" >&2
    printf '%s\n' "$deployments" >&2
    exit 1
fi

echo "==> Restarting the workload so the freshly built image is used"
kubectl -n mt5 rollout restart deployment/mt5

echo "==> Waiting for PVC mt5-prefix to bind"
kubectl -n mt5 wait --for=jsonpath='{.status.phase}'=Bound pvc/mt5-prefix --timeout=120s

echo "==> Waiting for the pod to become Ready (first boot installs MT5 inside the pod; this can take many minutes)"
# The Deployment sets progressDeadlineSeconds: 1800 (the 600s default would be
# shorter than a cold MT5 install).
kubectl -n mt5 rollout status deployment/mt5 --timeout=1800s

echo ""
echo "==> Done (dev on kind)"
kubectl -n mt5 get pods,pvc
echo ""
echo "KasmVNC UI:    http://localhost:3000  (user/password from the repo-root .env)"
echo "mt5linux API:  localhost:8001"
echo "Prod runs on the Talos cluster (deploy/overlays/talos-prod), never here."
