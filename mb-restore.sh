#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Restores a backup taken by ./mb-backup.sh. This is destructive:
# it stops Metabase, wipes the current metabase_data contents, extracts
# the backup in their place, then starts Metabase back up.
#
# Usage: ./mb-restore.sh [name]   (name defaults to the most recent metabase backup)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

BACKUP_DIR="backups-mb"

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
    echo "ERROR: no metabase backups found in $BACKUP_DIR/" >&2
    exit 1
  fi
  BACKUP_NAME="$(basename "$BACKUP_FILE" .tz)"
fi

echo "==> Stopping Metabase"
docker compose --ansi never stop metabase

echo "==> Wiping current data and extracting $BACKUP_FILE"
docker compose --ansi never run --rm -T --no-deps --entrypoint sh \
  metabase -c "rm -rf /metabase-data/* && tar xzf - -C /metabase-data" \
  < "$BACKUP_FILE"

echo "==> Starting Metabase back up"
docker compose --ansi never up -d metabase

echo "==> Waiting for Metabase to become healthy"
status="starting"
for _ in $(seq 1 60); do
  status="$(docker inspect -f '{{.State.Health.Status}}' metabase 2>/dev/null || echo starting)"
  [ "$status" = "healthy" ] && break
  sleep 5
done
if [ "$status" != "healthy" ]; then
  echo "WARNING: Metabase did not report healthy in time. Check 'docker compose logs metabase'" >&2
  exit 1
fi

echo "==> Restore complete: $BACKUP_NAME"
