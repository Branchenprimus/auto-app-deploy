#!/usr/bin/env bash
# =============================================================================
# remove_deployment.sh — unregister an app from this GitOps repo.
#
#   ./scripts/remove_deployment.sh <app-name|apps/<app>.yaml>
# Deletes apps/<app>.yaml, refreshes the Terraform app mirror, optionally
# removes the ArgoCD Application + k8s workload, and can Terraform-apply to drop
# the Cloudflare Access app. Does NOT delete the source repo or container images.
# Env: ARGOCD_NAMESPACE (default argocd). Requires: git, kubectl (+ terraform).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APPS_DIR="$PLATFORM_DIR/apps"
TERRAFORM_DIR="$PLATFORM_DIR/terraform/cloudflare-access"
TERRAFORM_APPS_DIR="$TERRAFORM_DIR/apps"
DEFAULT_ARGOCD_NAMESPACE="argocd"

usage() {
  cat <<EOF
Usage: $(basename "$0") [app-name|apps/app-name.yaml]

Remove an app deployment from this GitOps repo without deleting the app
repository or container images.

The script removes apps/<app>.yaml, refreshes the Terraform app mirror,
optionally deletes the ArgoCD Application and Kubernetes workload, and can run
Terraform apply to remove the Cloudflare Access application.

Environment:
  ARGOCD_NAMESPACE  ArgoCD namespace. Default: $DEFAULT_ARGOCD_NAMESPACE
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

prompt_yes_no() {
  local label="$1"
  local default="${2:-y}"
  local value

  read -r -p "$label [y/n, default: $default]: " value
  value="${value:-$default}"

  case "$value" in
    y|Y|yes|YES|true|TRUE) return 0 ;;
    n|N|no|NO|false|FALSE) return 1 ;;
    *) die "Please answer yes or no for: $label" ;;
  esac
}

yaml_value() {
  local file="$1"
  local key_path="$2"

  python3 - "$file" "$key_path" <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None

path = Path(sys.argv[1])
key_path = sys.argv[2].split(".")

if yaml:
    data = yaml.safe_load(path.read_text()) or {}
else:
    # Small fallback for this repo's simple app.yaml structure.
    data = {}
    stack = [(-1, data)]
    for raw_line in path.read_text().splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        line = raw_line.strip()
        if ":" not in line or line.startswith("- "):
            continue
        key, value = line.split(":", 1)
        value = value.strip()
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if value:
            parent[key] = value.strip('"\'')
        else:
            parent[key] = {}
            stack.append((indent, parent[key]))

value = data
for key in key_path:
    if not isinstance(value, dict) or key not in value:
        sys.exit(0)
    value = value[key]

if value is not None:
    print(value)
PY
}

list_app_files() {
  find "$APPS_DIR" -maxdepth 1 -type f -name '*.yaml' | sort
}

