#!/usr/bin/env bash
set -euo pipefail
shopt -s extglob  # for safe trimming if you add guards

# Required env (fail fast if missing)
req=(SRC_HOST SRC_DB SRC_USER SRC_PASSWORD DST_HOST DST_DB DST_USER DST_PASSWORD)
for v in "${req[@]}"; do
  : "${!v:?Missing required env: $v}"
done

# Defaults
SRC_PORT="${SRC_PORT:-5432}"
DST_PORT="${DST_PORT:-5432}"
SRC_SSLMODE="${SRC_SSLMODE:-verify-full}"   # Azure usually needs verify-full
SRC_SSLROOTCERT="${SRC_SSLROOTCERT:-system}"
DST_SSLMODE="${DST_SSLMODE:-disable}"       # local docker typically no TLS

echo "Source: $SRC_USER@$SRC_HOST:$SRC_PORT/$SRC_DB (sslmode=$SRC_SSLMODE sslrootcert=$SRC_SSLROOTCERT)"
echo "Dest:   $DST_USER@$DST_HOST:$DST_PORT/$DST_DB (sslmode=$DST_SSLMODE)"
echo

# List of env vars that define table groups (space-separated schema-qualified names)
TABLE_GROUP_VARS=(
  PUBLIC_TABLES
  ALERT_TABLES
  CONFIG_TABLES
  EDU_TABLES
  KDB_TABLES
  LIFE_TABLES
  UTIL_TABLES
)

# Optional: if you *only* want some groups, set TABLE_GROUP_FILTER="PUBLIC_TABLES UTIL_TABLES"
TABLE_GROUP_FILTER="${TABLE_GROUP_FILTER:-}"

dump_one_table() {
  local t="$1"
  local sch="${t%%.*}"
  local tbl="${t#*.}"

  echo "→ Syncing ${sch}.${tbl}"

  # 1) Truncate target & reset sequences
  PGPASSWORD="$DST_PASSWORD" PGSSLMODE="$DST_SSLMODE" \
    psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 \
      -c "TRUNCATE TABLE \"${sch}\".\"${tbl}\" RESTART IDENTITY CASCADE;"

  # 2) Dump DATA ONLY for that table from Azure -> pipe to psql on dest
  env -i PGPASSWORD="$SRC_PASSWORD" PGSSLMODE="$SRC_SSLMODE" PGSSLROOTCERT="$SRC_SSLROOTCERT" \
    pg_dump -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" \
      --data-only -t "${sch}.${tbl}" --no-owner --no-privileges -w \
  | PGPASSWORD="$DST_PASSWORD" PGSSLMODE="$DST_SSLMODE" \
    psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1

  echo "✓ ${sch}.${tbl} done"
  echo
}

for group_var in "${TABLE_GROUP_VARS[@]}"; do
  # Honor TABLE_GROUP_FILTER if set
  if [[ -n "$TABLE_GROUP_FILTER" ]]; then
    if ! grep -qw "$group_var" <<<"$TABLE_GROUP_FILTER"; then
      echo ">>> Skipping $group_var due to TABLE_GROUP_FILTER"
      continue
    fi
  fi

  # Get the value of the env var whose name is in $group_var
  tables="${!group_var-}"

  # If that group is unset or empty, skip it
  if [[ -z "${tables//[[:space:]]/}" ]]; then
    echo ">>> Skipping $group_var (not set or empty)"
    continue
  fi

  echo "========================================"
  echo ">>> Processing group: $group_var"
  echo ">>> Tables: $tables"
  echo

  # Loop each schema-qualified table in this group
  for t in $tables; do
    dump_one_table "$t"
  done
done

echo "All tables synced ✅"
