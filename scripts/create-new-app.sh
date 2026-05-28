#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_OWNER="Branchenprimus"
DEFAULT_DOMAIN="darwin-labs.org"
DEFAULT_GITOPS_REPO="Branchenprimus/auto-app-deploy"
DEFAULT_GITOPS_BRANCH="main"
DEFAULT_KEEPASS_ENTRY="GITOPS_TOKEN"
DEFAULT_PROJECTS_DIR="/home/jan/projects"
DEFAULT_BOILERPLATE_PORT="8080"
DEFAULT_AGENT_INSTRUCTIONS_TEMPLATE="$PLATFORM_DIR/app-template/AGENT_INSTRUCTIONS.md"
ISSUE_PIPELINE_AUTOMATION_LABEL="codex-auto"
ISSUE_PIPELINE_RELEASE_LABEL="release"

# Adjust these defaults if your KeePassXC database or token entry lives elsewhere.
# If the database is missing, run: scripts/setup-gitops-token-store.sh
DEFAULT_KEEPASS_DB="${HOME}/.config/auto-app-deploy/secrets.kdbx"
DEFAULT_KEEPASS_KEY_FILE=""

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

  read -r -p "$label [y/n, default: $default]: " value
  value="${value:-$default}"

  case "$value" in
    y|Y|yes|YES|true|TRUE) return 0 ;;
    n|N|no|NO|false|FALSE) return 1 ;;
    *) die "Please answer yes or no for: $label" ;;
  esac
}

prompt_optional() {
  local label="$1"
  local value

  read -r -p "$label: " value
  printf '%s' "$value"
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

resolve_app_path() {
  local input="$1"

  if [[ "$input" = /* ]]; then
    printf '%s' "$input"
  else
    printf '%s/%s' "$DEFAULT_PROJECTS_DIR" "$input"
  fi
}

app_yaml_container_port() {
  local app_yaml="$1"

  [[ -f "$app_yaml" ]] || return 0

  awk -F ': *' '
    $1 == "container" {
      in_container = 1
      next
    }
    in_container && $0 !~ /^  / {
      in_container = 0
    }
    in_container && $1 == "  port" {
      print $2
      exit
    }
  ' "$app_yaml"
}

dockerfile_exposed_port() {
  local dockerfile="$1"

  [[ -f "$dockerfile" ]] || return 0

  awk '
    /^[[:space:]]*#/ {
      next
    }
    toupper($1) == "EXPOSE" {
      for (i = 2; i <= NF; i++) {
        port = $i
        sub(/\/.*/, "", port)
        if (port ~ /^[0-9]+$/) {
          print port
          exit
        }
      }
    }
  ' "$dockerfile"
}

dockerfile_env_port() {
  local dockerfile="$1"

  [[ -f "$dockerfile" ]] || return 0

  awk '
    /^[[:space:]]*#/ {
      next
    }
    toupper($1) == "ENV" {
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^PORT=[0-9]+$/) {
          sub(/^PORT=/, "", $i)
          print $i
          exit
        }
        if ($i == "PORT" && (i + 1) <= NF && $(i + 1) ~ /^[0-9]+$/) {
          print $(i + 1)
          exit
        }
      }
    }
  ' "$dockerfile"
}

detect_container_port_default() {
  local app_path="$1"
  local detected=""

  detected="$(app_yaml_container_port "$app_path/app.yaml")"
  if [[ -n "$detected" ]]; then
    printf '%s' "$detected"
    return
  fi

  detected="$(dockerfile_exposed_port "$app_path/Dockerfile")"
  if [[ -n "$detected" ]]; then
    printf '%s' "$detected"
    return
  fi

  detected="$(dockerfile_env_port "$app_path/Dockerfile")"
  if [[ -n "$detected" ]]; then
    printf '%s' "$detected"
    return
  fi

  printf '80'
}

write_boilerplate_dockerfile() {
  local target="$1"

  cat > "$target" <<EOF
FROM python:3.12-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \\
    PORT=${DEFAULT_BOILERPLATE_PORT}

RUN printf '%s\\n' \\
  '<!doctype html>' \\
  '<html lang="en">' \\
  '<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>New App</title></head>' \\
  '<body><main style="font-family: system-ui, sans-serif; max-width: 720px; margin: 4rem auto; padding: 0 1rem;">' \\
  '<h1>It works.</h1>' \\
  '<p>Replace this boilerplate with your app, then create a release tag.</p>' \\
  '</main></body>' \\
  '</html>' \\
  > index.html

EXPOSE ${DEFAULT_BOILERPLATE_PORT}

CMD ["sh", "-c", "python -m http.server \${PORT} --bind 0.0.0.0"]
EOF
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'
}

