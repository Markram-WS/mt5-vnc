#!/usr/bin/env bash
# Bring up the mt5 kind cluster and deploy one mode of MT5 onto it.
#
#   ./scripts/kind-up.sh [--mode dev|prod]     # default: dev
#
# dev  -> image localhost/mt5-dev:dev   (gmag11 base, KasmVNC UI on :3000, HEADLESS=false)
# prod -> image localhost/mt5-prod:prod (tobix/wine base, headless, HEADLESS=true)
#
# The two modes are mutually exclusive and share ONE Deployment named mt5 plus
# one Wine-prefix PVC, so switching is just a re-run with the other --mode: the
# Recreate strategy tears the old pod down before the new one starts.
set -euo pipefail

# Saved before the option parser consumes "$@": the delegated-scope re-exec
# below happens after parsing, so it must forward the ORIGINAL arguments (a
# re-exec with the drained "$@" silently falls back to the default mode).
ORIGINAL_ARGS=("$@")

usage() {
    cat <<'EOF'
Usage: ./scripts/kind-up.sh [--mode dev|prod]

  --mode dev    (default) VNC build, reachable at http://localhost:3000
  --mode prod   headless build, API at localhost:8001

Environment:
  MT5_DATA_DIR        host directory for the Wine prefix (default: $HOME/mt5-data)
  KIND_IMAGE_TMPDIR   where image archives are staged (default: ~/.cache/mt5-kind-image-tars)
EOF
}

MODE=dev
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode)
            [ "$#" -ge 2 ] || { echo "ERROR: --mode needs a value (dev|prod)" >&2; exit 2; }
            MODE="$2"
            shift 2
            ;;
        --mode=*)
            MODE="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$MODE" in
    dev|prod) ;;
    *) echo "ERROR: --mode must be 'dev' or 'prod' (got '$MODE')" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Rootless podman requires a delegated systemd scope; re-exec inside one.
if [ -z "${KIND_IN_DELEGATED_SCOPE:-}" ] && [ "$(id -u)" -ne 0 ]; then
    export KIND_IN_DELEGATED_SCOPE=1
    if command -v systemd-run >/dev/null 2>&1; then
        exec systemd-run --user --scope --quiet --collect --property=Delegate=yes -- "$0" "${ORIGINAL_ARGS[@]}"
    fi
    echo "ERROR: rootless kind needs a delegated systemd scope and systemd-run is missing." >&2
    echo "       Either install systemd, or create /etc/systemd/user@.service.d/delegate.conf with [Service] Delegate=yes" >&2
    exit 1
fi

CLUSTER_NAME="mt5"
KIND_CONFIG_TMPL="deploy/kind-cluster.yaml.tmpl"
SECRETS_EXAMPLE="deploy/base/secrets.env.example"
DATA_DIR="${MT5_DATA_DIR:-$HOME/mt5-data}"
# The Wine prefix must live on a real filesystem: Wine maps built-in DLLs with
# UNIX symlinks, which exFAT cannot store (the repo itself is on exFAT).
DATA_DIR="${DATA_DIR%/}"

case "$MODE" in
    dev)
        IMAGE="localhost/mt5-dev:dev"
        BUILD_CONTEXT="dev"
        OVERLAY="deploy/overlays/kind-dev"
        ENV_FILE="dev/.env"
        ;;
    prod)
        IMAGE="localhost/mt5-prod:prod"
        BUILD_CONTEXT="prod"
        OVERLAY="deploy/overlays/kind-prod"
        ENV_FILE="prod/.env"
        ;;
esac

# The secret is generated INSIDE the overlay: kustomize refuses an env file that
# lies outside the kustomization root ("security; file ... is not in or below"),
# so each overlay owns its own deploy/overlays/<mode>/secrets.env. Keeping it
# out of base/ is what lets base — and the homelab overlay — render without any
# local secret file.
SECRETS_FILE="$OVERLAY/secrets.env"

# `podman save` writes uncompressed layers (dev image is ~8.8GB), so the
# archive must NOT go to $TMPDIR — on this host /tmp is a 7.5GB tmpfs.
IMAGE_TMPDIR="${KIND_IMAGE_TMPDIR:-$HOME/.cache/mt5-kind-image-tars}"
RENDERED_CONFIG="${TMPDIR:-/tmp}/kind-mt5-cluster.yaml"

