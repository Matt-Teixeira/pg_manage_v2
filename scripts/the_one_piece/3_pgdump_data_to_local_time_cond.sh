#!/usr/bin/env bash
set -euo pipefail
shopt -s extglob

# -----------------------------
# Config via environment
# -----------------------------
# Required env (fail fast if missing)
req=(SRC_HOST SRC_DB SRC_USER SRC_PASSWORD DST_HOST DST_DB DST_USER DST_PASSWORD)
for v in "${req[@]}"; do
  : "${!v:?Missing required env: $v}"
done

# Connection defaults
SRC_PORT="${SRC_PORT:-5432}"
DST_PORT="${DST_PORT:-5432}"
SRC_SSLMODE="${SRC_SSLMODE:-verify-full}"      # Azure typically verify-full
SRC_SSLROOTCERT="${SRC_SSLROOTCERT:-system}"
DST_SSLMODE="${DST_SSLMODE:-disable}"          # local docker usually no TLS

# Table groups to process (each is an env var containing space-separated schema-qualified tables)
TIME_TABLE_GROUP_VARS=(
  LOG_TABLES
  PHILIPS_LOGCURRENT
  MAG_TABLES
)

# Optional: only run a subset, e.g. TABLE_GROUP_FILTER="LOG_TABLES MAG_TABLES"
TABLE_GROUP_FILTER="${TABLE_GROUP_FILTER:-}"

# Date filtering
DAYS_BACK="${DAYS_BACK:-2}"                    # e.g. 2 means NOW() - interval '2 days'
DATE_COL_DEFAULT="${DATE_COL_DEFAULT:-capture_datetime}"
DATE_COL_OVERRIDES="${DATE_COL_OVERRIDES:-}"   # e.g. "schema.tbl:created_at schema2.tbl2:inserted_at"

# Optional absolute start time override (RFC3339/ISO). If set, it wins over DAYS_BACK.
SINCE_TIMESTAMP="${SINCE_TIMESTAMP:-}"         # e.g. "2025-11-01T00:00:00Z"

# Load strategy
TRUNCATE_MODE="${TRUNCATE_MODE:-true}"         # true/false: truncate destination before loading
RESTART_IDENTITY="${RESTART_IDENTITY:-false}"  # true/false: only used if TRUNCATE_MODE=true

echo "Source: $SRC_USER@$SRC_HOST:$SRC_PORT/$SRC_DB (sslmode=$SRC_SSLMODE sslrootcert=$SRC_SSLROOTCERT)"
echo "Dest:   $DST_USER@$DST_HOST:$DST_PORT/$DST_DB (sslmode=$DST_SSLMODE)"

if [[ -n "$SINCE_TIMESTAMP" ]]; then
  echo "Window: since=$SINCE_TIMESTAMP (overrides DAYS_BACK)"
else
  echo "Window: last ${DAYS_BACK} days, DATE_COL_DEFAULT=$DATE_COL_DEFAULT"
fi
[[ -n "$DATE_COL_OVERRIDES" ]] && echo "Overrides: $DATE_COL_OVERRIDES"
echo

# Build an override map for quick lookup
# Format: "schema.table:col schema2.table2:col2"
declare -A OV
if [[ -n "$DATE_COL_OVERRIDES" ]]; then
  for kv in $DATE_COL_OVERRIDES; do
    key="${kv%%:*}"
    val="${kv#*:}"
    OV["$key"]="$val"
  done
fi

# Resolve cutoff expression used on SOURCE side
if [[ -n "$SINCE_TIMESTAMP" ]]; then
  # Use a parameterized literal timestamp at source
  CUTOFF_SQL="(TIMESTAMPTZ '$SINCE_TIMESTAMP')"
else
  # Use interval on the server side
  CUTOFF_SQL="(NOW() - INTERVAL '${DAYS_BACK} days')"
fi

# -----------------------------
# Main loop: over all *_TABLES groups
# -----------------------------
for group_var in "${TIME_TABLE_GROUP_VARS[@]}"; do
  # Honor TABLE_GROUP_FILTER if set
  if [[ -n "$TABLE_GROUP_FILTER" ]]; then
    if ! grep -qw "$group_var" <<<"$TABLE_GROUP_FILTER"; then
      echo ">>> Skipping $group_var due to TABLE_GROUP_FILTER"
      continue
    fi
  fi

  # Get the value of the env var whose name is in $group_var
  tables="${!group_var-}"

  # Skip groups that are unset or empty
  if [[ -z "${tables//[[:space:]]/}" ]]; then
    echo ">>> Skipping $group_var (not set or empty)"
    continue
  fi

  echo "========================================"
  echo ">>> Processing time group: $group_var"
  echo ">>> Tables: $tables"
  echo

  for t in $tables; do
    sch="${t%%.*}"
    tbl="${t#*.}"
    fqtn="${sch}.${tbl}"
    date_col="${OV[$fqtn]:-$DATE_COL_DEFAULT}"

    echo "→ Syncing recent rows for ${fqtn} (date col: ${date_col}, cutoff: ${CUTOFF_SQL})"

    # Optionally truncate destination first
    if [[ "$TRUNCATE_MODE" == "true" ]]; then
      trunc="TRUNCATE TABLE \"${sch}\".\"${tbl}\""
      [[ "$RESTART_IDENTITY" == "true" ]] && trunc+=" RESTART IDENTITY"
      trunc+=" CASCADE;"
      PGPASSWORD="$DST_PASSWORD" PGSSLMODE="$DST_SSLMODE" \
        psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 -c "$trunc"
    fi

    # Safety check: validate the date column exists on source
    if ! PGPASSWORD="$SRC_PASSWORD" PGSSLMODE="$SRC_SSLMODE" PGSSLROOTCERT="$SRC_SSLROOTCERT" \
         psql -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" -Atqc \
         "SELECT 1 FROM information_schema.columns WHERE table_schema='${sch}' AND table_name='${tbl}' AND column_name='${date_col}' LIMIT 1;" \
         | grep -qx '1'; then
      echo "ERROR: Column '${date_col}' not found on ${fqtn} at source. Use DATE_COL_OVERRIDES or set DATE_COL_DEFAULT correctly." >&2
      exit 1
    fi

    # Perform the streaming copy
    # Note: we set UTC to avoid timezone surprises from NOW()
    PGPASSWORD="$SRC_PASSWORD" PGSSLMODE="$SRC_SSLMODE" PGSSLROOTCERT="$SRC_SSLROOTCERT" \
      psql -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" -v ON_ERROR_STOP=1 -q \
        -c "SET TIME ZONE 'UTC';" >/dev/null

    PGPASSWORD="$SRC_PASSWORD" PGSSLMODE="$SRC_SSLMODE" PGSSLROOTCERT="$SRC_SSLROOTCERT" \
      psql -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" -v ON_ERROR_STOP=1 -q \
        -c "COPY (SELECT * FROM \"${sch}\".\"${tbl}\" WHERE \"${date_col}\" >= ${CUTOFF_SQL}) TO STDOUT WITH (FORMAT csv, HEADER false);" \
    | PGPASSWORD="$DST_PASSWORD" PGSSLMODE="$DST_SSLMODE" \
      psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 -q \
        -c "COPY \"${sch}\".\"${tbl}\" FROM STDIN WITH (FORMAT csv);"

    echo "✓ ${fqtn} done"
    echo
  done
done

echo "Recent rows copy complete ✅"
