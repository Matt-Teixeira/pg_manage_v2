# pgdump_prod_staging_all_table_data.sh

## Purpose
Clones entire tables from Azure PROD into Azure STAGING. Every listed table is truncated on STAGING and then repopulated with all rows streamed from PROD.

## Flow
1. Sets PROD/STAGING connection variables and a space-separated `TABLES` list (schema-qualified).
2. Spins up a disposable `postgres:16` container, installs CA certs, and loops through each table.
3. For each table:
   - Truncates the destination table and resets sequences.
   - Executes `\copy (SELECT * FROM schema.table)` on PROD with verify-full TLS and streams the binary output.
   - Pipes into `COPY ... FROM STDIN` on STAGING, followed by an `ANALYZE` to refresh statistics.
4. Prints progress markers for visibility.

## Notes
- Designed for full refreshes where partial filtering is not acceptable.
- The binary `COPY` path preserves types and performs better than text dumps when moving large datasets.
