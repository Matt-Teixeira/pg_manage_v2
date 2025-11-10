docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  --env-file .env \
  -v "$PWD":/app -w /app \
  --entrypoint bash \
  pg_manage \
  -lc './scripts/azure_to_local_migration/3_pgdump_data_to_local_time_cond.sh'
