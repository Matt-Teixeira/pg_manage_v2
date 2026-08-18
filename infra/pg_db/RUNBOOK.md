# pg_db recreate runbook (DRAFT — plan item 10)

**What this does:** replaces the hand-launched pg_db container with the tracked compose
definition. The data volume is external and untouched — this is a container swap, not a
data migration. Expected DB downtime: under a minute.

**When:** a quiet moment — ideally right after a :4x cron burst clears (or with the app
crontab paused, as on Aug 17). Jobs that fire during the swap fail that one cycle and
self-heal on the next.

## Pre-flight (no downtime)

1. Fresh backup exists and `backup.log` shows OK (nightly, or run `backup.sh` by hand).
2. ~~Create a bootstrap secret file~~ — **not required on this server (removed 2026-08-18).**
   Verified against `postgres:16`'s entrypoint: `docker_verify_minimum_env` — the check that
   demands `POSTGRES_PASSWORD`/`_FILE` — runs only inside `if [ -z "$DATABASE_ALREADY_EXISTS" ]`,
   i.e. only when initializing an EMPTY data directory. `postgres_data` is already initialized,
   so the value would be read by nothing while still appearing in `docker inspect` — exactly what
   SEC-05 asks us to remove. The role password lives in the database catalog; rotate it with
   `\password`. The compose file carries commented-out secret plumbing for the **new server**
   case, where initialization genuinely does need it.
3. Fix the SEC-06 key exposure (dd-agent uid collision) — move the key into a
   root-only directory; the container still reads it via the bind mount, but host
   uid 999 can no longer traverse to it:
   ```bash
   sudo install -d -m 700 -o root -g root /opt/resources/ssl/private
   sudo mv /opt/resources/ssl/pg_ssl.key /opt/resources/ssl/private/pg_ssl.key
   sudo chown 999:root /opt/resources/ssl/private/pg_ssl.key
   sudo chmod 600 /opt/resources/ssl/private/pg_ssl.key
   ```
4. Place `docker-compose.yaml` (this draft) in its agreed home; `docker compose config
   --quiet` must pass silently.

## The swap (downtime starts)

```bash
docker stop pg_db && docker rm pg_db        # volume + network survive
cd <compose home> && docker compose up -d
```

## Verification (gate — all must pass)

```bash
docker ps --filter name=pg_db --format '{{.Status}}'          # → (healthy) within ~1 min
docker inspect pg_db --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -c '^POSTGRES_PASSWORD='
                                                              # → 0 (SEC-05 closed)
docker exec pg_db psql -U postgres -d staging -c 'SELECT 1;'  # → 1
psql "host=<VM_IP> dbname=staging user=postgres sslmode=disable"   # → rejected (hostssl intact)
sudo -u dd-agent cat /opt/resources/ssl/private/pg_ssl.key         # → Permission denied (SEC-06 closed)
```
Then watch one full cron cycle land rows in `util.app_run_logs` and confirm
ops-dashboard `/healthz` still returns ok.

## Rollback

The old container is gone but its exact run parameters are documented (guide lines
469–478). Rollback = `docker compose down` (volume survives) + re-run the documented
`docker run` with the key at its new path. Data is never at risk in either direction —
both definitions point at the same external volume.

## Deliberately deferred (do NOT fold into this window)

- Memory limits/reservations — measure first (DB-04), June OOM still uninvestigated.
- Private interface binding (SEC-11) — NSG is the boundary today; revisit in doc 2.1.
- `shared_preload_libraries=pg_stat_statements` (DB-06) — worth adding at the SAME
  restart if decided in time, since it needs one; flag for Matt.
