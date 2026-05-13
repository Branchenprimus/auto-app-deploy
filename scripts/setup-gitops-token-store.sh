#!/usr/bin/env bash
set -euo pipefail

DEFAULT_DB_PATH="/home/jan/.config/auto-app-deploy/secrets.kdbx"
ENTRY_NAME="GITOPS_TOKEN"

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: Missing required command: $cmd" >&2
    echo "Install it with: sudo apt-get install -y keepassxc" >&2
    exit 1
  fi
}

read_secret() {
  local prompt="$1"
  local value=""

  printf "%s" "$prompt" >&2
  IFS= read -r -s value
  printf "\n" >&2

  printf "%s" "$value"
}

require_command keepassxc-cli

echo "KeePassXC token store setup"
echo

read -r -p "KeePassXC database path [${DEFAULT_DB_PATH}]: " DB_PATH
DB_PATH="${DB_PATH:-$DEFAULT_DB_PATH}"

echo
echo "KeePassXC database: ${DB_PATH}"
echo "KeePassXC entry:    ${ENTRY_NAME}"
echo

read -r -p "Do you already have the GitOps GitHub token? [y]: " HAVE_TOKEN
HAVE_TOKEN="${HAVE_TOKEN:-y}"

case "$HAVE_TOKEN" in
  y|Y|yes|YES|Yes)
    ;;
  *)
    echo "Create a GitHub token first, then run this script again."
    exit 1
    ;;
esac

mkdir -p "$(dirname "$DB_PATH")"

DB_EXISTS="true"
if [ ! -f "$DB_PATH" ]; then
  DB_EXISTS="false"
  echo
  echo "KeePassXC database does not exist yet:"
  echo "$DB_PATH"
  echo
  echo "Creating new KeePassXC database."
  DB_PASSWORD="$(read_secret "Enter new password for ${DB_PATH}: ")"
  DB_PASSWORD_CONFIRM="$(read_secret "Confirm new password for ${DB_PATH}: ")"

  if [ "$DB_PASSWORD" != "$DB_PASSWORD_CONFIRM" ]; then
    echo "Error: Passwords do not match." >&2
    exit 1
  fi

  printf "%s\n%s\n" "$DB_PASSWORD" "$DB_PASSWORD_CONFIRM" \
    | keepassxc-cli db-create --set-password "$DB_PATH" >/dev/null

  echo "Created KeePassXC database."
else
  DB_PASSWORD="$(read_secret "Enter password to unlock ${DB_PATH}: ")"
fi

if [ "$DB_EXISTS" = "true" ]; then
  if ! printf "%s\n" "$DB_PASSWORD" | keepassxc-cli ls "$DB_PATH" >/dev/null 2>&1; then
    echo "Error: Could not unlock KeePassXC database." >&2
    exit 1
  fi
fi

echo

if printf "%s\n" "$DB_PASSWORD" | keepassxc-cli show "$DB_PATH" "$ENTRY_NAME" >/dev/null 2>&1; then
  echo "Entry exists. Updating token value."
  NEW_VALUE="$(read_secret "Enter new entry value: ")"

  printf "%s\n%s\n" "$DB_PASSWORD" "$NEW_VALUE" \
    | keepassxc-cli edit --password-prompt "$DB_PATH" "$ENTRY_NAME" >/dev/null

  echo "Successfully edited entry ${ENTRY_NAME}."
else
  echo "Entry does not exist. Creating entry."
  NEW_VALUE="$(read_secret "Enter new entry value: ")"

  printf "%s\n%s\n" "$DB_PASSWORD" "$NEW_VALUE" \
    | keepassxc-cli add --password-prompt --username "$ENTRY_NAME" "$DB_PATH" "$ENTRY_NAME" >/dev/null

  echo "Successfully created entry ${ENTRY_NAME}."
fi

echo "Verifying entry."

if printf "%s\n" "$DB_PASSWORD" | keepassxc-cli show "$DB_PATH" "$ENTRY_NAME" >/dev/null 2>&1; then
  echo "Verification successful."
else
  echo "Error: Verification failed." >&2
  exit 1
fi
