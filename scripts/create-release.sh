#!/usr/bin/env bash
# =============================================================================
# create-release.sh — cut the next version tag and watch it deploy.
#
#   ./scripts/create-release.sh                    # pick a repo interactively
#   ./scripts/create-release.sh --project=<repo>   # target one repo, no prompts
#   ./scripts/create-release.sh --auto             # accept defaults for current repo
# Tags vX.Y.Z, pushes it, watches the GitHub Actions build, then reports the
# ArgoCD / Kubernetes rollout. Worktree must be clean. Requires: git, gh.
# =============================================================================
set -euo pipefail

DEFAULT_PROJECTS_DIR="/home/jan/projects"
DEFAULT_GITOPS_REPO_PATH="/home/jan/projects/auto-app-deploy"
DEFAULT_LIVE_TIMEOUT_SECONDS=300
AUTO_MODE=false
PROJECT_INPUT=""

usage() {
  cat <<'EOF'
Usage: create-release.sh [--auto] [--project=<repo_name|owner/repo|path>]

Create and push the next release tag, then watch the GitHub Actions pipeline.

Options:
  --auto                 Use default values for prompts after the project is known.
                         With no --project, only releases the current app repo;
                         it never chooses the first discovered repo.
  --project=<project>    Release the matching project without prompting.
                         Matches a local path, repo directory name, GitHub
                         owner/repo, or GitHub repo name under /home/jan/projects.
  -h, --help             Show this help.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

prompt() {
  local label="$1"
  local default="${2:-}"
  local value

  if [[ "$AUTO_MODE" == "true" ]]; then
    [[ -n "$default" ]] || die "$label is required in --auto mode"
    printf '%s' "$default"
    return
  fi

  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "$label: " value
    [[ -n "$value" ]] || die "$label is required"
    printf '%s' "$value"
  fi
}

prompt_yes_no() {
  local label="$1"
  local default="${2:-y}"
  local value

  if [[ "$AUTO_MODE" == "true" ]]; then
    value="$default"
  else
    read -r -p "$label [y/n, default: $default]: " value
    value="${value:-$default}"
  fi

  case "$value" in
    y|Y|yes|YES|true|TRUE) return 0 ;;
    n|N|no|NO|false|FALSE) return 1 ;;
    *) die "Please answer yes or no for: $label" ;;
  esac
}

