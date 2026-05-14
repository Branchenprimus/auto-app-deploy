#!/usr/bin/env bash
set -euo pipefail

DEFAULT_PROJECTS_DIR="/home/jan/projects"

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

  read -r -p "$label [$default]: " value
  value="${value:-$default}"

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

  if [[ "$watch_status" -ne 0 ]]; then
    printf '  Note:            Pipeline finished with a non-success status.\n'
  elif [[ "$logs_status" -ne 0 ]]; then
    printf '  Note:            Pipeline succeeded, but log printing returned an error.\n'
  else
    printf '  Next:            ArgoCD should sync the updated GitOps app values.\n'
  fi
}

main() {
  need_cmd git
  need_cmd gh
  need_cmd realpath
  need_cmd awk
  need_cmd sed
  need_cmd sort

  gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

  printf 'Release app repositories are usually under: %s\n' "$DEFAULT_PROJECTS_DIR"
  printf 'Enter a directory name like "Flashcards" or an absolute path.\n'

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

  repo_path_input="$(prompt 'Local repo path')"
  repo_path="$(resolve_repo_path "$repo_path_input")"
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

  print_release_summary "$repo_path" "$repo" "$release_tag" "$head_sha" "$run_id" "$watch_status" "$logs_status"

  if [[ "$logs_status" -ne 0 ]]; then
    return "$logs_status"
  fi
  return "$watch_status"
}

main "$@"
