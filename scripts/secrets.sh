#!/usr/bin/env bash
# The dev cluster's only path from local credentials to cluster Secrets.
#
# `.env` at the repo root holds the six local values (Vault secret/mt5 plus the
# dev-only VNC pair). This script reads it with grep/cut — never `source`, the
# file is operator-editable and must not execute — and creates the two Secrets
# the manifests read:
#
#   mt5-secrets   namespace mt5       CUSTOM_USER, PASSWORD        (KasmVNC)
#   postgrest-db  namespace mt5-data  POSTGRES_USER, PASSWORD      (PostgreSQL)
#
# The kustomize overlays deliberately carry no secretGenerator: they render from
# committed files alone, so a secret can never appear in a render, a diff or a
# git object, and applying an overlay never depends on what is on this disk.
#
# Prod never uses this path: the Talos cluster materializes the same Secret
# names from Vault through the external-secrets operator, so this script refuses
# any cluster that is not a local kind cluster.
#
# Values are never printed — not on success, not on failure. Only key names.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./scripts/secrets.sh apply   [--env-file PATH] [--context NAME]
       ./scripts/secrets.sh check   [--env-file PATH]
       ./scripts/secrets.sh --help

  apply    validate .env, then create/update Secret mt5/mt5-secrets and
           Secret mt5-data/postgrest-db from it. Needs a kind-* kubectl
           context (refused otherwise).
  check    validate .env only: every required key present and non-empty.
           Touches no cluster.

Options:
  --env-file PATH   secret file to read (default: <repo>/.env)
  --context NAME    use this kubectl context instead of the current one; the
                    only way to target a dev cluster not named kind-*. `apply`
                    only.

Neither the keys' values nor the rendered Secret YAML is ever printed.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="$REPO_ROOT/.env"
COMMAND=""
KUBE_CONTEXT=""

MT5_NAMESPACE="mt5"
DATA_NAMESPACE="mt5-data"

# The whole .env surface. A missing value is an error rather than a silent empty
# Secret key: an empty KasmVNC password or Postgres password is never what the
# operator meant (and the Postgres entrypoint refuses an empty PASSWORD).
REQUIRED_KEYS=(
    MT5_VNC_USER
    MT5_VNC_PASSWORD
    POSTGRES_USER
    POSTGRES_PASSWORD
    MINIO_ACCESS_KEY
    MINIO_SECRET_KEY
)

TMP_FILES=()
cleanup() {
    if [ "${#TMP_FILES[@]}" -gt 0 ]; then
        rm -f "${TMP_FILES[@]}"
    fi
}
trap 'status=$?; cleanup; exit $status' EXIT

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Read KEY=VALUE out of the file without sourcing it, stripping CR and one pair
# of surrounding quotes. Last occurrence wins, exactly like a shell would.
env_value() {
    local file="$1" key="$2" line
    line="$({ grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null || true; } | tail -n 1)"
    line="${line#*=}"
    line="${line%$'\r'}"
    line="${line#\"}"; line="${line%\"}"
    line="${line#\'}"; line="${line%\'}"
    printf '%s' "$line"
}

kubectl_cmd() {
    if [ -n "$KUBE_CONTEXT" ]; then
        kubectl --context "$KUBE_CONTEXT" "$@"
    else
        kubectl "$@"
    fi
}

check_env() {
    local missing=() key
    if [ ! -f "$ENV_FILE" ]; then
        printf 'ERROR: %s does not exist.\n' "$ENV_FILE" >&2
        printf '       Copy %s to it and fill in the values.\n' "$REPO_ROOT/.env.example" >&2
        exit 1
    fi
    for key in "${REQUIRED_KEYS[@]}"; do
        if [ -z "$(env_value "$ENV_FILE" "$key")" ]; then
            missing+=("$key")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        printf 'ERROR: %s has no value for:\n' "$ENV_FILE" >&2
        printf '  %s\n' "${missing[@]}" >&2
        printf 'Fill in those keys (see .env.example) and re-run.\n' >&2
        exit 1
    fi
    printf '==> %s: %s required keys present\n' "$ENV_FILE" "${#REQUIRED_KEYS[@]}"
}

