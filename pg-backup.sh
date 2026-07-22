#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Takes a hot (online) backup of the running Postgres cluster via
# pg_basebackup: the server keeps running and accepting writes the whole
# time. Internally this is exactly pg_backup_start() (forces a checkpoint)
# + copy the files + pg_backup_stop(), which pg_basebackup wraps and does
# correctly (including embedding the WAL needed to make the backup
# consistent on restore).
#
# Usage: ./pg_backup [name]   (name defaults to the current timestamp)
# Output: backups-pg/<name>.tz (a single gzip'd tar file)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

BACKUP_NAME="${1:-$(date +%Y%m%d_%H%M%S)}"
case "$BACKUP_NAME" in
  */*) echo "ERROR: backup name must not contain '/'" >&2; exit 1 ;;
esac

BACKUP_DIR="backups-pg"
BACKUP_FILE="$BACKUP_DIR/${BACKUP_NAME}.tz"
mkdir -p "$BACKUP_DIR"

if [ -e "$BACKUP_FILE" ]; then
  echo "ERROR: $BACKUP_FILE already exists" >&2
  exit 1
fi

PG_USER="$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2-)"

# Remove a partial file if pg_basebackup fails partway through, so a
# broken backup never sits there looking like a valid one.
trap 'rm -f "$BACKUP_FILE"' ERR

echo "==> Taking hot backup '$BACKUP_NAME' (Postgres keeps running throughout)"
docker compose --ansi never exec -T postgres \
  pg_basebackup -U "$PG_USER" -D - -Ft -X fetch --checkpoint=fast -z \
  > "$BACKUP_FILE"

echo "==> Done: $BACKUP_FILE"
