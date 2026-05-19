#!/usr/bin/env bash

set -euo pipefail

APPS_DIR="/home/jan/projects/auto-app-deploy/apps"
PROJECTS_DIR="/home/jan/projects"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

ensure_gitignore_entry() {
  local repo_path="$1"
  local gitignore_file="$repo_path/.gitignore"

  touch "$gitignore_file"

  if ! grep -qxF 'issues/' "$gitignore_file"; then
    printf '\nissues/\n' >> "$gitignore_file"
  fi
}

normalize_repo_url() {
  local url="${1%.git}"

  if [[ "$url" =~ ^git@github\.com:(.+/.+)$ ]]; then
    printf 'https://github.com/%s\n' "${BASH_REMATCH[1],,}"
    return
  fi

  if [[ "$url" =~ ^https://github\.com/(.+/.+)$ ]]; then
    printf 'https://github.com/%s\n' "${BASH_REMATCH[1],,}"
    return
  fi

  if [[ "$url" =~ ^ssh://git@github\.com/(.+/.+)$ ]]; then
    printf 'https://github.com/%s\n' "${BASH_REMATCH[1],,}"
    return
  fi

  printf '%s\n' "$url"
}

repo_slug_from_url() {
  local normalized
  normalized="$(normalize_repo_url "$1")"

  if [[ "$normalized" =~ ^https://github\.com/([^/]+/[^/]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi

  return 1
}

require_command git
require_command gh

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

declare -A REPO_PATHS=()

while IFS=$'\t' read -r repo_path remote_url; do
  [[ -n "$repo_path" && -n "$remote_url" ]] || continue
  REPO_PATHS["$(normalize_repo_url "$remote_url")"]="$repo_path"
done < <(
  while IFS= read -r git_dir; do
    repo_path="${git_dir%/.git}"
    remote_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)"
    [[ -n "$remote_url" ]] && printf '%s\t%s\n' "$repo_path" "$remote_url"
  done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -type d -name .git | sort)
)

mapped_count=0
skipped_count=0

printf '%-42s %12s %13s %14s\n' "Repo" "Open issues" "Closed issues" "Pulled issues"
printf '%-42s %12s %13s %14s\n' "----" "-----------" "-------------" "-------------"

while IFS=$'\t' read -r app_slug github_url; do
  [[ -n "$app_slug" && -n "$github_url" ]] || continue

  normalized_url="$(normalize_repo_url "$github_url")"
  repo_path="${REPO_PATHS[$normalized_url]:-}"

  if [[ -z "$repo_path" ]]; then
    echo "Skipping $app_slug: no local repo found for $normalized_url" >&2
    ((skipped_count += 1))
    continue
  fi

  repo_slug="$(repo_slug_from_url "$github_url")"
  issues_dir="$repo_path/issues"
  output_file="$issues_dir/open_issues.json"

  ensure_gitignore_entry "$repo_path"
  mkdir -p "$issues_dir"

  gh issue list \
    --repo "$repo_slug" \
    --state open \
    --limit 200 \
    --json number,state,labels,title,body \
    > "$output_file"

  issue_count="$(
    gh issue list \
      --repo "$repo_slug" \
      --state open \
      --limit 200 \
      --json number \
      --template '{{len .}}'
  )"
  closed_issue_count="$(
    gh issue list \
      --repo "$repo_slug" \
      --state closed \
      --limit 200 \
      --json number \
      --template '{{len .}}'
  )"

  printf '%-42s %12s %13s %14s\n' "$repo_slug" "$issue_count" "$closed_issue_count" "$issue_count"
  ((mapped_count += 1))
done < <(
  python3 - "$APPS_DIR" <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Missing required Python package: PyYAML", file=sys.stderr)
    sys.exit(1)

apps_dir = Path(sys.argv[1])

seen = set()
for app_file in sorted(apps_dir.glob("*.yaml")):
    app_metadata = yaml.safe_load(app_file.read_text()) or {}
    app_slug = app_metadata.get("name") or app_file.stem
    github = app_metadata.get("github")

    if not github:
        source = app_metadata.get("source") or {}
        github = source.get("repository")

    if not github:
        image = app_metadata.get("image") or {}
        repository = image.get("repository", "")
        if repository.startswith("ghcr.io/"):
            owner_repo = repository.removeprefix("ghcr.io/")
            if owner_repo.count("/") == 1:
                github = f"https://github.com/{owner_repo}"

    if not github:
        print(f"Skipping {app_slug}: no github/source.repository/image.repository", file=sys.stderr)
        continue

    normalized = github.removesuffix(".git").lower()
    if normalized in seen:
        continue
    seen.add(normalized)
    print(f"{app_slug}\t{github}")
PY
)

echo "Processed $mapped_count repos; skipped $skipped_count entries."
