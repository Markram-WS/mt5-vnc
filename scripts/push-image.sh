#!/usr/bin/env bash
# Build the prod image and push it to Docker Hub.
#
#   ./scripts/push-image.sh [TAG] [--build-only]    # TAG defaults to 1.0.0
#
# The tag is the release contract for the Talos prod overlay:
# deploy/overlays/talos pins markram92/mt5-prod:<tag>, so pushing a new tag means
# editing that overlay (or re-pushing the same tag and restarting the pod). This
# is the only prod image; the local kind cluster runs dev only.
#
# Credentials: the push uses the podman login store, looked up in podman's own
# order — $REGISTRY_AUTH_FILE if set, else
# $XDG_RUNTIME_DIR/containers/auth.json (usually /run/user/<uid>/containers/auth.json),
# else ~/.config/containers/auth.json. A `podman login` done from a desktop
# session writes the runtime-dir store, so checking only the config file produces
# a false "not logged in". The runtime dir is per-session state and disappears on
# logout/reboot, so re-run `podman login docker.io` after either. Nothing here
# reads, prints or copies the values — only the presence of a docker.io entry is
# checked, and that check only ever happens for keys, never for secrets.
#
# Output may be piped (`./scripts/push-image.sh | tail`): a closed stdout makes
# a later echo fail with EPIPE/SIGPIPE, which is not a script failure and must
# not print a bogus ERROR line.
#
# Behaviours worth knowing:
#   * this checkout is on exFAT, where buildah cannot mount its overlay, so the
#     build context is staged under $TMPDIR first (same trick as kind-up.sh);
#   * --build-only stops after the build (no auth needed, nothing pushed), which
#     is the path to use while the registry login does not exist yet;
#   * a failed push is never faked: podman's exit status is propagated.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./scripts/push-image.sh [TAG] [--build-only]

  TAG           release tag for markram92/mt5-prod (default: 1.0.0)
  --build-only  build and tag locally, do not push

Environment:
  REGISTRY_AUTH_FILE  podman login store (overrides the lookup below)
  TMPDIR              where the build context is staged (repo is on exFAT)

The login store is looked up in podman's own order:
  $REGISTRY_AUTH_FILE, else $XDG_RUNTIME_DIR/containers/auth.json,
  else ~/.config/containers/auth.json
EOF
}

TAG=""
BUILD_ONLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --build-only)
            BUILD_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$TAG" ]; then
                echo "ERROR: only one TAG may be given (got '$TAG' and '$1')" >&2
                exit 2
            fi
            TAG="$1"
            shift
            ;;
    esac
done
TAG="${TAG:-1.0.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

REGISTRY="docker.io"
REPOSITORY="markram92/mt5-prod"
IMAGE="${REPOSITORY}:${TAG}"
BUILD_CONTEXT="prod"

# This host has no /etc/containers/registries.conf, so unqualified image names
# in prod/Dockerfile (tobix/wine) do not resolve without the repo-local aliases.
export CONTAINERS_REGISTRIES_CONF="$REPO_ROOT/deploy/registries.conf"

# A closed stdout (piping into `tail`/`head`) makes a later echo fail with
# EPIPE or SIGPIPE. That is not a script failure, so report only real errors;
# set -e still exits on any genuine failure.
on_err() {
    local status=$? command="$BASH_COMMAND"
    if [ "$status" -eq 141 ]; then
        return 0                       # SIGPIPE: the reader went away
    fi
    case "$command" in
        echo*|printf*) [ "$status" -eq 1 ] && return 0 ;;   # EPIPE on output only
    esac
    echo "ERROR: command failed on line $LINENO: $command" >&2
}
trap on_err ERR

