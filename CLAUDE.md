# CLAUDE.md — pg_manage_v2

> **⚠️ MIGRATION VERIFYING (cutover executed 2026-08-26 ~19:05 UTC).** Aligned to the
> fleet dev/release paradigm — spec: `data_acquisition/docs/migration_CLAUDE.md`.
> Release `03b1a1a` is deployed and the hardened crontab installed; what remains is
> the daily-clock verification: two nightly `backup.log` lines carrying
> `sha=03b1a1a` (expected clean by the morning of 2026-08-28). Remove this banner
> after that, and cut one more release so `/opt/apps` carries the closeout docs.
> (The watchdog verified from the release copy 2026-08-26; its next scheduled tick
> is Sep 3 and reports on its own clock.)
>
> Shape note: this is an **admin/infra repo** (host tooling, not a containerized job
> app), so only part of the paradigm applies — see *Paradigm application* below.

**pg_manage_v2** is the database-administration repo for this server family. It owns
the maintenance scripts for the local PostgreSQL, the tracked runtime definition of
the `pg_db` container, and the (dormant) Azure→local seeding tooling used when
building a new server.

---

## The three components

### 1. Maintenance scripts (LIVE — scheduled)

Both are **host bash scripts** run straight from cron — no container, no Node, no
vendored logger. Their run record is their own log file, not `util.app_run_logs`.

