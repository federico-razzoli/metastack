#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Tears down the stack and wipes pg-config/ (the live, host-editable
# Postgres config directory) so any edits made to postgresql.conf /
# pg_hba.conf while the container was running are discarded. Postgres
# data itself is untouched (it lives in the postgres_data Docker volume,
# not here) unless -v/--volumes is passed through.
#
# Usage: ./teardown.sh [docker compose down flags, e.g. -v]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Stopping the stack"
docker compose down "$@"

CONFIG_DIR="pg-config"
if [ -d "$CONFIG_DIR" ]; then
  echo "==> Wiping $CONFIG_DIR/ (Postgres config resets to postgres-config.template/ on next ./setup.sh)"
  rm -rf "$CONFIG_DIR"
fi

PGADMIN_CONFIG_DIR="pgadmin-config"
if [ -d "$PGADMIN_CONFIG_DIR" ]; then
  echo "==> Wiping $PGADMIN_CONFIG_DIR/ (contains the pgpass secret; regenerated fresh on next ./setup.sh)"
  rm -rf "$PGADMIN_CONFIG_DIR"
fi

echo "==> Done."
