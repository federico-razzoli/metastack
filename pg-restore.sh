#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Restores a backup taken by ./pg_backup. This is destructive: it stops
# Postgres, wipes the current postgres_data contents, extracts the backup
# in their place, then starts Postgres back up (it replays WAL on startup
# to reach a consistent state, same as crash recovery).
#
# Usage: ./pg_restore [name]   (name defaults to the most recent backup)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

BACKUP_DIR="backups"

if [ -n "${1:-}" ]; then
  BACKUP_NAME="$1"
  BACKUP_FILE="$BACKUP_DIR/${BACKUP_NAME}.tz"
  if [ ! -f "$BACKUP_FILE" ]; then
    echo "ERROR: $BACKUP_FILE not found" >&2
    exit 1
  fi
else
  BACKUP_FILE="$(ls -1t "$BACKUP_DIR"/*.tz 2>/dev/null | head -n1 || true)"
  if [ -z "$BACKUP_FILE" ]; then
    echo "ERROR: no backups found in $BACKUP_DIR/" >&2
    exit 1
  fi
  BACKUP_NAME="$(basename "$BACKUP_FILE" .tz)"
fi

echo "==> Stopping Postgres"
docker compose --ansi never stop postgres

echo "==> Wiping current data and extracting $BACKUP_FILE"
docker compose --ansi never run --rm -T --no-deps --entrypoint sh \
  -v "$(pwd)/$BACKUP_DIR":/backup \
  postgres -c "rm -rf /var/lib/postgresql/data/* && tar xzf /backup/$(basename "$BACKUP_FILE") -C /var/lib/postgresql/data"

echo "==> Starting Postgres (it will replay WAL to reach a consistent state)"
docker compose --ansi never up -d postgres

echo "==> Waiting for Postgres to become healthy"
status="starting"
for _ in $(seq 1 30); do
  status="$(docker inspect -f '{{.State.Health.Status}}' dbgate_postgres 2>/dev/null || echo starting)"
  [ "$status" = "healthy" ] && break
  sleep 2
done
if [ "$status" != "healthy" ]; then
  echo "WARNING: Postgres did not report healthy in time. Check 'docker compose logs postgres'" >&2
  exit 1
fi

echo "==> Restore complete: $BACKUP_NAME"