trap 'echo "ERROR: command failed on line $LINENO: $BASH_COMMAND" >&2' ERR

cleanup() {
    rm -f "$RENDERED_CONFIG"
    rm -f "${IMAGE_TMPDIR}"/kind-image-*.tar
    rm -rf "${TMPDIR:-/tmp}"/kind-build-mt5-dev "${TMPDIR:-/tmp}"/kind-build-mt5-prod
}
trap 'status=$?; cleanup; exit $status' EXIT

echo "==> Mode: $MODE (image $IMAGE)"

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

# Read KEY=VALUE out of a .env without ever sourcing it, and never echo values.
env_value() {
    local file="$1" key="$2" line
    line="$({ grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null || true; } | tail -n 1)"
    line="${line#*=}"
    line="${line%$'\r'}"
    line="${line#\"}"; line="${line%\"}"
    line="${line#\'}"; line="${line%\'}"
    printf '%s' "$line"
}

# Credentials for this mode's overlay. Never printed, never committed: the file
# is written mode 0600 (best effort on exFAT) from the mode's .env, and only
# when it does not exist yet — a later run of the other mode keeps its own file.
echo "==> Checking $SECRETS_FILE"
if [ ! -f "$SECRETS_FILE" ]; then
    if [ ! -f "$ENV_FILE" ]; then
        cp "$SECRETS_EXAMPLE" "$SECRETS_FILE"
        chmod 600 "$SECRETS_FILE"
        echo "ERROR: $SECRETS_FILE was missing and $ENV_FILE does not exist." >&2
        echo "A template was copied from $SECRETS_EXAMPLE (mode 0600)." >&2
        echo "Fill in CUSTOM_USER, PASSWORD, MT5_SERVER, MT5_ACCOUNT and MT5_PASSWORD, then re-run." >&2
        exit 1
    fi
    echo "==> Generating $SECRETS_FILE from $ENV_FILE"
    (
        umask 077
        {
            printf 'CUSTOM_USER=%s\n' "$(env_value "$ENV_FILE" MT5_VNC_USER)"
            printf 'PASSWORD=%s\n' "$(env_value "$ENV_FILE" MT5_VNC_PASSWORD)"
            printf 'MT5_SERVER=%s\n' "$(env_value "$ENV_FILE" MT5_SERVER)"
            printf 'MT5_ACCOUNT=%s\n' "$(env_value "$ENV_FILE" MT5_ACCOUNT)"
            printf 'MT5_PASSWORD=%s\n' "$(env_value "$ENV_FILE" MT5_PASSWORD)"
        } > "$SECRETS_FILE"
    )
    chmod 600 "$SECRETS_FILE"
    # The repo is exFAT, which stores no POSIX modes: the chmod above silently
    # does nothing there. Say so instead of pretending the file is private.
    if [ "$(stat -c %a "$SECRETS_FILE" 2>/dev/null)" != "600" ]; then
        echo "WARNING: $SECRETS_FILE could not be chmod 600 (filesystem does not store POSIX modes);" >&2
        echo "         keep real credentials out of this checkout, or move deploy/ onto an ext4 filesystem." >&2
    fi
fi

echo "==> Ensuring prefix data dir '$DATA_DIR' exists"
mkdir -p "$DATA_DIR/prefix"

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
BUILD_CTX="$(stage_context "$BUILD_CONTEXT" "mt5-$MODE")"
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
# `rollout status` tracks the NEW ReplicaSet only, so it cannot be satisfied by
# the previous mode's still-Ready pod. It works here because the Deployment sets
# progressDeadlineSeconds: 1800 (the 600s default would be shorter than a cold
# MT5 install).
kubectl -n mt5 rollout status deployment/mt5 --timeout=1800s

echo ""
echo "==> Done ($MODE mode)"
kubectl -n mt5 get pods,pvc
echo ""
case "$MODE" in
    dev)
        echo "KasmVNC UI:    http://localhost:3000  (user/password from $SECRETS_FILE)"
        echo "mt5linux API:  localhost:8001"
        ;;
    prod)
        echo "Headless:      no UI. mt5linux API: localhost:8001"
        echo "Logs:          kubectl -n mt5 logs deploy/mt5 -f"
        ;;
esac
