#!/usr/bin/env bash
set -euo pipefail

# --- Source (Azure) ---
# PROD AZURE DB
export STAGING_PW='Drm2nz3x^8of&QyAS5Ssn82VLfcCnu$G' 
export HOST='prod-avante-connected.postgres.database.azure.com'
export USER='avantehs_admin'
export SRC_DB='prod'

# STAGING AZURE DB
# export STAGING_PW='hLRbc47Ngp%F77p%pTASk^MHs2ZF' 
# export HOST='staging-avante-connnected.postgres.database.azure.com'
# export USER='avantehs_admin'
# export SRC_DB='staging'

# ---- Destination (Local Docker Postgres) ----
export DST_HOST='localhost'
export DST_PORT='5432'
export DST_USER='postgres'
export DST_DB='dev'
export DEV_PW='AidEaBbXJX97VjYP6b'

docker run --rm --network=host \
  -e DEBIAN_FRONTEND=noninteractive \
  -e STAGING_PW -e DEV_PW -e HOST -e USER -e SRC_DB \
  -e DST_HOST -e DST_PORT -e DST_USER -e DST_DB \
  postgres:16 bash -lc '
    set -e
    apt-get update -qq && apt-get install -y -qq ca-certificates >/dev/null

    # --- Ensure destination DB exists ---
    # psql returns exit code 0 even if the SELECT finds no rows, so pipe to grep
    if ! PGSSLMODE=disable PGPASSWORD="$DEV_PW" \
         psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d postgres -tAc \
         "SELECT 1 FROM pg_database WHERE datname = '\''$DST_DB'\''" | grep -q 1; then
      PGSSLMODE=disable PGPASSWORD="$DEV_PW" \
        psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d postgres -v ON_ERROR_STOP=1 -qc \
        "CREATE DATABASE \"$DST_DB\";"
    fi

    # Dump schema from staging (TLS verify) -> apply to local dev (no TLS)
    PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$STAGING_PW" \
      pg_dump -h "$HOST" -p 5432 -U "$USER" -d "$SRC_DB" \
        --schema-only --clean --if-exists --no-owner --no-privileges -w \
    | PGSSLMODE=disable PGPASSWORD="$DEV_PW" \
      psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1
  '
