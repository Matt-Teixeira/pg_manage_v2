#!/usr/bin/env bash
set -euo pipefail

# --- Load .env (disable when running under Docker) ---
if [[ "${LOAD_ENV:-false}" == "true" && -f "${ENV_FILE:-.env}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE:-.env}"
  set +a
fi


# --- Required variables check (fail fast with a clear message) ---
req_vars=(SRC_HOST SRC_USER SRC_PASSWORD SRC_DB DST_HOST DST_USER DST_PASSWORD DST_DB)
for v in "${req_vars[@]}"; do
  : "${!v:?Missing required env var: $v}"
done

# --- Defaults (override via env/.env as needed) ---
SRC_PORT="${SRC_PORT:-5432}"
DST_PORT="${DST_PORT:-5432}"
SRC_SSLMODE="${SRC_SSLMODE:-require}"              # Azure usually requires SSL
SRC_SSLROOTCERT="${SRC_SSLROOTCERT:-system}"       # or a path to the CA cert
DST_SSLMODE="${DST_SSLMODE:-disable}"              # local Docker usually no SSL

# --- Ensure destination DB exists ---
if ! PGSSLMODE=disable PGPASSWORD="$DST_PASSWORD" \
     psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d postgres -tAc \
     "SELECT 1 FROM pg_database WHERE datname = '${DST_DB}'" | grep -q 1; then
  PGSSLMODE=disable PGPASSWORD="$DST_PASSWORD" \
    psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d postgres -v ON_ERROR_STOP=1 -qc \
    "CREATE DATABASE \"${DST_DB}\";"
fi

# --- Dump schema from Azure -> apply to local ---
PGPASSWORD="$SRC_PASSWORD" PGSSLMODE="$SRC_SSLMODE" PGSSLROOTCERT="$SRC_SSLROOTCERT" \
  pg_dump -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" \
    --schema-only --clean --if-exists --no-owner --no-privileges -w \
| PGPASSWORD="$DST_PASSWORD" PGSSLMODE="$DST_SSLMODE" \
  psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1
