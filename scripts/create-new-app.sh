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
ISSUE_PIPELINE_AUTOMATION_LABEL="agent-auto"
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

_is_secret_var() {
  local key="$1"
  local val="$2"
  if printf '%s' "$key" | grep -qiE '(SECRET|PASSWORD|TOKEN|CLIENT_ID|CLIENT_SECRET|CREDENTIAL|API_KEY|PRIVATE_KEY)'; then
    return 0
  fi
  if printf '%s' "$val" | grep -qiE '^(your_|replace.with|change.?me|<[A-Z]|TODO|changeme|placeholder)'; then
    return 0
  fi
  return 1
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

detect_compose_volume_mount() {
  local compose_file="$1"
  [[ -f "$compose_file" ]] || return 0

  awk '
    /- [A-Za-z_][A-Za-z0-9_]*:\// {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[A-Za-z_][A-Za-z0-9_]*:\//) {
          n = split($i, p, ":")
          if (n >= 2 && p[2] ~ /^\//) { print p[2]; exit }
        }
      }
    }
  ' "$compose_file"
}

detect_persistence_mount() {
  local app_path="$1"
  local compose_file mount

  for compose_file in "$app_path/docker-compose.yml" "$app_path/docker-compose.yaml"; do
    mount="$(detect_compose_volume_mount "$compose_file")"
    if [[ -n "$mount" ]]; then
      printf '%s' "$mount"
      return
    fi
  done

  if [[ -f "$app_path/Dockerfile" ]]; then
    mount="$(awk 'toupper($1)=="VOLUME" { val=$2; gsub(/["\\[\\]]/, "", val); if (val ~ /^\//) { print val; exit } }' "$app_path/Dockerfile" 2>/dev/null || true)"
    [[ -n "$mount" ]] && printf '%s' "$mount"
  fi
}

build_env_yaml() {
  local env_file="$1"
  local secret_name="$2"
  local result="" key val

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    [[ "$key" == "PORT" || "$key" == "APP_PORT" || "$key" == "HOST_PORT" ]] && continue
    [[ -z "$val" ]] && continue

    if _is_secret_var "$key" "$val"; then
      result+="  - name: ${key}"$'\n'
      result+="    valueFrom:"$'\n'
      result+="      secretKeyRef:"$'\n'
      result+="        name: ${secret_name}"$'\n'
      result+="        key: ${key}"$'\n'
    else
      result+="  - name: ${key}"$'\n'
      result+="    value: \"$(printf '%s' "$val" | sed 's/"/\\"/g')\""$'\n'
    fi
  done < "$env_file"

  printf '%s' "$result"
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
  local env_section

  if [[ -n "${APP_ENV_YAML:-}" ]]; then
    env_section="env:"$'\n'"${APP_ENV_YAML%$'\n'}"
  else
    env_section="env: []"
  fi

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

$env_section
EOF

  if [[ "${PERSISTENCE_ENABLED:-false}" == "true" ]]; then
    cat >> "$target" <<EOF
persistence:
  enabled: true
  mountPath: $PERSISTENCE_MOUNT_PATH
  size: ${PERSISTENCE_SIZE:-2Gi}
  storageClassName: ${PERSISTENCE_STORAGE_CLASS:-local-path}
EOF
  fi
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
    "Run the GitHub issue agent automation pipeline"
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

add_to_homepage() {
  local homepage_yaml="$PLATFORM_DIR/platform/homepage.yaml"
  [[ -f "$homepage_yaml" ]] || { printf 'Homepage config not found, skipping.\n'; return; }

  local display_name description icon
  display_name="$(prompt 'App display name on homepage' "$APP_NAME")"
  description="$(prompt_optional 'Short description')"
  icon="$(prompt 'Icon (mdi-* or filename.png)' 'mdi-application')"

  python3 - "$homepage_yaml" "$display_name" "https://$HOSTNAME" "$description" "$icon" <<'PY'
import sys
from pathlib import Path

path, name, href, description, icon = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
marker = "    - Platform:"
entry = (
    f"        - {name}:\n"
    f"            href: {href}\n"
    f"            siteMonitor: {href}\n"
    f"            description: {description}\n"
    f"            icon: {icon}\n"
)
content = path.read_text()
if marker not in content:
    print(f"Could not find '{marker}' in homepage config.", file=sys.stderr)
    sys.exit(1)
if href in content:
    print(f"'{name}' already present in homepage config, skipping.")
    sys.exit(0)
path.write_text(content.replace(marker, entry + marker, 1))
print(f"Added '{name}' to homepage.")
PY

  git -C "$PLATFORM_DIR" add platform/homepage.yaml
  if ! git -C "$PLATFORM_DIR" diff --cached --quiet; then
    git -C "$PLATFORM_DIR" commit -m "Add $APP_NAME to homepage"
    git -C "$PLATFORM_DIR" push origin main
    printf 'Homepage updated.\n'
  else
    printf 'No homepage changes to commit.\n'
  fi
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

  PERSISTENCE_ENABLED="false"
  PERSISTENCE_MOUNT_PATH=""
  PERSISTENCE_SIZE="2Gi"
  PERSISTENCE_STORAGE_CLASS="local-path"

  local detected_mount
  detected_mount="$(detect_persistence_mount "$APP_PATH")"
  if [[ -n "$detected_mount" ]]; then
    printf 'Detected volume mount: %s\n' "$detected_mount"
    if prompt_yes_no 'Enable persistence (PVC) for this mount?' 'y'; then
      PERSISTENCE_ENABLED="true"
      PERSISTENCE_MOUNT_PATH="$(prompt 'Mount path' "$detected_mount")"
      PERSISTENCE_SIZE="$(prompt 'Storage size' '2Gi')"
      PERSISTENCE_STORAGE_CLASS="$(prompt 'Storage class' 'local-path')"
    fi
  fi

  APP_ENV_YAML=""
  local env_example="$APP_PATH/.env.example"
  if [[ -f "$env_example" ]]; then
    printf 'Found .env.example — scanning env vars...\n'
    if prompt_yes_no 'Include env vars from .env.example in app.yaml?' 'y'; then
      local secret_name
      secret_name="$(slugify "$APP_NAME")-secret"
      APP_ENV_YAML="$(build_env_yaml "$env_example" "$secret_name")"
      if [[ -n "$APP_ENV_YAML" ]]; then
        printf 'Secrets will reference k8s secret "%s" via secretKeyRef.\n' "$secret_name"
        printf 'Create it manually on the cluster before first deploy:\n'
        printf '  kubectl create secret generic %s -n apps \\\n' "$secret_name"
        printf '    --from-literal=KEY=value ...\n'
      fi
    fi
  fi

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

  if prompt_yes_no 'Add this app to the homepage?' 'y'; then
    add_to_homepage
  fi

  printf '\nNext release:\n'
  printf '  cd %q\n' "$APP_PATH"
  printf '  git tag v0.1.0\n'
  printf '  git push origin v0.1.0\n'
  printf '\nWatch:\n'
  printf '  gh run list --repo %q --limit 3\n' "$repo"
}

main "$@"
