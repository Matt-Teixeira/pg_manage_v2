#!/usr/bin/env bash
# Copies entire tables (ALL ROWS) from Azure PROD -> Azure STAGING.
# WARNING: Truncates destination tables first (destructive).
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

# --- Tables to copy (space-separated, schema-qualified) ---
export TABLES="${TABLES:-alert.models}"

# --- Run copy in a throwaway postgres:16 container (psql inside) ---
docker run --rm --network=host \
  -e DEBIAN_FRONTEND=noninteractive \
  -e SRC_HOST -e SRC_DB -e SRC_USER -e SRC_PW \
  -e DST_HOST -e DST_DB -e DST_USER -e DST_PW \
  -e TABLES \
  postgres:16 bash -lc '
    set -euo pipefail
    apt-get update -qq && apt-get install -y -qq ca-certificates >/dev/null

    if [ -z "${TABLES:-}" ]; then
      echo "No TABLES specified; nothing to do."
      exit 0
    fi

    for tbl_ref in $TABLES; do
      sch="${tbl_ref%%.*}"
      tbl="${tbl_ref#*.}"

      echo ">>> Processing ${sch}.${tbl} (COPY ALL ROWS)"

      # 1) Truncate destination table and reset sequences (DESTRUCTIVE)
      PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$DST_PW" \
        psql -h "$DST_HOST" -p 5432 -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 \
        -c "TRUNCATE TABLE \"${sch}\".\"${tbl}\" RESTART IDENTITY CASCADE;"

      # 2) Stream ALL rows via binary COPY for speed and type fidelity
      PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$SRC_PW" \
        psql -h "$SRC_HOST" -p 5432 -U "$SRC_USER" -d "$SRC_DB" -v ON_ERROR_STOP=1 \
        -c "\copy (SELECT * FROM \"${sch}\".\"${tbl}\") TO STDOUT WITH (FORMAT binary)" \
      | PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$DST_PW" \
        psql -h "$DST_HOST" -p 5432 -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 \
        -c "COPY \"${sch}\".\"${tbl}\" FROM STDIN WITH (FORMAT binary);"

      # 3) (Optional) Analyze for fresh stats
      PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$DST_PW" \
        psql -h "$DST_HOST" -p 5432 -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 \
        -c "ANALYZE \"${sch}\".\"${tbl}\";"

      echo "<<< Done ${sch}.${tbl}"
    done
  '
