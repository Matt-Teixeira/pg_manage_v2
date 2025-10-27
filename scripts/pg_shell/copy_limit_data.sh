#!/usr/bin/env bash
# Copies only recent rows for selected tables (by timestamp), no full-table path.
# NOTE: Truncates destination tables first.
set -euo pipefail

# --- Source (Azure) ---
# - PROD AZURE DB
export STAGING_PW='Drm2nz3x^8of&QyAS5Ssn82VLfcCnu$G' 
export HOST='prod-avante-connected.postgres.database.azure.com'
export USER='avantehs_admin'
export SRC_DB='prod'

# - STAGING AZURE DB
# export STAGING_PW='hLRbc47Ngp%F77p%pTASk^MHs2ZF' 
# export HOST='staging-avante-connnected.postgres.database.azure.com'
# export USER='avantehs_admin'
# export SRC_DB='staging'

# --- Destination (local docker Postgres) ---
export DST_HOST='localhost'
export DST_PORT='5432'
export DST_USER='postgres'
export DST_DB='staging'
export DEV_PW='AidEaBbXJX97VjYP6b'

# --- How far back to pull filtered rows ---
export DAYS_BACK="${DAYS_BACK:-2}"

# --- Default timestamp column name (can be overridden per table) DATE_COL_DEFAULT=created_at ./copy_recent.sh ---
export DATE_COL_DEFAULT="${DATE_COL_DEFAULT:-capture_datetime}"

export FILTERED_TABLES=''
# -- LOG --
# log.ge_ct_gesys log.ge_cv_syserror log.ge_mri_gesys log.philips_ct_eal_events log.philips_cv_eventlog log.siemens_ct log.siemens_mri log.stt_magnet
# log.philips_mri_logcurrent

# -- EDU --
# edu.v1 edu.v2

# -- MAG --
# mag.ge_mm3 mag.ge_mm4 mag.philips_mri_monitoring_data_agg mag.philips_mri_rmmu_history mag.philips_mri_rmmu_long mag.philips_mri_rmmu_short mag.philips_mri_rmmu_magnet mag.siemens mag.siemens_non_tim mag.stt_magnet

docker run --rm --network=host \
  -e DEBIAN_FRONTEND=noninteractive \
  -e HOST -e USER -e SRC_DB -e STAGING_PW \
  -e DST_HOST -e DST_PORT -e DST_USER -e DST_DB -e DEV_PW \
  -e FILTERED_TABLES -e DAYS_BACK -e DATE_COL_DEFAULT \
  postgres:16 bash -lc '
    set -euo pipefail
    apt-get update -qq && apt-get install -y -qq ca-certificates >/dev/null

    for item in $FILTERED_TABLES; do
      # Allow schema.table or schema.table:date_col
      tbl_ref="${item%%:*}"           # before colon
      col_ref="${item#*:}"            # after colon
      if [ "$col_ref" = "$item" ]; then
        date_col="$DATE_COL_DEFAULT"  # no override provided
      else
        date_col="$col_ref"
      fi

      sch="${tbl_ref%%.*}"
      tbl="${tbl_ref#*.}"

      echo ">>> Processing filtered copy for $sch.$tbl (column: $date_col, last ${DAYS_BACK} days)"

      # 1) Truncate destination table and reset sequences
      PGSSLMODE=disable PGPASSWORD="$DEV_PW" \
        psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 \
        -c "TRUNCATE TABLE \"${sch}\".\"${tbl}\" RESTART IDENTITY CASCADE;"

      # 2) Stream recent rows only (binary COPY keeps types and is fast)
      PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$STAGING_PW" \
        psql -h "$HOST" -p 5432 -U "$USER" -d "$SRC_DB" -v ON_ERROR_STOP=1 \
        -c "\copy (SELECT * FROM \"${sch}\".\"${tbl}\" WHERE \"${date_col}\" >= NOW() - INTERVAL '\''${DAYS_BACK} days'\'') TO STDOUT WITH (FORMAT binary)" \
      | PGSSLMODE=disable PGPASSWORD="$DEV_PW" \
        psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 \
        -c "COPY \"${sch}\".\"${tbl}\" FROM STDIN WITH (FORMAT binary);"

      echo "<<< Done $sch.$tbl"
    done
  '
