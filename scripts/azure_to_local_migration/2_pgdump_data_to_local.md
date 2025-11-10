# pgdump_azure_to_dock_table_data_node.sh

## Purpose
Streams table data from an Azure Postgres instance into a local destination database for a set of schema-qualified tables listed in `TABLES`.

## Flow
1. Verifies all required env vars (source/destination connection info plus `TABLES`) are present.
2. Prints a summary of both endpoints and the tables to be synced.
3. Iterates each table, truncating it on the destination (with `RESTART IDENTITY CASCADE`).
4. Runs `pg_dump --data-only -t schema.table` against Azure using strict TLS and pipes the output to `psql` pointed at the destination, so rows are repopulated immediately.
5. Reports success per table and a final completion line.

## Inputs
- Source: `SRC_HOST`, `SRC_PORT`, `SRC_DB`, `SRC_USER`, `SRC_PASSWORD`, `SRC_SSLMODE`, `SRC_SSLROOTCERT`
- Destination: `DST_HOST`, `DST_PORT`, `DST_DB`, `DST_USER`, `DST_PASSWORD`, `DST_SSLMODE`
- Worklist: `TABLES` (space-separated schema-qualified table names)

## Notes
- Uses `env -i` when invoking `pg_dump` to avoid leaking host environment into the dump process.
- Designed to run on a host with `pg_dump`/`psql` binaries available (e.g., a Node-based environment, hence the file name).

## RUN (Change out .env tables as needed)
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  --env-file .env \
  -v "$PWD":/app -w /app \
  --entrypoint bash \
  pg_manage \
  -lc './scripts/azure_to_local_migration/2_pgdump_data_to_local.sh'