render_agent_instructions() {
  local target="$1"
  local template="${AGENT_INSTRUCTIONS_TEMPLATE:-$DEFAULT_AGENT_INSTRUCTIONS_TEMPLATE}"

  [[ -f "$template" ]] || die "Agent instructions template is missing: $template"

  sed \
    -e "s|{{APP_NAME}}|$(escape_sed_replacement "$APP_NAME")|g" \
    -e "s|{{CONTAINER_PORT}}|$(escape_sed_replacement "$CONTAINER_PORT")|g" \
    -e "s|{{PLATFORM_DIR}}|$(escape_sed_replacement "$PLATFORM_DIR")|g" \
    "$template" > "$target"
}

write_gitignore() {
  local target="$1"

  cat > "$target" <<'EOF'
# Local agent guidance
AGENT_INSTRUCTIONS.md

# Operating system files
.DS_Store
Thumbs.db

# Editor and IDE files
.idea/
.vscode/
*.swp
*.swo

# Environment and secrets
.env
.env.*
!.env.example
*.pem
*.key
*.crt
secrets/

# Python
__pycache__/
*.py[cod]
*.pyo
.python-version
.venv/
venv/
env/
.pytest_cache/
.mypy_cache/
.ruff_cache/
.coverage
htmlcov/

# JavaScript and frontend tooling
node_modules/
npm-debug.log*
yarn-debug.log*
yarn-error.log*
pnpm-debug.log*
dist/
build/
coverage/

# Logs and local runtime data
*.log
logs/
*.sqlite
*.sqlite3
*.db

# Docker and local build output
.docker/
tmp/
temp/
EOF
}

write_app_yaml() {
  local target="$1"

  cat > "$target" <<EOF
name: $APP_NAME

image:
  repository: ghcr.io/${OWNER_SLUG}/$IMAGE_REPO_NAME
  pullSecrets:$IMAGE_PULL_SECRETS_YAML

container:
  port: $CONTAINER_PORT

route:
  host: $HOSTNAME
  path: /

access:
  enabled: $ACCESS_ENABLED

resources:
  requests:
    cpu: 25m
    memory: 32Mi
  limits:
    cpu: 250m
    memory: 128Mi

env: []
EOF
}

copy_release_workflow() {
  local workflow_dir="$APP_PATH/.github/workflows"
  mkdir -p "$workflow_dir"
  cp "$PLATFORM_DIR/app-template/.github/workflows/release.yaml" "$workflow_dir/release.yaml"

  python3 - "$workflow_dir/release.yaml" "$DEFAULT_GITOPS_REPO" "$DEFAULT_GITOPS_BRANCH" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
gitops_repo = sys.argv[2]
gitops_branch = sys.argv[3]
text = path.read_text()
text = text.replace("GITOPS_REPO: Branchenprimus/auto-app-deploy", f"GITOPS_REPO: {gitops_repo}")
text = text.replace("GITOPS_BRANCH: main", f"GITOPS_BRANCH: {gitops_branch}")
path.write_text(text)
PY
}

get_keepass_password() {
  local db_path="$1"
  local entry="$2"
  local key_file="$3"

  [[ -f "$db_path" ]] || die "KeePassXC database not found: $db_path"

  local args=()
  if [[ -n "$key_file" ]]; then
    [[ -f "$key_file" ]] || die "KeePassXC key file not found: $key_file"
    args+=(--key-file "$key_file")
  fi

  keepassxc-cli show -s -a Password "${args[@]}" "$db_path" "$entry"
}

github_repo_from_origin() {
  local app_path="$1"
  local url
  local repo

  url="$(git -C "$app_path" remote get-url origin 2>/dev/null || true)"
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

ensure_repo() {
  local repo="$1"
  local visibility_flag="$2"
  local origin_url
  local origin_repo

  if gh repo view "$repo" >/dev/null 2>&1; then
    printf 'GitHub repo already exists: %s\n' "$repo"
  else
    gh repo create "$repo" "$visibility_flag"
  fi

  origin_url="$(git -C "$APP_PATH" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$origin_url" ]]; then
    printf 'Git remote origin already exists: %s\n' "$origin_url"

    origin_repo="$(github_repo_from_origin "$APP_PATH" || true)"
    if [[ -n "$origin_repo" && "$origin_repo" != "$repo" ]]; then
      printf 'Origin points to GitHub repo: %s\n' "$origin_repo"
      printf 'Selected GitHub repo:        %s\n' "$repo"
      if prompt_yes_no 'Update origin to selected repo?' 'n'; then
        git -C "$APP_PATH" remote set-url origin "git@github.com:${repo}.git"
      else
        die "Existing origin does not match selected repo."
      fi
    fi
  else
    git -C "$APP_PATH" remote add origin "git@github.com:${repo}.git"
  fi
}