# Does the podman login store carry an entry for Docker Hub? Only KEY NAMES are
# inspected; no token, password or `auth` blob is ever echoed.
has_docker_hub_auth() {
    local file="$1"
    [ -f "$file" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        # `keys[]` yields registry URLs only.
        jq -r '.auths // {} | keys[]' "$file" 2>/dev/null \
            | grep -qE '(^|/)(docker\.io|index\.docker\.io|registry-1\.docker\.io)(/v1/?)?$'
    else
        grep -qE '"(https://index\.docker\.io/v1/|docker\.io|registry-1\.docker\.io)"' "$file"
    fi
}

# Resolve the login store in podman's own order: an explicit $REGISTRY_AUTH_FILE
# wins (podman then reads nothing else), otherwise the runtime-dir store, then
# ~/.config. A desktop-session `podman login` writes the runtime-dir store, which
# is why looking only at ~/.config reported a false "not logged in".
AUTH_FILE=""
AUTH_SEARCHED=()
resolve_auth_file() {
    local candidate
    AUTH_FILE=""
    AUTH_SEARCHED=()
    if [ -n "${REGISTRY_AUTH_FILE:-}" ]; then
        candidate="$REGISTRY_AUTH_FILE"
        AUTH_SEARCHED+=("$candidate")
        if [ -f "$candidate" ]; then
            AUTH_FILE="$candidate"
            return 0
        fi
        return 1
    fi
    for candidate in \
        "${XDG_RUNTIME_DIR:-/run/user/$UID}/containers/auth.json" \
        "$HOME/.config/containers/auth.json"; do
        AUTH_SEARCHED+=("$candidate")
        if [ -f "$candidate" ]; then
            AUTH_FILE="$candidate"
            return 0
        fi
    done
    return 1
}

require_auth() {
    if ! resolve_auth_file; then
        cat >&2 <<EOF
ERROR: not logged in to $REGISTRY — no podman login store found.

Nothing was built or pushed. Looked for (podman's order):
$(printf '  %s\n' "${AUTH_SEARCHED[@]}")

Either:
  podman login $REGISTRY          # creates the login store, prompts for credentials
  ./scripts/push-image.sh $TAG --build-only   # build locally without a push
EOF
        exit 3
    fi
    if ! has_docker_hub_auth "$AUTH_FILE"; then
        cat >&2 <<EOF
ERROR: $AUTH_FILE has no $REGISTRY entry.

Nothing was built or pushed. Run:
  podman login $REGISTRY
then re-run ./scripts/push-image.sh $TAG
(or use --build-only to build the image locally without a push).
EOF
        exit 3
    fi
}

echo "==> Tools"
missing=()
for tool in podman; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: missing required tool(s): ${missing[*]}" >&2
    exit 1
fi

if [ "$BUILD_ONLY" -eq 0 ]; then
    # Checked BEFORE the build: a missing login must not cost a full image build.
    echo "==> Checking push credentials"
    require_auth
    echo "==> $REGISTRY login for $REPOSITORY found in $AUTH_FILE (values not read)"
else
    echo "==> --build-only: skipping the credential check and the push"
fi

STAGED_CONTEXT=""
cleanup() {
    # `[ … ] &&` would return 1 when nothing was staged, and a failing command in
    # this EXIT trap makes the whole script exit 1 after a successful push.
    if [ -n "$STAGED_CONTEXT" ]; then
        rm -rf "$STAGED_CONTEXT"
    fi
}
trap 'status=$?; cleanup; exit $status' EXIT

# buildah mounts an overlay over the build context and exFAT cannot host one
# (and exFAT also stores no POSIX modes/symlinks, which prod/ may rely on).
# Sets STAGED_CONTEXT (empty when the context is used in place) — it cannot be
# assigned inside a command substitution, so the caller reads it from here.
stage_context() {
    local src="$1" fs dst
    fs="$(stat -f -c %T "$src" 2>/dev/null || echo unknown)"
    if [ "$fs" != "exfat" ]; then
        return 0
    fi
    dst="${TMPDIR:-/tmp}/mt5-prod-build"
    echo "==> Staging build context '$src' (on $fs) to '$dst'" >&2
    rm -rf "$dst"
    mkdir -p "$dst"
    tar -C "$src" --exclude=.git --exclude=.env --exclude=.gitignore -cf - . | tar -C "$dst" -xf -
    STAGED_CONTEXT="$dst"
}

echo "==> Building $IMAGE from $BUILD_CONTEXT/"
BUILD_CTX="$BUILD_CONTEXT"
stage_context "$BUILD_CONTEXT"
if [ -n "$STAGED_CONTEXT" ]; then
    BUILD_CTX="$STAGED_CONTEXT"
fi
podman build -t "$IMAGE" "$BUILD_CTX"

if [ "$BUILD_ONLY" -eq 1 ]; then
    echo ""
    echo "==> Built $IMAGE locally; nothing was pushed (--build-only)."
    echo "    Push it later with: ./scripts/push-image.sh $TAG"
    exit 0
fi

echo "==> Pushing $IMAGE"
podman push "$IMAGE"

echo ""
echo "==> Pushed $IMAGE"
echo "    deploy/overlays/talos pins markram92/mt5-prod:1.0.0 — keep the tag in"
echo "    sync with what was just pushed before applying the overlay."
