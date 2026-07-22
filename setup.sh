#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Wrapper around docker compose that:
#   - generates a secure random Postgres password on first run (and reuses
#     it on later runs, since Postgres only honors POSTGRES_PASSWORD when
#     its data volume is first initialized)
#   - brings up the dedicated network, Postgres, pgAdmin, and Metabase
#   - pre-wires pgAdmin with the Postgres connection to the spg database,
#     password included via PGPASS_FILE so no manual login is needed
#   - pre-wires Metabase (via its REST API, since it has no static config
#     file support in the open-source edition) with an admin account and a
#     connection to the spg database's public schema, reusing the pgAdmin
#     password for the Metabase admin login
#   - runs best-effort checks that Postgres (5432), pgAdmin (80, HTTP), and
#     Metabase (3000, HTTP) are reachable
#
# Requires install-docker.sh to have been run first.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE=".env"

if ! command -v docker &> /dev/null || ! docker compose version &> /dev/null; then
  echo "docker / docker compose not found. Run install-docker.sh first" >&2
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "jq not found (needed to configure Metabase via its API). Run install-docker.sh first" >&2
  exit 1
fi

EXTRA_USERS_FILE="extra-users.conf"
if [ ! -f "$EXTRA_USERS_FILE" ]; then
  umask 077
  cat > "$EXTRA_USERS_FILE" <<'EOF'
# email:password
# alice@example.com:some-strong-password
EOF
  chmod 600 "$EXTRA_USERS_FILE"
  echo "==> Created $EXTRA_USERS_FILE. Edit it to add extra admin users (email:password, one per line), then re-run ./setup.sh."
  exit 0
fi

if [ -f "$ENV_FILE" ]; then
  echo "==> Reusing existing credentials from $ENV_FILE"
  PG_PASSWORD="$(grep -E '^POSTGRES_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
  PGADMIN_PASSWORD="$(grep -E '^PGADMIN_DEFAULT_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
else
  echo "==> Generating secure random passwords for Postgres and the pgAdmin login"
  PG_PASSWORD="$(openssl rand -base64 24)"
  PGADMIN_PASSWORD="$(openssl rand -base64 24)"
  umask 077
  cat > "$ENV_FILE" <<EOF
POSTGRES_USER=pgadmin
POSTGRES_PASSWORD=${PG_PASSWORD}
POSTGRES_DB=spg
PGADMIN_DEFAULT_EMAIL=admin@example.com
PGADMIN_DEFAULT_PASSWORD=${PGADMIN_PASSWORD}
EOF
  chmod 600 "$ENV_FILE"
fi

CONFIG_DIR="pg-config"
CONFIG_TEMPLATE="postgres-config.template"

if [ -d "$CONFIG_DIR" ]; then
  echo "==> Reusing existing Postgres config in $CONFIG_DIR/ (edit files there directly;"
  echo "    run ./teardown.sh to wipe it back to defaults)"
else
  echo "==> Seeding Postgres config in $CONFIG_DIR/ from $CONFIG_TEMPLATE/"
  cp -r "$CONFIG_TEMPLATE" "$CONFIG_DIR"
fi

PGADMIN_CONFIG_DIR="pgadmin-config"
PGADMIN_CONFIG_TEMPLATE="pgadmin-config.template"

# Regenerated every run (not just when missing): the pgpass file must always
# match the current POSTGRES_PASSWORD in .env, so a stale one left over from
# a previous password would silently break passwordless login in pgAdmin.
echo "==> Seeding pgAdmin pre-configured connection in $PGADMIN_CONFIG_DIR/"
mkdir -p "$PGADMIN_CONFIG_DIR"
cp -f "$PGADMIN_CONFIG_TEMPLATE"/servers.json "$PGADMIN_CONFIG_DIR"/servers.json
umask 077
echo "postgres:5432:*:pgadmin:${PG_PASSWORD}" > "$PGADMIN_CONFIG_DIR"/pgpass
chmod 600 "$PGADMIN_CONFIG_DIR"/pgpass
# The pgadmin container runs as uid 5050 (non-root) and reads this file
# through a read-only bind mount, so it must be readable by that uid.
if [ "$(id -u)" = "0" ]; then
  chown 5050 "$PGADMIN_CONFIG_DIR"/pgpass