ensure_repo_label() {
  local repo="$1"
  local name="$2"
  local color="$3"
  local description="$4"

  if gh label view "$name" --repo "$repo" >/dev/null 2>&1; then
    gh label edit "$name" --repo "$repo" --color "$color" --description "$description"
    printf 'Updated GitHub label on %s: %s\n' "$repo" "$name"
  else
    gh label create "$name" --repo "$repo" --color "$color" --description "$description"
    printf 'Created GitHub label on %s: %s\n' "$repo" "$name"
  fi
}

ensure_issue_pipeline_labels() {
  local repo="$1"

  ensure_repo_label \
    "$repo" \
    "$ISSUE_PIPELINE_AUTOMATION_LABEL" \
    "5319e7" \
    "Run the GitHub issue Codex automation pipeline"
  ensure_repo_label \
    "$repo" \
    "$ISSUE_PIPELINE_RELEASE_LABEL" \
    "0e8a16" \
    "Release bot-created issue pipeline changes"
}

push_current_branch() {
  local branch
  branch="$(git -C "$APP_PATH" branch --show-current)"

  if [[ -z "$branch" ]]; then
    branch="main"
    git -C "$APP_PATH" checkout -b "$branch"
  fi

  git -C "$APP_PATH" push -u origin "$branch"
}

