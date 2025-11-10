# pgdump_schema_table_azure_to_dock_node.sh

## Purpose
Applies the schema from an Azure-hosted Postgres database (`SRC_*` vars) onto a local Docker/Postgres instance (`DST_*` vars) that is reachable from the same host running the script.

## Flow
1. Checks whether the destination database exists by querying `pg_database`; creates it if missing.
2. Runs `pg_dump --schema-only` against the Azure source using TLS (respecting `SRC_SSLMODE`/`SRC_SSLROOTCERT`).
3. Pipes the dump directly into `psql` connected to the destination with the requested SSL mode (defaults to disabled) so the schema is recreated locally, including `DROP ... IF EXISTS` statements and privilege cleanup flags.

## Inputs
- `SRC_HOST`, `SRC_PORT`, `SRC_DB`, `SRC_USER`, `SRC_PASSWORD`, `SRC_SSLMODE`, `SRC_SSLROOTCERT`
- `DST_HOST`, `DST_PORT`, `DST_DB`, `DST_USER`, `DST_PASSWORD`, `DST_SSLMODE`

## RUN & NOTES
- Script expects variables to be pre-populated (usually via `--env-file .env`).
- `set -euo pipefail` makes the migration stop immediately if any SQL statement fails.

# build your image (if not already)
docker build -t pg_manage .

# Your image already has psql/pg_dump. Tell Docker to skip Node and execute your script:
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  --env-file .env \
  -v "$PWD":/app -w /app \
  --entrypoint bash \
  pg_manage \
  -lc './scripts/azure_to_local_migration/1_pgdump_tables_to_local.sh'

## Notes
With pg_dump ... --schema-only you’ll get:

✅ Tables (columns, defaults, storage params)

✅ Constraints (PK/UK/FK/CK), i.e., your “table associations”

✅ Indexes (including partial/expressions)

✅ Views / materialized views

✅ Sequences (created, but no current values since there’s no data)

✅ Triggers / functions / procedures

✅ Extensions via CREATE EXTENSION (must exist on the destination)

What you’ve explicitly turned off with flags:

❌ Ownership transfer (--no-owner) → everything ends up owned by the user running psql.

❌ Privileges/GRANTs (--no-privileges) → no permissions are restored.

Other things not covered by schema-only dumps:

❌ Data (obviously)

❌ Roles, tablespaces, databases (use pg_dumpall --globals-only if you need roles)

❌ Logical replication subscriptions (publications are dumped; subscriptions are not)

❌ Stats/ANALYZE results, replication slots, server settings