else
  echo "WARNING: not running as root — could not chown pgpass to uid 5050;" >&2
  echo "         pgAdmin's pre-loaded password may fail to copy on first launch" >&2
fi

echo "==> Starting Postgres, pgAdmin, and Metabase"
docker compose up -d

echo "==> Waiting for Postgres to become healthy"
for _ in $(seq 1 30); do
  status="$(docker inspect -f '{{.State.Health.Status}}' dbgate_postgres 2>/dev/null || echo starting)"
  [ "$status" = "healthy" ] && break
  sleep 2
done
if [ "$status" != "healthy" ]; then
  echo "WARNING: Postgres did not report healthy in time. Check 'docker compose logs postgres'" >&2
fi

echo "==> Waiting for Metabase to become healthy (first boot can take a couple of minutes)"
mb_status="starting"
for _ in $(seq 1 200); do
  mb_status="$(docker inspect -f '{{.State.Health.Status}}' metabase 2>/dev/null || echo starting)"
  [ "$mb_status" = "healthy" ] && break
  sleep 3
done
if [ "$mb_status" != "healthy" ]; then
  echo "ERROR: Metabase did not become healthy after 10 minutes. Check 'docker compose logs metabase'" >&2
  exit 1
fi

echo "==> Configuring Metabase (admin account + spg Postgres connection, public schema only)"
MB_URL="http://localhost:3000"
MB_ADMIN_EMAIL="$(grep -E '^PGADMIN_DEFAULT_EMAIL=' "$ENV_FILE" | cut -d= -f2-)"

PGPASS_CONTENT="$(cat "$PGADMIN_CONFIG_DIR"/pgpass)"

# Writes the pgpass content into a pgAdmin user's own storage dir by piping
# it into the container (which owns that dir as its own internal user),
# instead of relying on the container being able to read the host-owned
# pgpass file bind-mounted above.
load_pgadmin_pgpass() {
  docker compose exec -T pgadmin sh -c '
    dir="/var/lib/pgadmin/storage/$(printf %s "$1" | sed "s/@/_/g")"
    mkdir -p "$dir" && cat > "$dir/.pgpass" && chmod 600 "$dir/.pgpass"
  ' _ "$1" <<< "$PGPASS_CONTENT"
}

echo "==> Loading the spg connection password into pgAdmin for $MB_ADMIN_EMAIL"
if load_pgadmin_pgpass "$MB_ADMIN_EMAIL" > /dev/null 2>&1; then
  echo "    OK"
else
  echo "    WARNING: failed to load the spg password for $MB_ADMIN_EMAIL" >&2
fi

MB_PROPS=""
for _ in $(seq 1 20); do
  MB_PROPS="$(curl -fsS --max-time 5 "$MB_URL/api/session/properties" 2>/dev/null)"
  [ -n "$MB_PROPS" ] && echo "$MB_PROPS" | jq -e . > /dev/null 2>&1 && break
  sleep 3
done
if [ -z "$MB_PROPS" ] || ! echo "$MB_PROPS" | jq -e . > /dev/null 2>&1; then
  echo "ERROR: Metabase's API never returned a valid response from $MB_URL/api/session/properties" >&2
  exit 1
fi
SETUP_TOKEN="$(echo "$MB_PROPS" | jq -r '."setup-token" // empty')"

MB_SESSION=""
if [ -n "$SETUP_TOKEN" ]; then
  for _ in $(seq 1 20); do
    MB_SESSION="$(curl -fsS --max-time 15 -X POST "$MB_URL/api/setup" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg token "$SETUP_TOKEN" \
        --arg email "$MB_ADMIN_EMAIL" \
        --arg password "$PGADMIN_PASSWORD" \
        '{token: $token, database: null,
          prefs: {site_name: "Metabase", allow_tracking: "false"},
          user: {first_name: "Admin", last_name: "User", email: $email, password: $password, site_name: "Metabase"}}')" \
      2>/dev/null | jq -r '.id // empty')"
    [ -n "$MB_SESSION" ] && break
    sleep 3
  done
