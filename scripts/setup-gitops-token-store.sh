#!/usr/bin/env bash
set -euo pipefail

DEFAULT_KEEPASS_DB="${HOME}/.config/auto-app-deploy/secrets.kdbx"
DEFAULT_KEEPASS_ENTRY="GITOPS_TOKEN"

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

entry_exists() {
  local db_path="$1"
  local title="$2"

  keepassxc-cli show "$db_path" "$title" >/dev/null 2>&1
}

print_token_instructions() {
  cat <<'EOF'

Create a GitHub fine-grained personal access token:

1. Open: https://github.com/settings/personal-access-tokens/new
2. Repository access: only Branchenprimus/auto-app-deploy
3. Repository permissions: Contents -> Write
4. Generate the token.
5. Re-run this script and paste the token only when KeePassXC asks for the entry password/token.

EOF
}

main() {
  need_cmd keepassxc-cli

  local db_path
  local entry

  db_path="$(prompt 'KeePassXC database path' "$DEFAULT_KEEPASS_DB")"
  entry="${AUTO_APP_DEPLOY_KEEPASS_ENTRY:-$DEFAULT_KEEPASS_ENTRY}"

  printf 'KeePassXC entry for GITOPS_TOKEN: %s\n' "$entry"

  if ! prompt_yes_no 'Do you already have the GitOps GitHub token?' 'y'; then
    print_token_instructions
    exit 0
  fi

  printf 'Process:\n'
  printf '1. Unlock the KeePassXC database when asked.\n'
  printf '2. Paste the GitOps token when KeePassXC asks for the new entry password.\n'

  mkdir -p "$(dirname "$db_path")"

  if [[ ! -f "$db_path" ]]; then
    printf 'Creating KeePassXC database: %s\n' "$db_path"
    printf 'KeePassXC will ask for a new database password.\n'
    keepassxc-cli db-create -p "$db_path"
  else
    printf 'Using existing KeePassXC database: %s\n' "$db_path"
  fi

  if entry_exists "$db_path" "$entry"; then
    if prompt_yes_no 'Entry exists. Replace its password/token?' 'y'; then
      printf 'KeePassXC will ask for the database password and then the GitOps token as the entry password.\n'
      keepassxc-cli edit -p "$db_path" "$entry"
    fi
  else
    printf 'Adding KeePassXC entry: %s\n' "$entry"
    printf 'KeePassXC will ask for the database password and then the GitOps token as the entry password.\n'
    keepassxc-cli add -p "$db_path" "$entry"
  fi

  printf 'Verifying KeePassXC entry exists: %s\n' "$entry"
  if ! entry_exists "$db_path" "$entry"; then
    die "Could not verify KeePassXC entry. Open the database and ensure the entry path is exactly: $entry"
  fi

  printf '\nDone. create-new-app.sh will use:\n'
  printf '  DB:    %s\n' "$db_path"
  printf '  Entry: %s\n' "$entry"
}

main "$@"
