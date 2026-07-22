<!--
SPDX-License-Identifier: AGPL-3.0-only
-->

# Metabase + PostgreSQL + pgAdmin

A stack to manage a PostgreSQL database and then experiment with Metabase.
It's a Docker Compose environment that includes PostgreSQL, pgAdmin, and
Metabase. All containers are pre-wired with the Postgres connection to the `spg`
database, password included so no login prompt appears on first use;
Metabase is additionally restricted to the `public` schema).

Use PgAdmin or connect to PostgreSQL to manage the raw data.
Then you can play with PostgreSQL.

**This environment is designed for learning and testing. It is not secure or performant.**

## Setup

1. **Install Docker** (fresh Ubuntu box only, skip if Docker is already installed):

   ```bash
   ./install-docker.sh
   ```

   If it printed a message about the `docker` group, you may need to open a
   new shell before the next step (the script drops you into one
   automatically when run as a non-root user).

2. **Bring up the stack:**

   ```bash
   ./setup.sh
   ```

   On first run this generates and stores, in a `.env` file (mode `600`,
   not committed to version control):

   - `POSTGRES_PASSWORD` — random password for the `pgadmin` Postgres user
   - `PGADMIN_DEFAULT_PASSWORD` — random password for the `PGADMIN_DEFAULT_EMAIL`
     (`admin@example.com`) pgAdmin web login, also reused as the Metabase
     admin login password (same email, same password)

   On later runs it reuses the same `.env` instead of regenerating
   passwords — Postgres only applies `POSTGRES_PASSWORD` the first time its
   data volume is initialized, so a new password on a later run would stop
   matching the actual database password.

   The script then starts the containers, waits for Postgres and Metabase
   to report healthy, and configures Metabase via its REST API (the
   open-source edition has no static config-file support like pgAdmin's
   `servers.json`): it creates the admin account on first run (or logs in
   on later runs) and adds the `spg` Postgres connection, restricted to the
   `public` schema, if it isn't already there. Metabase can take a couple
   of minutes to boot on first run, so the script retries each of these
   steps for several minutes before giving up — but if Metabase still
   isn't healthy or its API still isn't responding correctly after that,
   `setup.sh` fails outright (non-zero exit) instead of leaving Metabase
   half-configured; check `docker compose logs metabase` and re-run.

   Finally it runs best-effort checks: that Postgres (5432), pgAdmin (80,
   HTTP), and Metabase (3000, HTTP) are listening on all interfaces, plus a
   best-effort check against your public IP. That public-IP check can
   under-report (same-host self-checks can fail due to hairpin NAT even
   when external access works) and it cannot see cloud/security-group
   firewall rules — treat a "could not confirm" result as inconclusive, not
   as proof of failure, and verify from a genuinely external host if it
   matters to you.

## Extra admin users

By default the only login is `admin@example.com` (shared by pgAdmin and
Metabase, see above). `extra-users.conf` (gitignored, `chmod 600`) lists
additional accounts to provision on both tools as full Administrators,
each with the `spg` connection pre-configured in pgAdmin too: one
`email:password` per line, blank lines and `#` comments ignored.

If the file doesn't exist, `./setup.sh` creates an empty one and exits
immediately so you can edit it first — nothing else runs on that pass.
On every later run, it provisions whatever users are listed.

## First login to pgAdmin

1. Open `http://<server-ip>` in a browser.
2. Log in with:
   - **Email:** `admin@example.com`
   - **Password:** the `PGADMIN_DEFAULT_PASSWORD` value in `.env` (run
     `grep PGADMIN_DEFAULT_PASSWORD .env` on the server to retrieve it)
3. A server named **spg** is already listed in the tree on the left —
   click it to connect and browse the `spg` database. Its password was
   pre-loaded via a `pgpass` file, so no connection password prompt
   should appear.

## First login to Metabase

1. Open `http://<server-ip>:3000` in a browser.
2. Log in with:
   - **Email:** `admin@example.com`
   - **Password:** the same `PGADMIN_DEFAULT_PASSWORD` value used for pgAdmin
3. A database named **spg** is already connected, scoped to the `public`
   schema only — no need to add it manually.

## Postgres configuration

`postgresql.conf` and `pg_hba.conf` are bind-mounted from `pg-config/` on
the host into the container (read-only), so you can edit them directly
with any editor on the host — no `docker exec` needed. Apply changes with:

```bash
docker compose exec postgres su postgres -c "pg_ctl reload -D /var/lib/postgresql/data"
```

(or `docker compose restart postgres` if the setting you changed requires
a full restart, e.g. `max_connections`).

`pg-config/` is **not** committed to version control and is treated as
scratch: `./setup.sh` seeds it from the tracked baseline in
`postgres-config.template/` the first time it doesn't exist, and
`./teardown.sh` deletes it after bringing the stack down. So any edits
you make only live as long as the container does — destroy the container
(`./teardown.sh`) and the next `./setup.sh` starts you back at the
tracked defaults. Postgres's actual data is unaffected either way (it
lives in the separate `postgres_data` Docker volume).

Note: `ALTER SYSTEM` (run from SQL) writes `postgresql.auto.conf` into
the data directory, not into `pg-config/`, so it isn't covered by this
reset — that's a Postgres behavior, not something this setup can
intercept. Stick to editing the files in `pg-config/` from the host if
you want changes to reset on teardown.

## Security notes

**As stated, this environment is designed for learning and testing only.
As a consequence, it is not secure.**
The following list of security problems might not be complete.

- PostgreSQL's port 5432 is open.
- Metabase and PgAdmin share the same users and passwords.
- pgAdmin and Metabase have no HTTPS configured here.
- Credentials live in `.env` in this directory.