select_app_file() {
  local requested="${1:-}"
  local app_file
  local files=()
  local index
  local choice

  if [[ -n "$requested" ]]; then
    if [[ "$requested" == */* ]]; then
      app_file="$requested"
    else
      app_file="$APPS_DIR/${requested%.yaml}.yaml"
    fi
    [[ -f "$app_file" ]] || die "App config not found: $app_file"
    printf '%s' "$app_file"
    return
  fi

  while IFS= read -r app_file; do
    [[ -n "$app_file" ]] || continue
    files+=("$app_file")
  done < <(list_app_files)

  [[ "${#files[@]}" -gt 0 ]] || die "No app configs found in: $APPS_DIR"

  printf 'Deployments managed by this repo:\n' >&2
  for index in "${!files[@]}"; do
    local name
    local host
    name="$(yaml_value "${files[$index]}" "name")"
    host="$(yaml_value "${files[$index]}" "route.host")"
    printf '  %2d) %s  %s\n' "$((index + 1))" "${name:-$(basename "${files[$index]}" .yaml)}" "${host:-}" >&2
  done

  read -r -p 'Select deployment to remove [1]: ' choice
  choice="${choice:-1}"

  [[ "$choice" =~ ^[0-9]+$ ]] || die "Selection must be a number."
  [[ "$choice" -ge 1 && "$choice" -le "${#files[@]}" ]] || die "Selection out of range: $choice"

  printf '%s' "${files[$((choice - 1))]}"
}

sync_terraform_app_mirror() {
  mkdir -p "$TERRAFORM_APPS_DIR"
  find "$TERRAFORM_APPS_DIR" -maxdepth 1 -type f -name '*.yaml' -delete

  if compgen -G "$APPS_DIR/*.yaml" >/dev/null; then
    cp "$APPS_DIR"/*.yaml "$TERRAFORM_APPS_DIR/"
  fi

  touch "$TERRAFORM_APPS_DIR/.gitkeep"
}

delete_argocd_application() {
  local app_name="$1"
  local argocd_namespace="$2"

  if ! command -v kubectl >/dev/null 2>&1; then
    printf 'kubectl not found; skipping ArgoCD Application deletion.\n'
    return
  fi

  kubectl delete application "$app_name" \
    --namespace "$argocd_namespace" \
    --ignore-not-found \
    --wait=false
}

delete_kubernetes_workload() {
  local app_name="$1"
  local app_namespace="$2"

  if ! command -v kubectl >/dev/null 2>&1; then
    printf 'kubectl not found; skipping Kubernetes workload deletion.\n'
    return
  fi

  kubectl delete deployment,service,ingress "$app_name" \
    --namespace "$app_namespace" \
    --ignore-not-found \
    --wait=false
}

run_terraform_apply() {
  need_cmd terraform

  sync_terraform_app_mirror

  terraform -chdir="$TERRAFORM_DIR" init
  terraform -chdir="$TERRAFORM_DIR" apply -auto-approve
}

main() {
  need_cmd python3

  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
  esac

  local app_file
  local app_name
  local app_namespace
  local route_host
  local argocd_namespace="${ARGOCD_NAMESPACE:-$DEFAULT_ARGOCD_NAMESPACE}"

  app_file="$(select_app_file "${1:-}")"
  app_name="$(yaml_value "$app_file" "name")"
  app_namespace="$(yaml_value "$app_file" "namespace")"
  route_host="$(yaml_value "$app_file" "route.host")"

  [[ -n "$app_name" ]] || app_name="$(basename "$app_file" .yaml)"
  [[ -n "$app_namespace" ]] || app_namespace="apps"

  cat <<EOF

This will remove the deployment for:
  App:        $app_name
  Namespace:  $app_namespace
  Hostname:   ${route_host:-unknown}
  Config:     $app_file

The application repository and container images will not be deleted.
EOF

  prompt_yes_no 'Continue?' 'y' || {
    printf 'Aborted.\n'
    exit 0
  }

  rm -f "$app_file"
  rm -f "$TERRAFORM_APPS_DIR/$(basename "$app_file")"
  sync_terraform_app_mirror
  printf 'Removed GitOps app config and refreshed Terraform app mirror.\n'

  if prompt_yes_no 'Disconnect from ArgoCD now?' 'y'; then
    delete_argocd_application "$app_name" "$argocd_namespace"
  fi

  if prompt_yes_no 'Delete Kubernetes workload now?' 'y'; then
    delete_kubernetes_workload "$app_name" "$app_namespace"
  fi

  if prompt_yes_no 'Run Terraform apply to update Cloudflare Access now?' 'y'; then
    run_terraform_apply
  else
    printf 'Terraform apply skipped. Commit and push this repo so the Cloudflare Access workflow can remove the Access application.\n'
  fi

  cat <<EOF

Deployment removal prepared.

Next steps:
  git status --short
  git add apps terraform/cloudflare-access/apps
  git commit -m "Remove $app_name deployment"
  git push origin main

After push, ArgoCD and the Cloudflare Access workflow should converge on the removed deployment.
EOF
}

main "$@"