else
  for _ in $(seq 1 20); do
    MB_SESSION="$(curl -fsS --max-time 15 -X POST "$MB_URL/api/session" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg u "$MB_ADMIN_EMAIL" --arg p "$PGADMIN_PASSWORD" '{username: $u, password: $p}')" \
      2>/dev/null | jq -r '.id // empty')"
    [ -n "$MB_SESSION" ] && break
    sleep 3
  done
fi

if [ -z "$MB_SESSION" ]; then
  echo "ERROR: could not authenticate to Metabase's API (setup/login both failed after retrying)" >&2
  exit 1
fi

already_added=""
for _ in $(seq 1 20); do
  db_list="$(curl -fsS --max-time 5 -H "X-Metabase-Session: $MB_SESSION" "$MB_URL/api/database" 2>/dev/null)"
  if [ -n "$db_list" ] && echo "$db_list" | jq -e . > /dev/null 2>&1; then
    already_added="$(echo "$db_list" | jq '[.. | objects | select(.engine? == "postgres" and .name? == "spg")] | length')"
    break
  fi
  sleep 3
done
if [ -z "$already_added" ]; then
  echo "ERROR: could not query Metabase's /api/database after retrying" >&2
  exit 1
fi

if [ "$already_added" -gt 0 ]; then
  echo "    Reusing existing 'spg' database connection in Metabase"
else
  added=false
  for _ in $(seq 1 20); do
    if curl -fsS --max-time 15 -X POST "$MB_URL/api/database" \
      -H "Content-Type: application/json" \
      -H "X-Metabase-Session: $MB_SESSION" \
      -d "$(jq -n --arg pass "$PG_PASSWORD" '{
        name: "spg",
        engine: "postgres",
        details: {
          host: "postgres",
          port: 5432,
          dbname: "spg",
          user: "pgadmin",
          password: $pass,
          "schema-filters-type": "inclusion",
          "schema-filters-patterns": "public"
        }
      }')" > /dev/null 2>&1; then
      added=true
      break
    fi
    sleep 3
  done
  if [ "$added" = true ]; then
    echo "    OK: added the 'spg' Postgres connection to Metabase (public schema only)"
  else
    echo "ERROR: failed to add the 'spg' Postgres connection to Metabase after retrying" >&2
    exit 1
  fi
fi

echo
echo "==> Provisioning extra admin users from $EXTRA_USERS_FILE"

# Group 2 is Metabase's built-in "Administrators" group.
mb_users_json="$(curl -fsS --max-time 5 -H "X-Metabase-Session: $MB_SESSION" "$MB_URL/api/user" 2>/dev/null || true)"

mapfile -t extra_user_lines < "$EXTRA_USERS_FILE"
for line in "${extra_user_lines[@]}"; do
  line="${line%%#*}"
  # Trim leading/trailing whitespace without word-splitting the password.
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] && continue

  email="${line%%:*}"
  password="${line#*:}"
  if [ -z "$email" ] || [ -z "$password" ] || [ "$email" = "$line" ]; then
    echo "    WARNING: skipping malformed line in $EXTRA_USERS_FILE (expected email:password): $line" >&2
    continue
  fi

  echo "    -- $email"

  pgadmin_out="$(docker compose exec -T pgadmin /venv/bin/python /pgadmin4/setup.py add-user "$email" "$password" --admin 2>&1)"
  if echo "$pgadmin_out" | grep -qi "already exists"; then
    echo "       pgAdmin: already exists"
  elif echo "$pgadmin_out" | grep -qi "error"; then
    echo "       WARNING: pgAdmin add-user failed for $email: $pgadmin_out" >&2
  else
    echo "       pgAdmin: OK (created as Administrator)"
  fi

  # add-user only creates the login; the "spg" server connection is a
  # separate per-user tree, so it has to be imported into each extra
  # user's own account too (--replace keeps this idempotent on reruns).
  if docker compose exec -T pgadmin /venv/bin/python /pgadmin4/setup.py load-servers /pgadmin4/servers.json --user "$email" --replace > /dev/null 2>&1; then
    echo "       pgAdmin: OK (spg server connection imported)"
  else
    echo "       WARNING: pgAdmin load-servers failed for $email" >&2
  fi

  # The imported server's "PassFile": ".pgpass" only resolves if a pgpass
  # file exists in *this* user's own storage dir, loaded the same way as
  # for the default admin above.
  if load_pgadmin_pgpass "$email" > /dev/null 2>&1; then
    echo "       pgAdmin: OK (pgpass loaded, no password prompt)"
  else
    echo "       WARNING: pgAdmin pgpass load failed for $email" >&2
  fi

  if [ -n "$mb_users_json" ] && echo "$mb_users_json" | jq -e --arg e "$email" '[.. | objects | select(.email? == $e)] | length > 0' > /dev/null 2>&1; then
    echo "       Metabase: already exists"
  else
    if curl -fsS --max-time 15 -X POST "$MB_URL/api/user" \
      -H "Content-Type: application/json" \
      -H "X-Metabase-Session: $MB_SESSION" \
      -d "$(jq -n --arg email "$email" --arg pass "$password" \
        '{first_name: "Admin", last_name: "User", email: $email, password: $pass, group_ids: [2]}')" > /dev/null 2>&1; then
      echo "       Metabase: OK (created as Administrator)"
    else
      echo "       WARNING: Metabase user creation failed for $email" >&2
    fi
  fi