resolve_repo_path() {
  local input="$1"

  if [[ "$input" = /* ]]; then
    printf '%s' "$input"
  else
    printf '%s/%s' "$DEFAULT_PROJECTS_DIR" "$input"
  fi
}

parse_args() {
  local arg

  for arg in "$@"; do
    case "$arg" in
      --auto)
        AUTO_MODE=true
        ;;
      --project=*)
        PROJECT_INPUT="${arg#--project=}"
        [[ -n "$PROJECT_INPUT" ]] || die "--project requires a value"
        AUTO_MODE=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $arg"
        ;;
    esac
  done
}

discover_git_repos() {
  find "$DEFAULT_PROJECTS_DIR" -maxdepth 4 -type d -name .git -prune -print 2>/dev/null \
    | while IFS= read -r git_dir; do
        local repo_path
        local origin

        repo_path="$(dirname "$git_dir")"
        origin="$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)"
        case "$origin" in
          git@github.com:*|ssh://git@github.com/*|https://github.com/*|http://github.com/*)
            printf '%s\n' "$repo_path"
            ;;
        esac
      done \
    | sort
}

repo_display_name() {
  local repo_path="$1"
  local origin
  local rel_path

  rel_path="${repo_path#$DEFAULT_PROJECTS_DIR/}"
  origin="$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)"

  if [[ -n "$origin" ]]; then
    printf '%s  (%s)' "$rel_path" "$origin"
  else
    printf '%s  (no origin)' "$rel_path"
  fi
}

resolve_project_repo_path() {
  local input="$1"
  local candidate
  local repo_path
  local github_repo
  local github_name
  local matches=()

  candidate="$(resolve_repo_path "$input")"
  if [[ -d "$candidate/.git" ]]; then
    printf '%s' "$candidate"
    return
  fi

  while IFS= read -r repo_path; do
    [[ -n "$repo_path" ]] || continue
    github_repo="$(github_repo_from_origin "$repo_path" || true)"
    github_name="${github_repo##*/}"

    if [[ "$(basename "$repo_path")" == "$input" \
      || "$github_repo" == "$input" \
      || "$github_name" == "$input" ]]; then
      matches+=("$repo_path")
    fi
  done < <(discover_git_repos)

  if [[ "${#matches[@]}" -eq 0 ]]; then
    printf '%s' "$candidate"
    return
  fi

  if [[ "${#matches[@]}" -gt 1 ]]; then
    printf 'Project name is ambiguous: %s\n' "$input" >&2
    for repo_path in "${matches[@]}"; do
      printf '  %s\n' "$(repo_display_name "$repo_path")" >&2
    done
    die "Use an absolute path or GitHub owner/repo."
  fi

  printf '%s' "${matches[0]}"
}

current_repo_path_for_auto() {
  local repo_path
  local gitops_path

  repo_path="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$repo_path" ]] || return 1
  repo_path="$(realpath "$repo_path")"
  gitops_path="$(realpath "$DEFAULT_GITOPS_REPO_PATH" 2>/dev/null || printf '%s' "$DEFAULT_GITOPS_REPO_PATH")"

  [[ -d "$repo_path/.git" ]] || return 1
  github_repo_from_origin "$repo_path" >/dev/null || return 1

  if [[ "$repo_path" == "$gitops_path" ]]; then
    printf 'Error: --auto without --project was run from the GitOps repo. Refusing to release auto-app-deploy implicitly. Use --project=<app> or run from the app repository.\n' >&2
    return 2
  fi

  printf '%s' "$repo_path"
}

select_repo_path() {
  local repos=()
  local repo_path
  local choice
  local index
  local auto_status

  if [[ "$AUTO_MODE" == "true" ]]; then
    set +e
    repo_path="$(current_repo_path_for_auto)"
    auto_status="$?"
    set -e

    if [[ "$auto_status" -eq 0 ]]; then
      printf '%s' "$repo_path"
      return
    fi
    [[ "$auto_status" -eq 2 ]] && exit 1

    die "--auto without --project cannot choose a repository safely from here. Run from the app repo or pass --project=<repo_name|owner/repo|path>."
  fi

  while IFS= read -r repo_path; do
    [[ -n "$repo_path" ]] || continue
    repos+=("$repo_path")
  done < <(discover_git_repos)

  if [[ "${#repos[@]}" -eq 0 ]]; then
    printf 'No GitHub-backed repositories found under: %s\n' "$DEFAULT_PROJECTS_DIR" >&2
    printf '%s' "$(resolve_repo_path "$(prompt 'Local repo path')")"
    return
  fi

  printf 'GitHub-backed repositories under %s:\n' "$DEFAULT_PROJECTS_DIR" >&2
  for index in "${!repos[@]}"; do
    printf '  %2d) %s\n' "$((index + 1))" "$(repo_display_name "${repos[$index]}")" >&2
  done
  printf '   m) Enter a path manually\n' >&2

  if [[ "$AUTO_MODE" == "true" ]]; then
    choice="1"
  else
    read -r -p 'Select repo [1]: ' choice
    choice="${choice:-1}"
  fi

  if [[ "$choice" == "m" || "$choice" == "M" ]]; then
    printf '%s' "$(resolve_repo_path "$(prompt 'Local repo path')")"
    return
  fi

  [[ "$choice" =~ ^[0-9]+$ ]] || die "Selection must be a number or m."
  [[ "$choice" -ge 1 && "$choice" -le "${#repos[@]}" ]] || die "Selection out of range: $choice"

  printf '%s' "${repos[$((choice - 1))]}"
}

