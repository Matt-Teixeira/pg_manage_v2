# pgdump_prod_staging_alert_models.sh

## Purpose
Synchronizes the `alert.models` table from Azure PROD to STAGING without truncating the destination. It stages rows in a temp table and performs a `MERGE` so that updates and inserts are applied idempotently.

## Flow
1. Defines PROD/STAGING credentials (hardcoded) and launches a `postgres:16` container with TLS prerequisites.
2. Inside the container:
   - Creates a temporary `alert.models_incoming` table on STAGING that mirrors the target schema, including STAGING-only columns such as `snooze_until`.
   - Uses `psql \copy` to stream all rows from PROD `alert.models`, filling `snooze_until` with `NULL` because PROD lacks that column, and loads them into the staging table via binary `COPY`.
   - Executes a `MERGE` statement to upsert into `alert.models`, updating matching IDs and inserting new ones.
   - Runs `ANALYZE` and drops the temp table.

## Notes
- Safe for repeated runs because no truncation occurs; existing records are updated in place.
- Adjust column definitions or transformations in the temp table block if the schema evolves.