done

echo
echo "==> Final checks"
echo "    (these run from this same host; they confirm the ports are open"
echo "     on all interfaces and best-effort confirm reachability via the"
echo "     public IP, but they CANNOT see cloud/firewall security-group"
echo "     rules, and the public-IP self-check can false-negative due to"
echo "     hairpin NAT even when external access works fine)"
echo

check_local_listen() {
  local port="$1" name="$2"
  if ss -tln 2>/dev/null | grep -qE "0\.0\.0\.0:${port}|\*:${port}|:::${port}"; then
    echo "    OK: $name is listening on all interfaces (port $port)"
  else
    echo "    WARNING: $name does not appear to be listening on all interfaces (port $port)"
  fi
}

check_local_listen 5432 "Postgres"
check_local_listen 80 "pgAdmin"
check_local_listen 3000 "Metabase"

PUBLIC_IP="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || true)"
if [ -n "$PUBLIC_IP" ]; then
  echo "    Detected public IP: $PUBLIC_IP (via ifconfig.me)"

  if timeout 5 bash -c "echo > /dev/tcp/${PUBLIC_IP}/5432" 2>/dev/null; then
    echo "    OK: Postgres responded on ${PUBLIC_IP}:5432"
  else
    echo "    Could not confirm Postgres on the public IP (see note above; verify manually from another host)"
  fi

  if curl -fsS --max-time 5 "http://${PUBLIC_IP}" -o /dev/null 2>/dev/null; then
    echo "    OK: pgAdmin responded over HTTP on ${PUBLIC_IP}:80"
  else
    echo "    Could not confirm pgAdmin on the public IP (see note above; verify manually from another host)"
  fi

  if curl -fsS --max-time 5 "http://${PUBLIC_IP}:3000/api/health" -o /dev/null 2>/dev/null; then
    echo "    OK: Metabase responded over HTTP on ${PUBLIC_IP}:3000"
  else
    echo "    Could not confirm Metabase on the public IP (see note above; verify manually from another host)"
  fi
else
  echo "    Could not determine public IP (no outbound internet access?); skipping external check"
fi

echo
echo "==> Done."
echo "    Postgres:  ${PUBLIC_IP:-<this-host>}:5432  (user: pgadmin, db: spg, password: ${PG_PASSWORD})"
echo "    pgAdmin:   http://${PUBLIC_IP:-<this-host>}  (login: admin@example.com / ${PGADMIN_PASSWORD}; the spg"
echo "               connection is pre-configured with no further password prompt)"
echo "    Metabase:  http://${PUBLIC_IP:-<this-host>}:3000  (login: admin@example.com / ${PGADMIN_PASSWORD};"
echo "               same password as pgAdmin; the spg connection, public schema only, is pre-configured)"
