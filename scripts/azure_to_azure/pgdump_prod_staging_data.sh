#!/usr/bin/env bash
# Copies only recent rows for selected tables (by timestamp) from Azure PROD -> Azure STAGING.
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
 
# --- How far back to pull filtered rows ---
export DAYS_BACK="${DAYS_BACK:-2}"

# --- Default timestamp column name (can be overridden per table with schema.table:col) ---
# --- capture_datetime - inserted_at
export DATE_COL_DEFAULT="${DATE_COL_DEFAULT:-inserted_at}"

# --- Tables to copy (space-separated). Examples:
export FILTERED_TABLES='alert.detections'
# -- LOG --
# log.ge_ct_gesys log.ge_cv_syserror log.ge_mri_gesys log.philips_ct_eal_events log.philips_cv_eventlog log.siemens_ct log.siemens_mri log.stt_magnet
# log.philips_mri_logcurrent

# -- EDU --
# edu.v1 edu.v2

# -- MAG --
# mag.ge_mm3 mag.ge_mm4 mag.philips_mri_monitoring_data_agg mag.philips_mri_rmmu_history mag.philips_mri_rmmu_long mag.philips_mri_rmmu_short mag.philips_mri_rmmu_magnet mag.siemens mag.siemens_non_tim mag.stt_magnet

# -- ALERT capture_datetime --
# alert.offline_hhm_conn alert.offline_mmb_conn alert.reports
# -- ALERT inserted_at --
# alert.detections

# --- Run copy in a throwaway postgres:16 container (psql inside) ---
docker run --rm --network=host \
  -e DEBIAN_FRONTEND=noninteractive \
  -e SRC_HOST -e SRC_DB -e SRC_USER -e SRC_PW \
  -e DST_HOST -e DST_DB -e DST_USER -e DST_PW \
  -e FILTERED_TABLES -e DAYS_BACK -e DATE_COL_DEFAULT \
  postgres:16 bash -lc '
    set -euo pipefail
    apt-get update -qq && apt-get install -y -qq ca-certificates >/dev/null

    if [ -z "${FILTERED_TABLES:-}" ]; then
      echo "No FILTERED_TABLES specified; nothing to do."
      exit 0
    fi

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

      echo ">>> Processing $sch.$tbl (date column: $date_col, last ${DAYS_BACK} days)"

      # 1) Truncate destination table and reset sequences (DESTRUCTIVE)
      PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$DST_PW" \
        psql -h "$DST_HOST" -p 5432 -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 \
        -c "TRUNCATE TABLE \"${sch}\".\"${tbl}\" RESTART IDENTITY CASCADE;"

      # 2) Stream recent rows only (binary COPY keeps types and is fast)
      #    Azure requires SSL; we use verify-full (+ system CA bundle) on both sides.
      PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$SRC_PW" \
        psql -h "$SRC_HOST" -p 5432 -U "$SRC_USER" -d "$SRC_DB" -v ON_ERROR_STOP=1 \
        -c "\copy (SELECT * FROM \"${sch}\".\"${tbl}\" WHERE \"${date_col}\" >= NOW() - INTERVAL '\''${DAYS_BACK} days'\'') TO STDOUT WITH (FORMAT binary)" \
      | PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$DST_PW" \
        psql -h "$DST_HOST" -p 5432 -U "$DST_USER" -d "$DST_DB" -v ON_ERROR_STOP=1 \
        -c "COPY \"${sch}\".\"${tbl}\" FROM STDIN WITH (FORMAT binary);"

      echo "<<< Done $sch.$tbl"
    done
  '
