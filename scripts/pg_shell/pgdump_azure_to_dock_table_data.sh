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

# --- Destination (local docker Postgres published on host:5432) ---
export DST_HOST='localhost'
export DST_PORT='5432'
export DST_USER='postgres'
export DST_DB='staging'
export DEV_PW='AidEaBbXJX97VjYP6b'

# -- PUBLIC --
PUBLIC_TABLES="public.hhm_credentials"
# -- LIFE --
LIFE_TABLES="life.life_cycle"
# -- ALERT --
ALERT_TABLES="alert.models alert.detections alert.notifications alert.offline_hhm_conn alert.offline_mmb_conn alert.reports"
# -- CONFIG --
CONFIG_TABLES="config.acquisition config.edu config.he_tank_volumes config.log config.mag"
# -- UTIL --
UTIL_TABLES="util.ip_sec util.regex_models"
# -- MAG --
MAG_TABLES="mag.ge_mm3_units mag.ge_mm4_units mag.philips_mri_monitoring_data_units mag.siemens_non_tim_units mag.siemens_units"
# -- EDU --
EDU_TABLES="edu.v1_units edu.v2_units"
# -- LOG --
LOG_TABLES="log.lod_reference"

# --- Tables to copy
case "$1" in
  public)   export TABLES="$PUBLIC_TABLES" ;;
  life)     export TABLES="$LIFE_TABLES" ;;
  alert)    export TABLES="$ALERT_TABLES" ;;
  config)   export TABLES="$CONFIG_TABLES" ;;
  util)     export TABLES="$UTIL_TABLES" ;;
  mag)      export TABLES="$MAG_TABLES" ;;
  edu)      export TABLES="$EDU_TABLES" ;;
  log)     export TABLES="$LOG_TABLES" ;;
  *) echo "Unknown group: $1" && exit 1 ;;
esac

# --- Tables to copy ---
# export TABLES="$LOG_TABLES"

docker run --rm --network=host \
  -e DEBIAN_FRONTEND=noninteractive \
  -e HOST -e USER -e SRC_DB -e STAGING_PW \
  -e DST_HOST -e DST_PORT -e DST_USER -e DST_DB -e DEV_PW \
  -e TABLES \
  postgres:16 bash -lc '
    set -euo pipefail
    apt-get update -qq && apt-get install -y -qq ca-certificates >/dev/null

    for t in $TABLES; do
      sch="${t%%.*}"; tbl="${t#*.}"

      # 1) Empty target table first (and reset sequences)
      PGSSLMODE=disable PGPASSWORD="$DEV_PW" \
        psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 \
        -c "TRUNCATE TABLE \"${sch}\".\"${tbl}\" RESTART IDENTITY CASCADE;"

      # 2) Dump DATA ONLY for that table from staging and load into dev
      PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$STAGING_PW" \
        pg_dump -h "$HOST" -p 5432 -U "$USER" -d "$SRC_DB" \
          --data-only -t "${sch}.${tbl}" --no-owner --no-privileges -w \
      | PGSSLMODE=disable PGPASSWORD="$DEV_PW" \
        psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1
    done
  '
