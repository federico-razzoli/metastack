#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Backs up Metabase's application data (dashboards, questions, users,
# password hashes, permissions, connection settings, etc.), which lives
# in the metabase_data volume as an embedded H2 file database (MB_DB_FILE).
# Unlike Postgres, H2 has no pg_basebackup-style hot backup tool, so this
# briefly stops the metabase container, tars the volume, then starts it
# back up -- this guarantees a consistent copy since nothing is writing
# to the H2 files while stopped.
#
# Usage: ./metabase-backup.sh [name]   (name defaults to the current timestamp)
# Output: backups-mb/<name>.tz (a single gzip'd tar file)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

BACKUP_NAME="${1:-$(date +%Y%m%d_%H%M%S)}"
case "$BACKUP_NAME" in
  */*) echo "ERROR: backup name must not contain '/'" >&2; exit 1 ;;
esac

BACKUP_DIR="backups-mb"
BACKUP_FILE="$BACKUP_DIR/${BACKUP_NAME}.tz"
mkdir -p "$BACKUP_DIR"

if [ -e "$BACKUP_FILE" ]; then
  echo "ERROR: $BACKUP_FILE already exists" >&2
  exit 1
fi

# Remove a partial file if anything below fails partway through, so a
# broken backup never sits there looking like a valid one.
trap 'rm -f "$BACKUP_FILE"' ERR

echo "==> Stopping Metabase (briefly, so the backup is consistent)"
docker compose --ansi never stop metabase

echo "==> Taking backup '$BACKUP_NAME' of metabase_data"
docker compose --ansi never run --rm -T --no-deps --entrypoint sh \
  metabase -c "tar czf - -C /metabase-data ." \
  > "$BACKUP_FILE"

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

echo "==> Done: $BACKUP_FILE"
