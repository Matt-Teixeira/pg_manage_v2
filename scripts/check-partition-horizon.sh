#!/usr/bin/env bash
# check-partition-horizon.sh — read-only watchdog for monthly partition upkeep.
#
# Partition creation/archival is OWNED by the odd-jobs app (runs on the 1st,
# svc crontab). This script must never create, drop, or alter anything — it
# only verifies the OUTCOME: every partitioned parent (outside archive_*)
# must have coverage through the end of NEXT month, i.e. its max partition
# upper bound >= first day of (current month + 2).
#
# That invariant holds on every day of a healthy month:
#   - checked Aug 17: September bins exist (bound Oct 1)  -> OK
#   - checked Sep  3 after a FAILED Sep 1 run: max bound Oct 1 < Nov 1 -> ALERT
#
# Output contract (cron-friendly): silent + exit 0 when healthy; prints an
# ALERT to stdout + exit 1 when unhealthy or when the check itself fails
# (fail-closed). Every run appends one line to the log either way.
#
# Test a simulated gap safely: HORIZON_MONTHS=3 ./check-partition-horizon.sh
# (requires coverage two months out, which won't exist -> must alert).

set -uo pipefail

# Release provenance: build-release.sh stamps RELEASE_SHA into the .env one
# level up; each appended log line carries it ('dev-tree' in a dev clone).
# grep a single key, never `source` a fleet .env (values may contain $$).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_SHA="$(grep -m1 '^RELEASE_SHA=' "$SCRIPT_DIR/../.env" 2>/dev/null | cut -d= -f2 || true)"
RELEASE_SHA="${RELEASE_SHA:-dev-tree}"

LOG=/opt/run-logs/pg_manage_v2/partition-watchdog.log
HORIZON_MONTHS="${HORIZON_MONTHS:-2}"

result=$(docker exec -i pg_db psql -U postgres -d "${PG_DB:-staging}" -tA -v ON_ERROR_STOP=1 <<SQL 2>&1
WITH parents AS (
  SELECT pt.partrelid AS oid
  FROM pg_partitioned_table pt
  JOIN pg_class pc ON pc.oid = pt.partrelid
  JOIN pg_namespace n ON n.oid = pc.relnamespace
  WHERE n.nspname NOT LIKE 'archive%'
),
bounds AS (
  SELECT p.oid::regclass AS parent,
         max(((regexp_match(pg_get_expr(c.relpartbound, c.oid),
               'TO \(''([^'']+)''\)'))[1])::timestamptz) AS max_bound
  FROM parents p
  LEFT JOIN pg_inherits i ON i.inhparent = p.oid
  LEFT JOIN pg_class c ON c.oid = i.inhrelid
  GROUP BY p.oid
)
SELECT parent || '|' || coalesce(max_bound::text, 'NO PARTITIONS')
FROM bounds
WHERE max_bound IS NULL
   OR max_bound < date_trunc('month', now()) + interval '${HORIZON_MONTHS} months'
ORDER BY 1;
SQL
)
rc=$?

ts=$(date -Is)
if [ $rc -ne 0 ]; then
  echo "$ts CHECK-FAILED rc=$rc sha=$RELEASE_SHA: $result" >> "$LOG"
  echo "PARTITION WATCHDOG: check itself failed (rc=$rc) — verify pg_db and this script. $result"
  exit 1
fi

if [ -n "$result" ]; then
  n=$(echo "$result" | wc -l)
  echo "$ts ALERT $n parent(s) below horizon (+${HORIZON_MONTHS}mo) sha=$RELEASE_SHA: $(echo "$result" | tr '\n' ' ')" >> "$LOG"
  echo "PARTITION WATCHDOG ALERT: $n partitioned table(s) lack coverage through next month."
  echo "The odd-jobs pg-part-arch run (1st of month, svc crontab) may have failed — check"
  echo "/opt/run-logs/odd-jobs/ and coordinate with its owner. Do NOT hand-create partitions"
  echo "without coordinating. Affected (parent|max bound):"
  echo "$result"
  exit 1
fi

echo "$ts OK all parents covered through month+${HORIZON_MONTHS} sha=$RELEASE_SHA" >> "$LOG"
exit 0
