#!/usr/bin/env bash
#
# deploy_to_cloud.sh
#
# Copies the setup scripts and config file needed to provision a Butler
# Postgres instance to a remote cloud instance via scp.
#
# Copies:
#   - scripts/setup_butler_postgres.sh
#   - scripts/setup_butler_backups.sh
#   - scripts/butler_pg_backup.sh
#   - scripts/test_butler_postgres.sh
#   - configs/uzh-butler-postgres-databases.conf
#   - configs/uzh-butler-postgres-pull-keys.conf
#
# USAGE:
#   ./deploy_to_cloud.sh <ssh-alias|hostname|IP> [remote_dir]
#
# remote_dir defaults to ~/butler-postgres-setup on the remote host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET="${1:?Usage: $0 <ssh-alias|hostname|IP> [remote_dir]}"
REMOTE_DIR="${2:-butler-postgres-setup}"

FILES=(
    "$SCRIPT_DIR/scripts/setup_butler_postgres.sh"
    "$SCRIPT_DIR/scripts/setup_butler_backups.sh"
    "$SCRIPT_DIR/scripts/butler_pg_backup.sh"
    "$SCRIPT_DIR/scripts/test_butler_postgres.sh"
    "$SCRIPT_DIR/configs/uzh-butler-postgres-databases.conf"
    "$SCRIPT_DIR/configs/uzh-butler-postgres-pull-keys.conf"
)

for f in "${FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: expected file not found: $f" >&2
        exit 1
    fi
done

ssh "$TARGET" "mkdir -p '$REMOTE_DIR'"

scp "${FILES[@]}" "$TARGET:$REMOTE_DIR/"

echo "Deployed to $TARGET:$REMOTE_DIR"