github_repo_from_origin() {
  local repo_path="$1"
  local url
  local repo

  url="$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)"
  [[ -n "$url" ]] || return 1

  case "$url" in
    git@github.com:*)
      repo="${url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      repo="${url#ssh://git@github.com/}"
      ;;
    https://github.com/*)
      repo="${url#https://github.com/}"
      ;;
    http://github.com/*)
      repo="${url#http://github.com/}"
      ;;
    *)
      return 1
      ;;
  esac

  repo="${repo%.git}"
  [[ "$repo" == */* ]] || return 1
  printf '%s' "$repo"
}

latest_semver_tag() {
  local repo_path="$1"

  {
    git -C "$repo_path" tag --list 'v[0-9]*.[0-9]*.[0-9]*'
    git -C "$repo_path" ls-remote --tags origin 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null \
      | awk '{print $2}' \
      | sed -E 's#refs/tags/##; s/\^\{\}$//'
  } | sed -E 's/[[:space:]]+$//' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -Vu \
    | tail -n 1
}

next_major_tag() {
  local latest="$1"
  local version
  local major

  if [[ -z "$latest" ]]; then
    printf 'v1.0.0'
    return
  fi

  version="${latest#v}"
  major="${version%%.*}"
  printf 'v%s.0.0' "$((major + 1))"
}

ensure_clean_worktree() {
  local repo_path="$1"

  if [[ -n "$(git -C "$repo_path" status --porcelain)" ]]; then
    git -C "$repo_path" status --short
    die "Worktree has uncommitted changes. Commit or stash them before creating a release."
  fi
}

wait_for_run() {
  local repo="$1"
  local tag="$2"
  local head_sha="$3"
  local run_id=""
  local attempts=0

  printf '\nWaiting for GitHub Actions run for %s...\n' "$tag" >&2

  while [[ -z "$run_id" && "$attempts" -lt 30 ]]; do
    run_id="$(
      gh run list \
        --repo "$repo" \
        --event push \
        --branch "$tag" \
        --commit "$head_sha" \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId // empty'
    )"

    if [[ -z "$run_id" ]]; then
      attempts="$((attempts + 1))"
      sleep 4
    fi
  done

  [[ -n "$run_id" ]] || die "Could not find a GitHub Actions run for $tag."
  printf '%s' "$run_id"
}

print_run_steps() {
  local repo="$1"
  local run_id="$2"

  gh run view "$run_id" \
    --repo "$repo" \
    --json jobs \
    --jq '.jobs[] | "Job: \(.name) [\(if .conclusion == "" or .conclusion == null then .status else .conclusion end)]", (.steps[] | "  - \(.name): \(if .conclusion == "" or .conclusion == null then .status else .conclusion end)")'
}

app_yaml_value() {
  local repo_path="$1"
  local key_path="$2"
  local app_yaml="$repo_path/app.yaml"
  local parent
  local child

  [[ -f "$app_yaml" ]] || return 0

  if command -v yq >/dev/null 2>&1; then
    yq -r ".$key_path // \"\"" "$app_yaml"
    return
  fi

  if [[ "$key_path" != *.* ]]; then
    awk -F ': *' -v key="$key_path" '
      $1 == key {
        value = $2
        gsub(/^["'\'']|["'\'']$/, "", value)
        print value
        exit
      }
    ' "$app_yaml"
    return
  fi

  parent="${key_path%%.*}"
  child="${key_path#*.}"

  awk -F ': *' -v parent="$parent" -v child="$child" '
    $1 == parent {
      in_parent = 1
      next
    }
    in_parent && $0 !~ /^  / {
      in_parent = 0
    }
    in_parent && $1 == "  " child {
      value = $2
      gsub(/^["'\'']|["'\'']$/, "", value)
      print value
      exit
    }
  ' "$app_yaml"
}

target_url_from_app_yaml() {
  local repo_path="$1"
  local host
  local path

  host="$(app_yaml_value "$repo_path" "route.host")"
  path="$(app_yaml_value "$repo_path" "route.path")"

  [[ -n "$host" ]] || return 0

  if [[ -z "$path" || "$path" == "/" ]]; then
    printf 'https://%s' "$host"
  else
    printf 'https://%s/%s' "$host" "${path#/}"
  fi
}

print_argocd_live_updates() {
  local app_name="$1"
  local timeout_seconds="$2"
  local expected_image="${3:-}"
  local end_time
  local sync_status=""
  local health_status=""
  local revision=""
  local app_json=""

  [[ -n "$app_name" ]] || return 0

  if command -v kubectl >/dev/null 2>&1 \
    && kubectl get application "$app_name" -n argocd >/dev/null 2>&1; then
    printf '\nArgoCD live status:\n'
    end_time="$(($(date +%s) + timeout_seconds))"

    while [[ "$(date +%s)" -le "$end_time" ]]; do
      app_json="$(kubectl get application "$app_name" -n argocd -o json 2>/dev/null || true)"
      sync_status="$(
        kubectl get application "$app_name" -n argocd \
          -o jsonpath='{.status.sync.status}' 2>/dev/null || true
      )"
      health_status="$(
        kubectl get application "$app_name" -n argocd \
          -o jsonpath='{.status.health.status}' 2>/dev/null || true
      )"
      revision="$(
        kubectl get application "$app_name" -n argocd \
          -o jsonpath='{.status.sync.revision}' 2>/dev/null || true
      )"

      if [[ -n "$expected_image" ]] && printf '%s' "$app_json" | grep -Fq "$expected_image"; then
        printf '  ArgoCD app %s: sync=%s health=%s revision=%s image=%s\n' \
          "$app_name" \
          "${sync_status:-unknown}" \
          "${health_status:-unknown}" \
          "${revision:-unknown}" \
          "$expected_image"
      else
        printf '  ArgoCD app %s: sync=%s health=%s revision=%s image=%s\n' \
          "$app_name" \
          "${sync_status:-unknown}" \
          "${health_status:-unknown}" \
          "${revision:-unknown}" \
          "waiting"
      fi

      if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
        if [[ -z "$expected_image" ]] || printf '%s' "$app_json" | grep -Fq "$expected_image"; then
          return 0
        fi
      fi

      sleep 10
    done

    printf '  ArgoCD status watch timed out after %ss.\n' "$timeout_seconds"
    return 0
  fi

  if command -v argocd >/dev/null 2>&1; then
    printf '\nArgoCD live status:\n'
    argocd app wait "$app_name" --sync --health --timeout "$timeout_seconds" || true
    argocd app get "$app_name" || true
    return 0
  fi
}

print_kubernetes_live_updates() {
  local repo_path="$1"
  local release_tag="$2"
  local timeout_seconds="$3"
  local app_name
  local namespace
  local image_repo
  local expected_image
  local current_image=""
  local end_time

  command -v kubectl >/dev/null 2>&1 || {
    printf '\nLive deploy status:\n'
    printf '  kubectl is not installed; skipping cluster status.\n'
    return 0
  }

  app_name="$(app_yaml_value "$repo_path" "name")"
  namespace="$(app_yaml_value "$repo_path" "namespace")"
  image_repo="$(app_yaml_value "$repo_path" "image.repository")"
  namespace="${namespace:-apps}"

  [[ -n "$app_name" ]] || return 0

  if [[ -n "$image_repo" ]]; then
    expected_image="${image_repo}:${release_tag}"
  fi

  printf '\nKubernetes live status:\n'

  if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
    printf '  Namespace %s is not visible from the current kubeconfig.\n' "$namespace"
    return 0
  fi

  if [[ -n "${expected_image:-}" ]]; then
    printf '  Waiting for deployment/%s to use image %s...\n' "$app_name" "$expected_image"
    end_time="$(($(date +%s) + timeout_seconds))"

    while [[ "$(date +%s)" -le "$end_time" ]]; do
      current_image="$(
        kubectl get deployment "$app_name" -n "$namespace" \
          -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
      )"

      if [[ "$current_image" == "$expected_image" ]]; then
        printf '  Deployment image: %s\n' "$current_image"
        break
      fi

      printf '  Deployment image: %s\n' "${current_image:-not created yet}"
      sleep 10
    done
  fi

  printf '  Waiting for rollout...\n'
  kubectl rollout status "deployment/${app_name}" -n "$namespace" --timeout="${timeout_seconds}s" || true

  printf '\nKubernetes resources:\n'
  kubectl get deployment,service,ingress -n "$namespace" "$app_name" -o wide 2>/dev/null || true
  printf '\nPods:\n'
  kubectl get pods -n "$namespace" \
    -l "app.kubernetes.io/name=${app_name}" \
    -o wide 2>/dev/null || true
}

print_live_deploy_updates() {
  local repo_path="$1"
  local release_tag="$2"
  local timeout_seconds="${AUTO_APP_DEPLOY_LIVE_TIMEOUT:-$DEFAULT_LIVE_TIMEOUT_SECONDS}"
  local app_name
  local image_repo
  local expected_image=""

  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds="$DEFAULT_LIVE_TIMEOUT_SECONDS"

  if [[ "$timeout_seconds" -eq 0 ]]; then
    printf '\nLive deploy status skipped because AUTO_APP_DEPLOY_LIVE_TIMEOUT=0.\n'
    return 0
  fi

  app_name="$(app_yaml_value "$repo_path" "name")"
  image_repo="$(app_yaml_value "$repo_path" "image.repository")"
  if [[ -n "$image_repo" ]]; then
    expected_image="${image_repo}:${release_tag}"
  fi

  print_argocd_live_updates "$app_name" "$timeout_seconds" "$expected_image"
  print_kubernetes_live_updates "$repo_path" "$release_tag" "$timeout_seconds"
}

print_release_summary() {
  local repo_path="$1"
  local repo="$2"
  local release_tag="$3"
  local head_sha="$4"
  local run_id="$5"
  local watch_status="$6"
  local logs_status="$7"
  local run_url="https://github.com/${repo}/actions/runs/${run_id}"
  local app_name
  local image_repo
  local image_ref
  local target_url
  local access_enabled
  local branch
  local run_state
  local gitops_note

  app_name="$(app_yaml_value "$repo_path" "name")"
  image_repo="$(app_yaml_value "$repo_path" "image.repository")"
  target_url="$(target_url_from_app_yaml "$repo_path")"
  access_enabled="$(app_yaml_value "$repo_path" "access.enabled")"
  branch="$(git -C "$repo_path" branch --show-current)"
  run_state="$(
    gh run view "$run_id" \
      --repo "$repo" \
      --json status,conclusion \
      --jq 'if .conclusion == "" or .conclusion == null then .status else .conclusion end'
  )"

  if [[ -d "$DEFAULT_GITOPS_REPO_PATH/.git" ]]; then
    gitops_note="$(
      git -C "$DEFAULT_GITOPS_REPO_PATH" status --short --branch 2>/dev/null \
        | sed -n '1p'
    )"
  fi

  if [[ -n "$image_repo" ]]; then
    image_ref="${image_repo}:${release_tag}"
  fi

  printf '\nRelease summary:\n'
  printf '  Status:          %s\n' "$run_state"
  printf '  Version:         %s\n' "$release_tag"
  [[ -n "$app_name" ]] && printf '  App:             %s\n' "$app_name"
  printf '  GitHub repo:     %s\n' "$repo"
  printf '  Local repo:      %s\n' "$repo_path"
  [[ -n "$branch" ]] && printf '  Source branch:   %s\n' "$branch"
  printf '  Commit:          %s\n' "$head_sha"
  [[ -n "$image_ref" ]] && printf '  Container image: %s\n' "$image_ref"
  [[ -n "$target_url" ]] && printf '  Target URL:      %s\n' "$target_url"
  [[ -n "$access_enabled" ]] && printf '  Access enabled:  %s\n' "$access_enabled"
  printf '  Actions run:     %s\n' "$run_url"
  [[ -n "$gitops_note" ]] && printf '  GitOps checkout: %s\n' "$gitops_note"

  if [[ "$watch_status" -ne 0 ]]; then
    printf '  Note:            Pipeline finished with a non-success status.\n'
  elif [[ "$logs_status" -ne 0 ]]; then
    printf '  Note:            Pipeline succeeded, but log printing returned an error.\n'
  else
    printf '  Next:            ArgoCD should sync the updated GitOps app values.\n'
    if [[ "$gitops_note" == *"behind"* || "$gitops_note" == *"ahead"* ]]; then
      printf '  Local sync:      cd %s && git pull --rebase --tags origin main\n' "$DEFAULT_GITOPS_REPO_PATH"
    fi
  fi
}

main() {
  parse_args "$@"

  need_cmd git
  need_cmd gh
  need_cmd realpath
  need_cmd awk
  need_cmd sed
  need_cmd sort

  gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

  printf 'Release app repositories are usually under: %s\n' "$DEFAULT_PROJECTS_DIR"

  local repo_path_input
  local repo_path
  local repo
  local latest_tag
  local default_tag
  local release_tag
  local head_sha
  local run_id
  local watch_status
  local logs_status

  if [[ -n "$PROJECT_INPUT" ]]; then
    repo_path="$(resolve_project_repo_path "$PROJECT_INPUT")"
  else
    repo_path_input="$(select_repo_path)"
    repo_path="$(resolve_repo_path "$repo_path_input")"
  fi
  [[ -d "$repo_path" ]] || die "Repository path does not exist: $repo_path"
  repo_path="$(realpath "$repo_path")"
  [[ -d "$repo_path/.git" ]] || die "Not a git repository: $repo_path"

  repo="$(github_repo_from_origin "$repo_path" || true)"
  [[ -n "$repo" ]] || die "Could not detect a GitHub origin from $repo_path"

  printf 'GitHub repo: %s\n' "$repo"

  ensure_clean_worktree "$repo_path"
  git -C "$repo_path" fetch --tags origin >/dev/null 2>&1 || true

  latest_tag="$(latest_semver_tag "$repo_path" || true)"
  if [[ -n "$latest_tag" ]]; then
    printf 'Latest release tag: %s\n' "$latest_tag"
  else
    printf 'Latest release tag: none\n'
  fi

  default_tag="$(next_major_tag "$latest_tag")"
  release_tag="$(prompt 'Release tag' "$default_tag")"

  [[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Release tag must look like v1.0.0"

  if git -C "$repo_path" rev-parse -q --verify "refs/tags/$release_tag" >/dev/null; then
    die "Local tag already exists: $release_tag"
  fi

  if git -C "$repo_path" ls-remote --exit-code --tags origin "$release_tag" >/dev/null 2>&1; then
    die "Remote tag already exists: $release_tag"
  fi

  head_sha="$(git -C "$repo_path" rev-parse HEAD)"

  printf '\nRelease summary:\n'
  printf '  Repository: %s\n' "$repo_path"
  printf '  GitHub:     %s\n' "$repo"
  printf '  Commit:     %s\n' "$head_sha"
  printf '  Tag:        %s\n' "$release_tag"

  if ! prompt_yes_no 'Create and push this release tag?' 'y'; then
    die "Release cancelled."
  fi

  git -C "$repo_path" tag "$release_tag"
  git -C "$repo_path" push origin "$release_tag"

  run_id="$(wait_for_run "$repo" "$release_tag" "$head_sha")"
  printf 'GitHub Actions run: https://github.com/%s/actions/runs/%s\n' "$repo" "$run_id"

  printf '\nPipeline progress:\n'
  set +e
  gh run watch "$run_id" --repo "$repo" --exit-status
  watch_status="$?"
  set -e

  printf '\nPipeline steps:\n'
  print_run_steps "$repo" "$run_id"

  printf '\nPipeline logs:\n'
  set +e
  gh run view "$run_id" --repo "$repo" --log
  logs_status="$?"
  set -e

  if [[ "$watch_status" -eq 0 ]]; then
    print_live_deploy_updates "$repo_path" "$release_tag"
  fi

  print_release_summary "$repo_path" "$repo" "$release_tag" "$head_sha" "$run_id" "$watch_status" "$logs_status"

  if [[ "$logs_status" -ne 0 ]]; then
    return "$logs_status"
  fi
  return "$watch_status"
}

main "$@"
