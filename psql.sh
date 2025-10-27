
psql \
  "host=staging-avante-connnected.postgres.database.azure.com \
   port=5432 dbname=staging user=avantehs_admin \
   sslmode=verify-full sslrootcert=/etc/ssl/certs/ca-certificates.crt" \
  -W



PGPASSWORD="$1" PGSSLMODE=verify-full PGSSLROOTCERT=/etc/ssl/certs/ca-certificates.crt \
psql -h staging-avante-connnected.postgres.database.azure.com \
-p 5432 -U avantehs_admin -d staging --no-password

PGPASSWORD="hLRbc47Ngp%F77p%pTASk^MHs2ZF" PGSSLMODE=verify-full PGSSLROOTCERT=/etc/ssl/certs/ca-certificates.crt \
psql -h staging-avante-connnected.postgres.database.azure.com \
-p 5432 -U avantehs_admin -d staging --no-password