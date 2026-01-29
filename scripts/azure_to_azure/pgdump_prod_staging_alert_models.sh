#!/usr/bin/env bash
set -euo pipefail

# --- Load .env (enable via LOAD_ENV=true for standalone runs) ---
if [[ "${LOAD_ENV:-false}" == "true" && -f "${ENV_FILE:-.env}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE:-.env}"
  set +a
fi

# --- Map PROD/STAGING credentials to SRC/DST for Docker container ---
export SRC_HOST="${PROD_HOST:?Missing PROD_HOST}"
export SRC_DB="${PROD_DB:?Missing PROD_DB}"
export SRC_USER="${PROD_USER:?Missing PROD_USER}"
export SRC_PW="${PROD_PW:?Missing PROD_PW}"

export DST_HOST="${STAGING_HOST:?Missing STAGING_HOST}"
export DST_DB="${STAGING_DB:?Missing STAGING_DB}"
export DST_USER="${STAGING_USER:?Missing STAGING_USER}"
export DST_PW="${STAGING_PW:?Missing STAGING_PW}"

docker run --rm --network=host \
  -e SRC_HOST -e SRC_DB -e SRC_USER -e SRC_PW \
  -e DST_HOST -e DST_DB -e DST_USER -e DST_PW \
  -e DEBIAN_FRONTEND=noninteractive \
  postgres:16 bash -lc '
    set -euo pipefail
    apt-get update -qq && apt-get install -y -qq ca-certificates >/dev/null

    echo ">>> Loading PROD alert.models into a temp table on STAGING (no truncation)"
    # 1) Create temp table in STAGING to stage incoming rows
    PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$DST_PW" psql -h "$DST_HOST" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 <<SQL
DROP TABLE IF EXISTS alert.models_incoming;
CREATE TABLE alert.models_incoming
(
  id uuid NOT NULL,
  user_id text NULL,
  system_id text NOT NULL,
  pg_table text NOT NULL,
  field_name text NOT NULL,
  field_name_alias text NOT NULL,
  units_field_name text NULL,
  "operator" text NOT NULL,
  threshold text NOT NULL,
  threshold_units text NULL,
  threshold_offset text NULL,
  severity text NOT NULL,
  last_update timestamptz NOT NULL,
  last_updated_by text NOT NULL,
  default_id uuid NULL,
  customized bool NULL,
  enabled bool NULL,
  snooze_until timestamptz NULL,  -- exists in STAGING only
  notify_frequency int4 NULL,
  PRIMARY KEY (id)
);
SQL

    # 2) Stream from PROD with explicit column list + NULL AS snooze_until, pipe into STAGING temp table
    PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$SRC_PW" \
      psql -h "$SRC_HOST" -U "$SRC_USER" -d "$SRC_DB" -v ON_ERROR_STOP=1 \
      -c "\copy (
        SELECT
          id,
          user_id,
          system_id,
          pg_table,
          field_name,
          field_name_alias,
          units_field_name,
          \"operator\",
          threshold,
          threshold_units,
          threshold_offset,
          severity,
          last_update,
          last_updated_by,
          default_id,
          customized,
          enabled,
          NULL::timestamptz AS snooze_until,
          notify_frequency
        FROM alert.models
      ) TO STDOUT WITH (FORMAT binary)" \
    | PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$DST_PW" \
      psql -h "$DST_HOST" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 \
      -c "COPY alert.models_incoming FROM STDIN WITH (FORMAT binary);"

    # 3) MERGE (upsert) into STAGING alert.models
    PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$DST_PW" psql -h "$DST_HOST" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 <<SQL
MERGE INTO alert.models AS dst
USING alert.models_incoming AS src
ON (dst.id = src.id)
WHEN MATCHED THEN UPDATE SET
  user_id           = src.user_id,
  system_id         = src.system_id,
  pg_table          = src.pg_table,
  field_name        = src.field_name,
  field_name_alias  = src.field_name_alias,
  units_field_name  = src.units_field_name,
  "operator"        = src."operator",
  threshold         = src.threshold,
  threshold_units   = src.threshold_units,
  threshold_offset  = src.threshold_offset,
  severity          = src.severity,
  last_update       = src.last_update,
  last_updated_by   = src.last_updated_by,
  default_id        = src.default_id,
  customized        = src.customized,
  enabled           = src.enabled,
  snooze_until      = src.snooze_until,
  notify_frequency  = src.notify_frequency
WHEN NOT MATCHED THEN INSERT (
  id, user_id, system_id, pg_table, field_name, field_name_alias, units_field_name,
  "operator", threshold, threshold_units, threshold_offset, severity, last_update,
  last_updated_by, default_id, customized, enabled, snooze_until, notify_frequency
) VALUES (
  src.id, src.user_id, src.system_id, src.pg_table, src.field_name, src.field_name_alias, src.units_field_name,
  src."operator", src.threshold, src.threshold_units, src.threshold_offset, src.severity, src.last_update,
  src.last_updated_by, src.default_id, src.customized, src.enabled, src.snooze_until, src.notify_frequency
);
ANALYZE alert.models;
DROP TABLE alert.models_incoming;
SQL

    echo "<<< alert.models synced without truncation"
  '
