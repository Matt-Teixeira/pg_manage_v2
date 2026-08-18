#!/usr/bin/env bash
# backup.sh — nightly local backups of the stateful services on this box.
#
#   - PostgreSQL: pg_dump -Fc of the staging database (custom format,
#     compressed; restore with pg_restore). ~30 min / >10 GB on acq-vm-0 —
#     schedule it in a quiet overnight slot.
#   - Redis: redis-cli SAVE (synchronous snapshot) + copy of each instance's
#     dump.rdb out of the container.
#
# Retention is local-only until an off-host target is provisioned (Azure
# storage etc.) — at that point add a sync step at the bottom.
# Summary appends to /opt/resources/backups/backup.log.

set -euo pipefail

BASE=/opt/resources/backups
PG_KEEP_DAYS=7        # pg dumps are large (>10 GB) — keep a week locally
REDIS_KEEP_DAYS=14    # RDBs are small — keep two weeks
DATE=$(date +%Y%m%d-%H%M)
LOG="$BASE/backup.log"

mkdir -p "$BASE/pg" "$BASE/redis"

# Single-instance lock: if a previous backup is still running (e.g. a very long
# pg_dump), skip this run and log it rather than stacking two dumps (OPS-01).
exec 9>"$BASE/.backup.lock"
flock -n 9 || { echo "$(date -Is) SKIPPED: previous backup still running" >> "$LOG"; exit 0; }

fail() { echo "$(date -Is) FAILED: $*" | tee -a "$LOG" >&2; exit 1; }

# --- PostgreSQL -------------------------------------------------------------
# NOTE (2026-08-17): log.saved_files DATA is excluded — the raw-file blob table
# grew to 130+ GB (audit DB-05) and quintupled dump size/time. Its schema is
# still dumped (restores as an empty table). Remove the flag once the Phase-2
# retention cleanup shrinks the table. Full reference dumps incl. this table:
# staging-20260727-1933.dump.initial and staging-20260817-1324.dump.full.
PG_OUT="$BASE/pg/staging-$DATE.dump"
docker exec pg_db pg_dump -U postgres -Fc --exclude-table-data='log.saved_files' staging > "$PG_OUT" \
  || fail "pg_dump staging"
# A truncated dump is worse than none: verify the archive is listable.
docker exec -i pg_db pg_restore --list < "$PG_OUT" > /dev/null \
  || fail "pg_restore --list on $PG_OUT (dump unreadable)"

# --- Redis ------------------------------------------------------------------
# redis-cli exits 0 even when the server refuses the command (e.g. NOAUTH), so
# the reply text must be checked — exit codes are meaningless here. The three
# auth'd instances read their own mounted auth.conf (REDIS-01 rollout
# 2026-08-18); redis-STAGING remains passwordless by design (odd-jobs).
for r in redis-PROD redis-STAGING redis_dev-0-4 redis_dev-0-5; do
  if [ "$r" = "redis-STAGING" ]; then
    out=$(docker exec "$r" redis-cli SAVE)
  else
    out=$(docker exec "$r" sh -c 'redis-cli -a "$(awk "/^requirepass/{print \$2}" /usr/local/etc/redis/auth.conf)" --no-auth-warning SAVE')
  fi
  [ "$out" = "OK" ] || fail "SAVE on $r (reply: $out)"
  docker cp -q "$r:/data/dump.rdb" "$BASE/redis/$r-$DATE.rdb" || fail "copy RDB from $r"
done

# --- Retention --------------------------------------------------------------
find "$BASE/pg"    -name 'staging-*.dump' -mtime +"$PG_KEEP_DAYS"    -delete
find "$BASE/redis" -name '*.rdb'          -mtime +"$REDIS_KEEP_DAYS" -delete

echo "$(date -Is) OK pg=$(du -h "$PG_OUT" | cut -f1) redis=4 instances" | tee -a "$LOG"

# --- Off-host sync (TODO: enable once a target exists) ----------------------
# az storage blob upload-batch ... / rclone sync "$BASE" remote:acq-vm-0-backups