main() {
  need_cmd git
  need_cmd gh
  need_cmd keepassxc-cli
  need_cmd python3
  need_cmd realpath

  gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

  printf 'New local apps are created under: %s\n' "$DEFAULT_PROJECTS_DIR"
  printf 'Enter a directory name like "my-app" or an absolute path.\n'
  APP_PATH_INPUT="$(prompt 'Local app path')"
  APP_PATH="$(resolve_app_path "$APP_PATH_INPUT")"
  APP_DIR_CREATED="false"

  if [[ -d "$APP_PATH" ]]; then
    printf 'Using existing app directory: %s\n' "$APP_PATH"
    if [[ -z "$(find "$APP_PATH" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      APP_DIR_CREATED="true"
      printf 'Existing app directory is empty; treating it as a new app scaffold.\n'
    fi
  else
    printf 'App directory does not exist: %s\n' "$APP_PATH"
    if prompt_yes_no 'Create it as a new app directory?' 'y'; then
      mkdir -p "$APP_PATH"
      APP_DIR_CREATED="true"
      printf 'Created app directory: %s\n' "$APP_PATH"
    else
      die "Directory does not exist: $APP_PATH"
    fi
  fi

  APP_PATH="$(realpath "$APP_PATH")"

  local detected_name
  local detected_repo
  local owner_default
  local repo_default
  local container_port_default
  detected_name="$(slugify "$(basename "$APP_PATH")")"
  owner_default="$DEFAULT_OWNER"
  repo_default="$detected_name"

  detected_repo="$(github_repo_from_origin "$APP_PATH" || true)"
  if [[ -n "$detected_repo" ]]; then
    owner_default="${detected_repo%%/*}"
    repo_default="${detected_repo#*/}"
    printf 'Detected existing GitHub origin: %s\n' "$detected_repo"
  fi

  OWNER="$(prompt 'GitHub owner/user' "$owner_default")"
  OWNER_SLUG="$(slugify "$OWNER")"
  REPO_NAME="$(prompt 'GitHub repo name' "$repo_default")"
  IMAGE_REPO_NAME="$(slugify "$REPO_NAME")"
  APP_NAME="$(prompt 'App name' "$(slugify "$REPO_NAME")")"
  HOSTNAME="$(prompt 'App hostname' "${APP_NAME}.${DEFAULT_DOMAIN}")"

  if [[ ! -f "$APP_PATH/Dockerfile" ]]; then
    write_boilerplate_dockerfile "$APP_PATH/Dockerfile"
    printf 'Created boilerplate Dockerfile: %s\n' "$APP_PATH/Dockerfile"
  fi

  container_port_default="$(detect_container_port_default "$APP_PATH")"
  if [[ "$APP_DIR_CREATED" == "true" ]]; then
    CONTAINER_PORT="$container_port_default"
    printf 'Container HTTP port: %s\n' "$CONTAINER_PORT"
  else
    CONTAINER_PORT="$(prompt 'Container HTTP port' "$container_port_default")"
  fi
  [[ "$CONTAINER_PORT" =~ ^[0-9]+$ ]] || die "Container HTTP port must be numeric."
  ACCESS_ENABLED="true"
  if ! prompt_yes_no 'Protect with Cloudflare Access?' 'y'; then
    ACCESS_ENABLED="false"
  fi

  local visibility
  visibility="$(prompt 'GitHub repo visibility: private/public' 'private')"
  case "$visibility" in
    private)
      VISIBILITY_FLAG="--private"
      IMAGE_PULL_SECRETS_YAML=$'\n    - name: ghcr-pull'
      ;;
    public)
      VISIBILITY_FLAG="--public"
      IMAGE_PULL_SECRETS_YAML=" []"
      ;;
    *) die "Unsupported visibility: $visibility" ;;
  esac

  KEEPASS_DB="${AUTO_APP_DEPLOY_KEEPASS_DB:-$DEFAULT_KEEPASS_DB}"
  KEEPASS_ENTRY="${AUTO_APP_DEPLOY_KEEPASS_ENTRY:-$DEFAULT_KEEPASS_ENTRY}"
  KEEPASS_KEY_FILE="${AUTO_APP_DEPLOY_KEEPASS_KEY_FILE:-$DEFAULT_KEEPASS_KEY_FILE}"

  printf 'Using KeePassXC database: %s\n' "$KEEPASS_DB"
  printf 'Using KeePassXC entry: %s\n' "$KEEPASS_ENTRY"
  if [[ ! -f "$KEEPASS_DB" ]]; then
    die "KeePassXC database is missing. Run: $PLATFORM_DIR/scripts/setup-gitops-token-store.sh"
  fi

  local app_yaml="$APP_PATH/app.yaml"
  if [[ -f "$app_yaml" ]]; then
    if prompt_yes_no 'app.yaml exists. Overwrite?' 'n'; then
      write_app_yaml "$app_yaml"
    fi
  else
    write_app_yaml "$app_yaml"
  fi

  local agent_instructions="$APP_PATH/AGENT_INSTRUCTIONS.md"
  if [[ -f "$agent_instructions" ]]; then
    printf 'AGENT_INSTRUCTIONS.md already exists.\n'
  else
    render_agent_instructions "$agent_instructions"
    printf 'Created agent instructions: %s\n' "$agent_instructions"
  fi

  local gitignore="$APP_PATH/.gitignore"
  if [[ -f "$gitignore" ]]; then
    printf '.gitignore already exists.\n'
  else
    write_gitignore "$gitignore"
    printf 'Created git ignore file: %s\n' "$gitignore"
  fi

  copy_release_workflow

  if [[ ! -d "$APP_PATH/.git" ]]; then
    git -C "$APP_PATH" init
  fi

  git -C "$APP_PATH" add app.yaml .gitignore .github/workflows/release.yaml
  if [[ -f "$APP_PATH/Dockerfile" ]]; then
    git -C "$APP_PATH" add Dockerfile
  fi
  if ! git -C "$APP_PATH" diff --cached --quiet; then
    git -C "$APP_PATH" commit -m "Add container release workflow"
  else
    printf 'No staged changes to commit.\n'
  fi

  local repo="${OWNER}/${REPO_NAME}"
  ensure_repo "$repo" "$VISIBILITY_FLAG"
  ensure_issue_pipeline_labels "$repo"

  printf 'Reading GITOPS_TOKEN from KeePassXC entry: %s\n' "$KEEPASS_ENTRY"
  printf 'KeePassXC may ask for the database password now.\n'
  local gitops_token
  if ! gitops_token="$(get_keepass_password "$KEEPASS_DB" "$KEEPASS_ENTRY" "$KEEPASS_KEY_FILE")"; then
    die "Could not read KeePassXC entry '$KEEPASS_ENTRY'. Run: $PLATFORM_DIR/scripts/setup-gitops-token-store.sh"
  fi
  [[ -n "$gitops_token" ]] || die "KeePassXC entry returned an empty password."

  printf 'Setting GitHub Actions secret GITOPS_TOKEN on %s.\n' "$repo"
  printf '%s' "$gitops_token" | gh secret set GITOPS_TOKEN --repo "$repo"
  unset gitops_token

  if prompt_yes_no 'Push current branch now?' 'y'; then
    push_current_branch
  fi

  printf '\nNext release:\n'
  printf '  cd %q\n' "$APP_PATH"
  printf '  git tag v0.1.0\n'
  printf '  git push origin v0.1.0\n'
  printf '\nWatch:\n'
  printf '  gh run list --repo %q --limit 3\n' "$repo"
}

main "$@"
