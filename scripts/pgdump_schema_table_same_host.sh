# Secrets / settings (host shell)
export STAGING_PW='hLRbc47Ngp%F77p%pTASk^MHs2ZF'
export DEV_PW='hLRbc47Ngp%F77p%pTASk^MHs2ZF'
export HOST='staging-avante-connnected.postgres.database.azure.com'
export USER='avantehs_admin'
export SRC_DB='staging'
export DST_DB='dev'

docker run --rm \
  -e DEBIAN_FRONTEND=noninteractive \
  -e STAGING_PW -e DEV_PW -e HOST -e USER -e SRC_DB -e DST_DB \
  postgres:16 bash -lc '
    set -e
    apt-get update -qq && apt-get install -y -qq ca-certificates >/dev/null

    PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$STAGING_PW" \
      pg_dump -h "$HOST" -p 5432 -U "$USER" -d "$SRC_DB" \
        --schema-only --clean --if-exists --no-owner --no-privileges -w \
    | PGSSLMODE=verify-full PGSSLROOTCERT=system PGPASSWORD="$DEV_PW" \
      psql -h "$HOST" -p 5432 -U "$USER" -d "$DST_DB" -v ON_ERROR_STOP=1
  '
