#!/usr/bin/env bash
set -euo pipefail

KEEPASS_DB="${AUTO_APP_DEPLOY_KEEPASS_DB:-${HOME}/.config/auto-app-deploy/secrets.kdbx}"
KEEPASS_ENTRY="${AUTO_APP_DEPLOY_KEEPASS_ENTRY:-GITOPS_TOKEN}"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

yes_no() {
  local label="$1"
  local default="${2:-y}"
  local value

  read -r -p "$label [$default]: " value
  value="${value:-$default}"

  case "$value" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO) return 1 ;;
    *) die "Please answer y or n." ;;
  esac
}

print_token_instructions() {
  cat <<'EOF'

Create a GitHub fine-grained personal access token:

1. Open: https://github.com/settings/personal-access-tokens/new
2. Repository access: only Branchenprimus/auto-app-deploy
3. Repository permissions: Contents -> Write
4. Generate the token.
5. Re-run this script and paste the token when KeePassXC asks for the entry password.

EOF
}

entry_exists() {
  keepassxc-cli show "$KEEPASS_DB" "$KEEPASS_ENTRY" >/dev/null 2>&1
}

main() {
  need_cmd keepassxc-cli

  printf 'KeePassXC database: %s\n' "$KEEPASS_DB"
  printf 'KeePassXC entry:    %s\n' "$KEEPASS_ENTRY"

  if ! yes_no 'Do you already have the GitOps GitHub token?' 'y'; then
    print_token_instructions
    exit 0
  fi

  mkdir -p "$(dirname "$KEEPASS_DB")"

  if [[ ! -f "$KEEPASS_DB" ]]; then
    printf 'Creating KeePassXC database.\n'
    printf 'Enter a new database password when KeePassXC asks.\n'
    keepassxc-cli db-create -p "$KEEPASS_DB"
  fi

  printf 'Enter password to unlock %s when KeePassXC asks.\n' "$KEEPASS_DB"

  if entry_exists; then
    printf 'Entry exists. Updating token value.\n'
    printf 'Paste the GitOps token when KeePassXC asks for the entry password.\n'
    keepassxc-cli edit -p "$KEEPASS_DB" "$KEEPASS_ENTRY"
  else
    printf 'Creating entry %s.\n' "$KEEPASS_ENTRY"
    printf 'Paste the GitOps token when KeePassXC asks for the new entry password.\n'
    keepassxc-cli add -p "$KEEPASS_DB" "$KEEPASS_ENTRY"
  fi

  printf 'Verifying entry.\n'
  entry_exists || die "Could not verify KeePassXC entry: $KEEPASS_ENTRY"

  printf '\nSuccess. create-new-app.sh will use:\n'
  printf '  DB:    %s\n' "$KEEPASS_DB"
  printf '  Entry: %s\n' "$KEEPASS_ENTRY"
}

main "$@"
