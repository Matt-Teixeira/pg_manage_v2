#!/usr/bin/env bash
# Copies entire tables (ALL ROWS) from Azure PROD -> Azure STAGING.
# WARNING: Truncates destination tables first (destructive).
set -euo pipefail

# --- Source (Azure PROD) ---
export SRC_HOST='prod-avante-connected.postgres.database.azure.com'
export SRC_DB='prod'
export SRC_USER='avantehs_admin'
export SRC_PW='Drm2nz3x^8of&QyAS5Ssn82VLfcCnu$G'   # <-- PROD password

# --- Destination (Azure STAGING) ---
export DST_HOST='staging-avante-connnected.postgres.database.azure.com'
export DST_DB='staging'
export DST_USER='avantehs_admin'
export DST_PW='hLRbc47Ngp%F77p%pTASk^MHs2ZF'       # <-- STAGING password

# --- Tables to copy (space-separated, schema-qualified) ---
# Example:
# export TABLES='public.customers public.sites alert.detections'
export TABLES='alert.models'

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
