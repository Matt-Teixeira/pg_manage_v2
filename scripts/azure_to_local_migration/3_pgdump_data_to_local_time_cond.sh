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

# What to copy
TABLES="${MAG_TABLES:-}"                 # e.g. "public.users public.site_groups"
: "${TABLES:?Set TABLES to one or more schema-qualified tables}"

# Date filtering
DAYS_BACK="${DAYS_BACK:-2}"                    # e.g. 2 means NOW() - interval '2 days'
DATE_COL_DEFAULT="${DATE_COL_DEFAULT:-capture_datetime}"
DATE_COL_OVERRIDES="${DATE_COL_OVERRIDES:-}"   # e.g. "public.events:created_at public.logs:inserted_at"
# Optional absolute start time override (RFC3339/ISO). If set, it wins over DAYS_BACK.
SINCE_TIMESTAMP="${SINCE_TIMESTAMP:-}"         # e.g. "2025-11-01T00:00:00Z"

# Load strategy
TRUNCATE_MODE="${TRUNCATE_MODE:-true}"         # true/false: truncate destination before loading
RESTART_IDENTITY="${RESTART_IDENTITY:-false}"  # true/false: only used if TRUNCATE_MODE=true

echo "Source: $SRC_USER@$SRC_HOST:$SRC_PORT/$SRC_DB (sslmode=$SRC_SSLMODE sslrootcert=$SRC_SSLROOTCERT)"
echo "Dest:   $DST_USER@$DST_HOST:$DST_PORT/$DST_DB (sslmode=$DST_SSLMODE)"
echo "Tables: $TABLES"
echo "Window: ${SINCE_TIMESTAMP:+since=$SINCE_TIMESTAMP} ${SINCE_TIMESTAMP:+"(overrides DAYS_BACK)"} ${SINCE_TIMESTAMP:+" "}${SINCE_TIMESTAMP:=""} ${SINCE_TIMESTAMP:+" "}"
echo "         ${SINCE_TIMESTAMP:+" "}${SINCE_TIMESTAMP:=""}DAYS_BACK=$DAYS_BACK, DATE_COL_DEFAULT=$DATE_COL_DEFAULT"
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

for t in $TABLES; do
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

  # We COPY via pipeline:
  #   Source: COPY (SELECT * FROM sch.tbl WHERE date_col >= cutoff) TO STDOUT (FORMAT csv)
  #   Dest:   COPY sch.tbl FROM STDIN (FORMAT csv)
  #
  # Assumptions:
  # - Schemas are identical between SRC and DST (column order/types match).
  # - $date_col exists on the source table. (Fail fast if it doesn't.)
  #
  # Safety check: validate the date column exists on source (cheap and clear error)
  PGPASSWORD="$SRC_PASSWORD" PGSSLMODE="$SRC_SSLMODE" PGSSLROOTCERT="$SRC_SSLROOTCERT" \
    psql -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" -Atq <<SQL_CHECK
SELECT 1
FROM information_schema.columns
WHERE table_schema='${sch}' AND table_name='${tbl}' AND column_name='${date_col}'
LIMIT 1;
SQL_CHECK

  # If the check returned empty, raise an error
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

  # Optionally bump sequences to max(id) if you know the PK sequence name—left off by default.
  echo "✓ ${fqtn} done"
  echo
done

echo "Recent rows copy complete ✅"