| Script | Schedule (matt-teixeira's USER crontab) | Run record |
|---|---|---|
| `scripts/backup.sh` | `15 2 * * *` nightly, `>/opt/run-logs/pg_manage_v2/cron.backup.out 2>&1` | appends to `/opt/resources/backups/backup.log` |
| `scripts/check-partition-horizon.sh` | `0 9 3,25 * *`, **no redirect on purpose** | appends to `/opt/run-logs/partition-watchdog.log`; **ALERT goes to stdout → cron mail** |

Every log line both scripts write ends `sha=<RELEASE_SHA|dev-tree>` — the release
provenance for this app (grep'd from the `.env` beside the scripts, never sourced).

- `backup.sh`: `pg_dump -Fc` of the per-server database (`PG_DB`, default `staging`),
  verified with `pg_restore --list`; authenticated `SAVE` + RDB copy of all four
  Redis instances; retention pruning (pg 7 days, redis 14). Internal `flock -n`
  logs `SKIPPED` rather than stacking dumps.
- `check-partition-horizon.sh`: read-only watchdog that every partitioned parent has
  coverage through next month. Partition **creation is owned by odd-jobs**
  (`pg-part-arch`, svc crontab, 1st of month) — this script only alerts on the outcome.
- **The watchdog's cron entry deliberately has no output redirect.** Silent-and-exit-0
  when healthy; an unhealthy run prints to stdout so cron mails it — that mail *is*
  the alert channel. Do not "harden" it into an `.out` file; that would swallow alerts.

### 2. pg_db runtime definition (`infra/pg_db/`)

The tracked compose definition of the `pg_db` container (postgres:16, SSL, secrets
pattern, log caps) plus the recreate RUNBOOK — executed 2026-08-18. This is server
infrastructure that happens to live in this repo; it is not a scheduled app. See
`infra/pg_db/RUNBOOK.md` and the server setup doc
(`data_acquisition/docs/docker_server_full_setup_2.1.md`, STEP 2).

### 3. Azure→local seeding tooling (DORMANT — operator-run)

`Dockerfile` (image `pg_manage`, node:lts + postgresql-client-16), `index.js`,
`jobs/`, `db/pg-pool.js`, `scripts/azure_to_local_migration/`, `scripts/azure_to_azure/`,
`scripts/the_one_piece/`. Used only when seeding a new server from Azure (setup doc
STEP 5) — never scheduled, no run record. It deliberately does **not** follow the
fleet Docker pattern (see *Paradigm application*).

---

## Paradigm application (what applies here, what is skipped)

Applies (adopted 2026-08-26):

- **Dev/release split**: editable clone at `~/apps/pg_manage_v2`; `/opt/apps/pg_manage_v2`
  is build output produced only by `build-release.sh` (clean-tree guard, `#RELEASE:`
  transform, `RELEASE_SHA` stamp, chown `svc:docker`).
- **Release provenance**: both maintenance scripts read `RELEASE_SHA` from the `.env`
  beside them (grep, never `source`) and append `sha=<sha|dev-tree>` to their log
  lines — the boot-line pattern mapped onto the run record this app actually writes.
- **`.env.example`** as the tracked record of required keys.
- **`preflight-check.sh`** with authenticated checks (sibling-container PG check for
  the rotation-registered credential; authenticated Redis PINGs; presence-only for
  Azure creds — probing Azure prod is deliberately out).
- **Cron hardening in place**: the backup entry's output goes to a bounded `.out`
  file instead of `/dev/null`. Cadences unchanged; entries stay in the user crontab
  (fleet consolidation into the svc crontab is a separate follow-up, BACKLOG 6f).

Skipped, deliberately (admin-repo shape):

- **Fleet Dockerfile / entrypoint.sh / gosu / `<app>:${USER_ID}` image tags / root
  docker-compose** — the scheduled jobs never enter a container; the `pg_manage`
  image is operator-run seeding tooling. Its `COPY . .` + denylist `.dockerignore`
  stay as-is (noted deviation).
- **`${LOG_DIR}` mount / entrypoint dir-repair / vendored logger /
  `util.app_run_logs`** — no containerized runs, no logger.
- **run_outcome/v1 exit-code contract** — not consumed for this app; the analog is
  backup.sh's fail-loud `FAILED:` log lines and non-zero exits.
- **Schedule move to svc crontab** — standing decision: existing user-crontab
  schedules stay put until the fleet-wide consolidation.

## Day-to-day operations

```bash
# Validate the environment (either copy; zero warnings is the standard)
bash preflight-check.sh

# Edit code ONLY in the dev clone; a dev run of either script logs sha=dev-tree
cd ~/apps/pg_manage_v2 && bash scripts/check-partition-horizon.sh

# Release: commit + push, then (needs sudo, run in your own terminal)
cd ~/apps/pg_manage_v2 && bash build-release.sh
# refuses a dirty tree; wipes /opt/apps/pg_manage_v2 and redeploys HEAD with
# RELEASE_SHA stamped into the deployed .env, owned svc:docker

# Provenance queries
grep 'sha=' /opt/resources/backups/backup.log | tail
tail /opt/run-logs/partition-watchdog.log
cat /opt/run-logs/pg_manage_v2/cron.backup.out   # last cron invocation only
```

`/opt/apps/pg_manage_v2` is **build output** — never edit it, it is not a git
checkout. A `sha=dev-tree` line appearing on the nightly schedule means cron is
somehow running a dev tree — investigate immediately.

## Branches / server identity

Admin-repo branch scheme (per setup doc identity table): `DEV` / `STAGING` / `PROD`
per server — **`STAGING` on acq-vm-0**, remote `origin/PROD` is the GitHub default
branch. The database name is per-server: scripts take `PG_DB` (default `staging`).

## Known warts (kept by decision — do not "fix" silently)

- **`DST_PASSWORD` in `.env` is the live PG superuser password** — required by the
  seeding tooling. This is why pg_manage_v2 is registered with the host rotation
  script (`/opt/resources/scripts/rotate-envs-20260817.sh`), which matches on that
  value and rewrites both copies (`/opt/apps/.../.env` and `~/apps/.../.env`).
  Preflight verifies it with an authenticated read-only check.
- **Dead code kept by decision (2026-08-26):** `jobs/copy_schema.js` calls
  `scripts/pgdump_schema_table_azure_to_dock_node.sh`, which does not exist (the
  `schema_migration` job path is broken); `db/pg-pool_old.js`; `commands.sh`
  (hand-run Redis container commands — redis-admin's territory). Removal needs
  per-item owner sign-off; until then they are documented, not deleted.
- **Renamed dumps escape retention on purpose**: `*.dump.full` / `*.dump.initial`
  in `/opt/resources/backups/pg/` don't match the retention glob (`$PG_DB-*.dump`)
  and are kept indefinitely as milestone snapshots (~172G as of 2026-08-26).
