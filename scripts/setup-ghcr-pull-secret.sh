#!/usr/bin/env bash
# =============================================================================
# setup-ghcr-pull-secret.sh — create the GHCR image-pull secret in the cluster.
#
# Interactive; run with no args:   ./scripts/setup-ghcr-pull-secret.sh
# Prompts for namespace / secret name / registry / GitHub username and a token
# (PAT with read:packages), then creates the docker-registry pull secret
# (default "ghcr-pull" in "apps") that private app images reference.
# Requires: kubectl (pointed at the target cluster).
# =============================================================================
set -euo pipefail

DEFAULT_NAMESPACE="apps"
DEFAULT_SECRET_NAME="ghcr-pull"
DEFAULT_REGISTRY="ghcr.io"
DEFAULT_USERNAME="Branchenprimus"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

read_secret() {
  local prompt="$1"
  local value

  printf '%s' "$prompt" >&2
  IFS= read -r -s value
  printf '\n' >&2
  printf '%s' "$value"
}

prompt() {
  local label="$1"
  local default="${2:-}"
  local value

  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "$label: " value
    [[ -n "$value" ]] || die "$label is required"
    printf '%s' "$value"
  fi
}

main() {
  need_cmd kubectl

  local namespace
  local secret_name
  local registry
  local username
  local token

  namespace="$(prompt 'Kubernetes namespace' "$DEFAULT_NAMESPACE")"
  secret_name="$(prompt 'Image pull secret name' "$DEFAULT_SECRET_NAME")"
  registry="$(prompt 'Container registry' "$DEFAULT_REGISTRY")"
  username="$(prompt 'GitHub username/owner' "$DEFAULT_USERNAME")"

  cat <<'EOF'

Create a GitHub token for GHCR pulls:
  1. Open https://github.com/settings/tokens
  2. Choose "Tokens (classic)".
  3. Click "Generate new token" -> "Generate new token (classic)".
  4. Give it a clear name, for example "k3s ghcr pull".
  5. Select the read:packages scope.
  6. Generate the token and paste it here.

If the package belongs to an organization, make sure the token's user has access
to that organization/package. The token is stored only in the Kubernetes secret.
EOF

  token="$(read_secret 'GHCR pull token: ')"
  [[ -n "$token" ]] || die "Token is required."

  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry "$secret_name" \
    --namespace "$namespace" \
    --docker-server="$registry" \
    --docker-username="$username" \
    --docker-password="$token" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -

  unset token

  printf 'Updated image pull secret %s/%s.\n' "$namespace" "$secret_name"
}

main "$@"
