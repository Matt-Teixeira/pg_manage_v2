#!/usr/bin/env bash
set -euo pipefail

APP_USER="${APP_USER:-$(whoami)}"
APP_ROOT="${APP_ROOT:-/home/${APP_USER}/apps}"
PG_MANAGE_DIR="$APP_ROOT/pg_manage_v2"
REDIS_ADMIN_DIR="$APP_ROOT/redis-admin"
DATA_ACQ_DIR="$APP_ROOT/data_acquisition"
UTILS_DIR="$APP_ROOT/data_acquisition/utils"

echo "Using APP_ROOT=$APP_ROOT"

# Helper: ensure file exists and is non-empty
require_env_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "ERROR: Missing required .env file: $path" >&2
    exit 1
  fi
  if [[ ! -s "$path" ]]; then
    echo "ERROR: .env file exists but is empty: $path" >&2
    exit 1
  fi
}

echo "========================================"
echo ">>> Checking .env files"
echo

require_env_file "$PG_MANAGE_DIR/.env"
require_env_file "$REDIS_ADMIN_DIR/.env"
require_env_file "$DATA_ACQ_DIR/.env"

# ----------------------------------------
# Step 1: Database Setup & Migration
# ----------------------------------------
echo
echo "========================================"
echo ">>> Step 1: Build pg_manage image & run migrations"
echo

cd "$PG_MANAGE_DIR"

echo "Building pg_manage image..."
docker build -t pg_manage .

COMMON_DOCKER_ARGS=(
  --rm
  --add-host=host.docker.internal:host-gateway
  --env-file .env
  -v "$PWD":/app
  -w /app
)

echo
echo ">>> 1a) Schema-only migration"
docker run "${COMMON_DOCKER_ARGS[@]}" \
  --entrypoint bash pg_manage \
  -lc './scripts/azure_to_local_migration/1_pgdump_tables_to_local.sh'

echo
echo ">>> 1b) Bulk data migration (looping over *_TABLES)"
docker run "${COMMON_DOCKER_ARGS[@]}" \
  --entrypoint bash pg_manage \
  -lc './scripts/azure_to_local_migration/2_pgdump_data_to_local.sh'

echo
echo ">>> 1c) Time-constrained data migration (looping over LOG_TABLES / PHILIPS_LOGCURRENT / MAG_TABLES)"
docker run "${COMMON_DOCKER_ARGS[@]}" \
  --entrypoint bash pg_manage \
  -lc './scripts/azure_to_local_migration/3_pgdump_data_to_local_time_cond.sh'

echo
echo "Database setup & migration complete ✅"

# ----------------------------------------
# Step 2: Redis Containers
# ----------------------------------------
echo
echo "========================================"
echo ">>> Step 2: Start Redis containers (redis-admin)"
echo

cd "$REDIS_ADMIN_DIR"

# Bring up Redis stack
docker compose up -d

echo
echo "Current Redis containers:"
docker compose ps

# ----------------------------------------
# Step 3: Data Acquisition App
# ----------------------------------------
echo
echo "========================================"
echo ">>> Step 3: Data Acquisition app setup"
echo

cd "$DATA_ACQ_DIR"

echo
echo ">>> 3a) Update encrypted DB credentials (uses node:16.20.2 via update_db_creds.sh)"
if [[ -x "./run_scripts/update_db_creds.sh" ]]; then
  ./run_scripts/update_db_creds.sh
else
  echo "ERROR: run_scripts/update_db_creds.sh not found or not executable" >&2
  exit 1
fi

echo
echo ">>> 3b) Create required directories"
mkdir -p files

echo
echo ">>> 3c) Adjust group ownership & permissions"
# Make project group-owned by 'docker' (adjust if group is different on your host)
chgrp -R docker "$DATA_ACQ_DIR"


echo
echo ">>> 3d) Build runtime image (app_tools)"
docker compose build app_tools

echo
echo "========================================"
echo "All provisioning steps complete ✅"
echo
echo "Next typical run example:"
echo "  cd $DATA_ACQ_DIR"
echo "  docker compose run --rm app_tools bash -lc \"npm run job_name\""
