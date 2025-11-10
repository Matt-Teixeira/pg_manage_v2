# pgdump_prod_staging_data.sh

## Purpose
Pulls only *recent* rows (default: last 2 days) for selected tables from the Azure PROD database into Azure STAGING, truncating each target table before loading the filtered subset.

## Flow
1. Defines Azure PROD/STAGING connection credentials along with tunables such as `DAYS_BACK`, `DATE_COL_DEFAULT`, and `FILTERED_TABLES`.
2. Runs a temporary `postgres:16` container (network=host) so `psql` and CA bundles are available.
3. For every entry in `FILTERED_TABLES`, optionally honoring a custom timestamp column via `schema.table:column` syntax:
   - Truncates and resets the destination table on STAGING.
   - Uses `psql \copy` to stream rows newer than `NOW() - DAYS_BACK` from PROD over TLS.
   - Pipes the binary stream directly into STAGING via `COPY ... FROM STDIN`.
4. Prints progress for each table.

## Notes
- The script is destructive because of the initial `TRUNCATE ... RESTART IDENTITY CASCADE` step.
- Designed for operational “recent data refreshes” without copying entire historical tables.
