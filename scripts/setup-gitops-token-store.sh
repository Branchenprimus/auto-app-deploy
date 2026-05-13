#!/usr/bin/env bash
set -euo pipefail

DEFAULT_KEEPASS_DB="${HOME}/.config/auto-app-deploy/secrets.kdbx"
DEFAULT_KEEPASS_ENTRY="GitHub/GITOPS_TOKEN"

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

main() {
  need_cmd keepassxc-cli

  local db_path
  local entry
  local group

  db_path="$(prompt 'KeePassXC database path' "$DEFAULT_KEEPASS_DB")"
  entry="$(prompt 'KeePassXC entry for GITOPS_TOKEN' "$DEFAULT_KEEPASS_ENTRY")"
  group="${entry%/*}"

  mkdir -p "$(dirname "$db_path")"

  if [[ ! -f "$db_path" ]]; then
    printf 'Creating KeePassXC database: %s\n' "$db_path"
    printf 'KeePassXC will ask for a new database password.\n'
    keepassxc-cli db-create -p "$db_path"
  else
    printf 'Using existing KeePassXC database: %s\n' "$db_path"
  fi

  if [[ "$group" != "$entry" ]]; then
    printf 'Ensuring KeePassXC group exists: %s\n' "$group"
    keepassxc-cli mkdir "$db_path" "$group" >/dev/null 2>&1 || true
  fi

  if keepassxc-cli show -q "$db_path" "$entry" >/dev/null 2>&1; then
    if prompt_yes_no 'Entry exists. Replace its password/token?' 'y'; then
      printf 'KeePassXC will ask for the database password and then the GitOps token.\n'
      keepassxc-cli edit -p "$db_path" "$entry"
    fi
  else
    printf 'Adding KeePassXC entry: %s\n' "$entry"
    printf 'KeePassXC will ask for the database password and then the GitOps token.\n'
    keepassxc-cli add -p "$db_path" "$entry"
  fi

  printf '\nDone. create-new-app.sh will use:\n'
  printf '  DB:    %s\n' "$db_path"
  printf '  Entry: %s\n' "$entry"
}

main "$@"
