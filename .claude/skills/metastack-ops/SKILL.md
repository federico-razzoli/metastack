---
name: metastack-ops
description: This skill should be used when the user asks to "set up the stack", "start/stop/restart metastack", "bring the stack up/down", "add a user" or "configure extra users", "log into pgadmin/metabase/postgres", "connect to the spg database", or "take/restore a backup" in this repository (PostgreSQL + pgAdmin + Metabase Docker Compose stack).
---

# Metastack Operations

Docker Compose stack: PostgreSQL 16 (`spg` database), pgAdmin, Metabase.
Everything is driven by scripts in the repo root — never call `docker compose`
directly for lifecycle/config tasks, only for ad-hoc inspection (`logs`, `ps`).

## Initial setup (fresh clone, box already has the repo)

1. Fresh Ubuntu box only, skip if Docker already installed: `./install-docker.sh`.
   If it prints a message about the `docker` group, open a new shell before
   continuing (or the script itself drops into one via `exec sg docker`).
2. Run `./setup.sh`.
   - First run: no `.env` yet → generates random `POSTGRES_PASSWORD` and
     `PGADMIN_DEFAULT_PASSWORD`, writes `.env` (mode 600). Also, if
     `extra-users.conf` doesn't exist yet, creates an empty template and
     **exits immediately without starting anything** — edit that file, then
     re-run `./setup.sh`.
   - Every run: seeds `pg-config/` from `postgres-config.template/` if
     missing, regenerates `pgadmin-config/` (pgpass must always match the
     current `.env` password), starts all containers, waits for Postgres and
     Metabase healthchecks, configures Metabase via its REST API (admin
     account + `spg` connection scoped to the `public` schema — Metabase
     OSS has no config-file support), then provisions `extra-users.conf`
     accounts in both tools.
   - Never edit `POSTGRES_PASSWORD` in `.env` by hand after first run —
     Postgres only applies it when the data volume is first initialized, so
     a mismatched value breaks login silently.
3. `setup.sh` exits non-zero if Metabase never reports healthy/configurable
   instead of leaving it half-set-up — check `docker compose logs metabase`
   and re-run.

## Start / stop / restart

- Stop (keep data + config): `docker compose stop`
- Start back up: `docker compose start` (or `./setup.sh` — idempotent, safe
  to re-run, reuses `.env`)
- Restart a single service: `docker compose restart <postgres|pgadmin|metabase>`
- Full teardown: `./teardown.sh` — stops containers, wipes `pg-config/` and
  `pgadmin-config/` (regenerated from templates on next `./setup.sh`).
  Postgres/Metabase data volumes are untouched unless `-v`/`--volumes` is
  passed through, e.g. `./teardown.sh -v` (destroys all data — confirm with
  the user first).

## Extra admin users

Edit `extra-users.conf` (gitignored, mode 600): one `email:password` per
line, `#` comments and blank lines ignored. Re-run `./setup.sh` — it creates
missing accounts as full Administrators in both pgAdmin and Metabase, and
imports the `spg` server + pgpass into each new pgAdmin account (reruns are
idempotent, existing users are skipped with a log line).

## Logging in

**PostgreSQL, any GUI client / psql**: host = server IP (or `localhost`),
port 5432, db `spg`, user `pgadmin`, password = `POSTGRES_PASSWORD` in
`.env` (`grep POSTGRES_PASSWORD .env`). Port 5432 is published on all
interfaces.

**pgAdmin**: `http://<server-ip>` (port 80). Log in with
`admin@example.com` / `PGADMIN_DEFAULT_PASSWORD` from `.env`, or an
extra-user's own `email:password`. The **spg** server is already listed in
the tree with password pre-loaded via `pgpass` — no connection prompt.

**Metabase**: `http://<server-ip>:3000`. Same login as pgAdmin
(`admin@example.com` / `PGADMIN_DEFAULT_PASSWORD`, or an extra user). The
**spg** database is already connected, scoped to the `public` schema only.

## PostgreSQL config edits

Edit `pg-config/postgresql.conf` or `pg-config/pg_hba.conf` directly on the
host (bind-mounted read-only into the container). Apply with:
```
docker compose exec postgres su postgres -c "pg_ctl reload -D /var/lib/postgresql/data"
```
or `docker compose restart postgres` for settings that need a full restart
(e.g. `max_connections`). These edits are wiped by `./teardown.sh` (reset to
`postgres-config.template/`); actual data is unaffected.

## Backups and restores

Postgres (hot backup, `pg_basebackup`, cluster keeps running):
```
./pg-backup.sh [name]      # defaults to timestamp; writes backups-pg/<name>.tz
./pg-restore.sh [name]     # defaults to most recent; DESTRUCTIVE, wipes current data dir
```

Metabase (briefly stops the container for a consistent H2 file copy):
```
./mb-backup.sh [name]   # writes backups-mb/<name>.tz
./mb-restore.sh [name]  # defaults to most recent; DESTRUCTIVE, wipes metabase_data
```

Both `*-restore.sh` scripts stop the service, wipe its volume, extract the
archive, and wait for the healthcheck to pass. Confirm with the user before
running a restore — it discards current data. Both backup scripts refuse to
overwrite an existing file with the same name and clean up partial output on
failure (`trap ... ERR`).
