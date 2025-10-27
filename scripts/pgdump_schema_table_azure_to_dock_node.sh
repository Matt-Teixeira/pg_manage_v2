#!/usr/bin/env bash
set -euo pipefail

# expects env vars already present (coming from --env-file .env)
# SRC_* = Azure, DST_* = local

# Ensure destination DB exists
if ! PGSSLMODE=disable PGPASSWORD="$DST_PASSWORD" \
     psql -h "$DST_HOST" -p "${DST_PORT:-5432}" -U "$DST_USER" -d postgres -tAc \
     "SELECT 1 FROM pg_database WHERE datname = '${DST_DB}'" | grep -q 1; then
  PGSSLMODE=disable PGPASSWORD="$DST_PASSWORD" \
    psql -h "$DST_HOST" -p "${DST_PORT:-5432}" -U "$DST_USER" -d postgres -v ON_ERROR_STOP=1 -qc \
    "CREATE DATABASE \"${DST_DB}\";"
fi

# Dump schema from Azure -> apply to local
PGPASSWORD="$SRC_PASSWORD" PGSSLMODE="${SRC_SSLMODE:-require}" PGSSLROOTCERT="${SRC_SSLROOTCERT:-system}" \
  pg_dump -h "$SRC_HOST" -p "${SRC_PORT:-5432}" -U "$SRC_USER" -d "$SRC_DB" \
    --schema-only --clean --if-exists --no-owner --no-privileges -w \
| PGPASSWORD="$DST_PASSWORD" PGSSLMODE="${DST_SSLMODE:-disable}" \
  psql -h "$DST_HOST" -p "${DST_PORT:-5432}" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1