# The dev adapter must never write into a real cluster: prod Secrets come from
# Vault, and overwriting them by hand would be silently reverted by the
# external-secrets refresh. Refuse loudly, and name the override.
require_kind_context() {
    local current
    if [ -n "$KUBE_CONTEXT" ]; then
        printf '==> Using context %s (--context override)\n' "$KUBE_CONTEXT"
        return 0
    fi
    current="$(kubectl config current-context 2>/dev/null || true)"
    if [ -z "$current" ]; then
        die "no current kubectl context: run ./scripts/kind-up.sh first, or pass --context NAME."
    fi
    case "$current" in
        kind-*)
            printf '==> Context %s is a local kind cluster\n' "$current"
            ;;
        *)
            printf 'ERROR: refusing to write Secrets into context %s: it is not a kind-* cluster.\n' "$current" >&2
            printf '       Prod Secrets come from Vault via ExternalSecret, not from a local file.\n' >&2
            printf '       For a dev cluster with a different name, re-run with --context NAME.\n' >&2
            exit 1
            ;;
    esac
}

apply_namespace() {
    local namespace="$1" out
    if ! out="$(kubectl_cmd create namespace "$namespace" --dry-run=client -o yaml | kubectl_cmd apply -f - 2>&1)"; then
        printf '%s\n' "$out" >&2
        die "could not ensure namespace $namespace exists."
    fi
    printf '==> Namespace %s present\n' "$namespace"
}

# apply_secret NAME NAMESPACE KEY=ENV_KEY [KEY=ENV_KEY ...]
#
# The values go through a private temporary env file rather than
# `--from-literal`: a literal would put the secret on kubectl's command line,
# which every local user can read from /proc while it runs. The YAML from
# `--dry-run=client` is piped straight into `apply`, so it is never printed.
apply_secret() {
    local name="$1" namespace="$2" out mapping tmp
    shift 2
    tmp="$(mktemp "${TMPDIR:-/tmp}/mt5-secret.XXXXXX")"
    TMP_FILES+=("$tmp")
    (
        umask 077
        for mapping in "$@"; do
            printf '%s=%s\n' "${mapping%%=*}" "$(env_value "$ENV_FILE" "${mapping#*=}")"
        done > "$tmp"
    )
    if ! out="$(kubectl_cmd create secret generic "$name" \
            --namespace "$namespace" \
            --from-env-file "$tmp" \
            --dry-run=client -o yaml \
            | kubectl_cmd apply -f - 2>&1)"; then
        printf '%s\n' "$out" >&2
        die "could not apply Secret $namespace/$name."
    fi
    rm -f "$tmp"
    printf '==> Secret %s/%s applied (%s keys)\n' "$namespace" "$name" "$#"
}

if [ "$#" -eq 0 ]; then
    usage >&2
    exit 2
fi

case "$1" in
    -h|--help)
        usage
        exit 0
        ;;
    apply|check)
        COMMAND="$1"
        shift
        ;;
    *)
        printf 'ERROR: unknown command: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
esac

while [ "$#" -gt 0 ]; do
    case "$1" in
        --env-file)
            [ "$#" -ge 2 ] || die "--env-file needs a path."
            ENV_FILE="$2"
            shift 2
            ;;
        --context)
            [ "$#" -ge 2 ] || die "--context needs a name."
            KUBE_CONTEXT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'ERROR: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$COMMAND" = "check" ] && [ -n "$KUBE_CONTEXT" ]; then
    die "--context only applies to \`apply\`; \`check\` never talks to a cluster."
fi

if [ "$COMMAND" = "check" ]; then
    check_env
    exit 0
fi

command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH."

check_env
require_kind_context

apply_namespace "$MT5_NAMESPACE"
apply_namespace "$DATA_NAMESPACE"

# Exactly two keys per Secret, mapped from the .env key names. MT5_SERVER /
# MT5_ACCOUNT / MT5_PASSWORD are deliberately absent: MT5 logs in from the login
# profile, and the base Deployment reads this Secret with `optional: true`, so
# absent variables are simply empty.
apply_secret mt5-secrets "$MT5_NAMESPACE" \
    CUSTOM_USER=MT5_VNC_USER \
    PASSWORD=MT5_VNC_PASSWORD

apply_secret postgrest-db "$DATA_NAMESPACE" \
    POSTGRES_USER=POSTGRES_USER \
    POSTGRES_PASSWORD=POSTGRES_PASSWORD

printf '==> Done. Apply the overlay: kubectl apply -k deploy/overlays/kind-dev\n'
