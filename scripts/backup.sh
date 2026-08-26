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

# Release provenance: build-release.sh stamps RELEASE_SHA into the .env one
# level up; every log line below carries it, so backup.log identifies the
# commit that produced each run. A dev clone has no stamp -> 'dev-tree'.
# grep a single key, never `source` a fleet .env (values may contain $$).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# (|| true: under set -e/pipefail a no-match grep would otherwise kill the
# script — which is every dev-clone run, where the stamp legitimately absent)
RELEASE_SHA="$(grep -m1 '^RELEASE_SHA=' "$SCRIPT_DIR/../.env" 2>/dev/null | cut -d= -f2 || true)"
RELEASE_SHA="${RELEASE_SHA:-dev-tree}"

BASE=/opt/resources/backups
# The database name is per-server (dev / staging / prod — see the setup doc's
# server-identity table). Override via environment or edit the default here.
PG_DB="${PG_DB:-staging}"
PG_KEEP_DAYS=7        # pg dumps are large (>10 GB) — keep a week locally
REDIS_KEEP_DAYS=14    # RDBs are small — keep two weeks
DATE=$(date +%Y%m%d-%H%M)
LOG="$BASE/backup.log"

mkdir -p "$BASE/pg" "$BASE/redis"

# Single-instance lock: if a previous backup is still running (e.g. a very long
# pg_dump), skip this run and log it rather than stacking two dumps (OPS-01).
exec 9>"$BASE/.backup.lock"
flock -n 9 || { echo "$(date -Is) SKIPPED: previous backup still running sha=$RELEASE_SHA" >> "$LOG"; exit 0; }

# Every exit path must leave one log line and no unverified dump behind.
# Previously a `set -e` failure outside fail(), or a TERM/INT, exited with NO
# log line and left a partial $PG_OUT that looked like a good backup until
# restore day. The EXIT trap is the catch-all; fail() marks DONE so handled
# failures don't log twice. A dump is only kept once pg_restore --list has
# verified it (PG_DUMP_VERIFIED) — a truncated dump is worse than none.
# Note (verified by test): a TERM/INT exits promptly; an in-flight
# `docker exec pg_db pg_dump` client may be left to finish on its own, but
# its output file is already unlinked here, so no unverified dump survives.
# Only SIGKILL bypasses this (no line, partial dump left).
DONE=0
PG_DUMP_VERIFIED=0
drop_partial() {
    if [ "$PG_DUMP_VERIFIED" = 0 ] && [ -n "${PG_OUT:-}" ] && [ -f "$PG_OUT" ]; then
        rm -f "$PG_OUT"
        echo " (partial dump removed)"
    fi
}
cleanup() {
    rc=$?
    [ "$DONE" = 1 ] && exit "$rc"
    note=$(drop_partial)
    echo "$(date -Is) FAILED rc=$rc: aborted before completion (signal or unlogged failure)$note sha=$RELEASE_SHA" | tee -a "$LOG" >&2
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

fail() {
    note=$(drop_partial)
    echo "$(date -Is) FAILED: $*$note sha=$RELEASE_SHA" | tee -a "$LOG" >&2
    DONE=1
    exit 1
}

# --- PostgreSQL -------------------------------------------------------------
# log.saved_files is INCLUDED again as of 2026-08-18: its 48 h retention was
# restored (backlog purged, clear_old_db_files on :05/:35 — audit DB-05), so it
# adds only ~6 GB of incompressible blobs. If this dump ever balloons, check
# that retention job's outcomes before touching this script.
PG_OUT="$BASE/pg/$PG_DB-$DATE.dump"
docker exec pg_db pg_dump -U postgres -Fc "$PG_DB" > "$PG_OUT" \
  || fail "pg_dump $PG_DB"
# A truncated dump is worse than none: verify the archive is listable.
docker exec -i pg_db pg_restore --list < "$PG_OUT" > /dev/null \
  || fail "pg_restore --list on $PG_OUT (dump unreadable)"
PG_DUMP_VERIFIED=1

# --- Redis ------------------------------------------------------------------
# redis-cli exits 0 even when the server refuses the command (e.g. NOAUTH), so
# the reply text must be checked — exit codes are meaningless here. All four
# instances read their own mounted auth.conf (REDIS-01 rollout 2026-08-18;
# redis-STAGING auth'd since 2026-08-19).
for r in redis-PROD redis-STAGING redis_dev-0-4 redis_dev-0-5; do
  out=$(docker exec "$r" sh -c 'redis-cli -a "$(awk "/^requirepass/{print \$2}" /usr/local/etc/redis/auth.conf)" --no-auth-warning SAVE')
  [ "$out" = "OK" ] || fail "SAVE on $r (reply: $out)"
  docker cp -q "$r:/data/dump.rdb" "$BASE/redis/$r-$DATE.rdb" || fail "copy RDB from $r"
done

# --- Retention --------------------------------------------------------------
find "$BASE/pg"    -name "$PG_DB-*.dump" -mtime +"$PG_KEEP_DAYS"    -delete
find "$BASE/redis" -name '*.rdb'          -mtime +"$REDIS_KEEP_DAYS" -delete

echo "$(date -Is) OK pg=$(du -h "$PG_OUT" | cut -f1) redis=4 instances sha=$RELEASE_SHA" | tee -a "$LOG"
DONE=1

# --- Off-host sync (TODO: enable once a target exists) ----------------------
# az storage blob upload-batch ... / rclone sync "$BASE" remote:acq-vm-0-backups
