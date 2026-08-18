# Maintenance scripts

Moved here from the untracked `/opt/resources/scripts/` on 2026-08-18 so a new server
gets them by cloning this repo (scripts live in the repo that owns their subject).

| Script | Schedule (user crontab) | What it does |
|---|---|---|
| [backup.sh](backup.sh) | `15 2 * * *` | pg_dump of `staging` (verified with `pg_restore --list`) + authenticated `SAVE`/RDB copy of all four Redis instances + retention pruning. Logs to `/opt/resources/backups/backup.log`. |
| [check-partition-horizon.sh](check-partition-horizon.sh) | `0 9 3,25 * *` | Read-only watchdog: every binned table must have next month's partition (odd-jobs owns partition creation — this only alerts on its outcome). |

The authoritative schedule manifest is `data_acquisition/docs/schedules.md`.

`azure_to_azure/`, `azure_to_local_migration/`, `the_one_piece/` are pre-existing
migration tooling, unrelated to the nightly maintenance set.
