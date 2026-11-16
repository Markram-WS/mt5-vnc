#!/usr/bin/env bash
# Delete the mt5 kind cluster. The Wine prefix on the host ($MT5_DATA_DIR,
# default $HOME/mt5-data) is deliberately left untouched: it holds the MT5
# install, the login state and the EA profile, and it is the one thing worth
# keeping across cluster rebuilds. Built images are kept too.
set -euo pipefail

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
DATA_DIR="${MT5_DATA_DIR:-$HOME/mt5-data}"

export KIND_EXPERIMENTAL_PROVIDER=podman
# See scripts/kind-up.sh: this host has no /etc/containers/registries.conf.
export CONTAINERS_REGISTRIES_CONF="$REPO_ROOT/deploy/registries.conf"

trap 'echo "ERROR: command failed on line $LINENO: $BASH_COMMAND" >&2' ERR

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    echo "==> Deleting kind cluster '$CLUSTER_NAME'"
    kind delete cluster --name "$CLUSTER_NAME"
    echo "Removed kind cluster '$CLUSTER_NAME' (containers, node images, and cluster state)."
    echo "Kept: image localhost/mt5-dev:dev (prod runs on Talos from the registry image)."
    echo "Kept: Wine prefix data dir '$DATA_DIR'."
else
    echo "Kind cluster '$CLUSTER_NAME' does not exist; nothing to remove."
fi

rm -f "${TMPDIR:-/tmp}/kind-mt5-cluster.yaml"
