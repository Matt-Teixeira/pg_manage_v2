#!/usr/bin/env bash
# Preflight for pg_manage_v2 — validates the environment the scheduled
# maintenance scripts (and the dormant seeding tooling) actually use.
# Fleet paradigm (data_acquisition/docs/migration_CLAUDE.md); skeleton from
# ops-dashboard's preflight (newest copy — explicit exit 0), checks adapted
# to this repo's admin shape: host bash scripts, no container runs, no logger.
#
# A clean run reports ZERO warnings: treat a persistent warning as a bug in
# the check itself, or it trains people to ignore output.
# Exit codes: 0 = pass (or warnings only), 1 = critical errors found.
set -u
cd "$(dirname "$0")"

ERRORS=0; WARNINGS=0; OKS=0
ok()    { echo "  OK    $*"; OKS=$((OKS+1)); }
warn()  { echo "  WARN  $*"; WARNINGS=$((WARNINGS+1)); }
error() { echo "  ERROR $*"; ERRORS=$((ERRORS+1)); }
info()  { echo "        $*"; }
section(){ echo; echo "== $* =="; }

# Read KEY= from .env, stripping quotes, dotenv-style inline comments and
# trailing whitespace. NEVER source a fleet .env (the $$-in-URI lesson).
env_val() {
    grep "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- \
        | sed -e 's/[[:space:]]\+#.*$//' -e 's/[[:space:]]*$//' \
              -e "s/^['\"]//" -e "s/['\"]$//"
}

PG_DB="${PG_DB:-staging}"   # per-server DB name, same default as the scripts

# ------------------------------------------------------- 1. identity/location
section "Identity"
APP_NAME_V="$(env_val APP_NAME)"
if [ ! -f .env ]; then
    error ".env missing — copy .env.example and fill it in"
elif [ "$APP_NAME_V" != "pg_manage_v2" ]; then
    error ".env: APP_NAME='$APP_NAME_V' (expected pg_manage_v2) — build-release.sh derives its destination from this"
else
    ok "APP_NAME=$APP_NAME_V"
fi
RELEASE_SHA_V="$(env_val RELEASE_SHA)"
if [ "$(pwd)" = "/opt/apps/pg_manage_v2" ]; then
    if [ -n "$RELEASE_SHA_V" ]; then
        ok "release copy: RELEASE_SHA=$RELEASE_SHA_V (stamped by build-release.sh)"
    else
        error "release copy but RELEASE_SHA missing — script logs would record 'dev-tree'; was build-release.sh bypassed?"
    fi
else
    if [ -n "$RELEASE_SHA_V" ]; then
        error "dev tree but RELEASE_SHA present — never set it by hand (dev runs must record 'dev-tree')"
    else
        ok "dev tree: no RELEASE_SHA (runs record 'dev-tree')"
    fi
fi

# ------------------------------------------------------------------- 2. docker
section "Docker"
if docker ps >/dev/null 2>&1; then ok "docker daemon reachable"; else error "docker daemon not reachable as $(id -un)"; fi
if id -nG | grep -qw docker; then ok "$(id -un) is in the docker group"; else error "$(id -un) not in docker group"; fi
if docker compose version >/dev/null 2>&1; then ok "docker compose available (infra/pg_db ops)"; else error "docker compose not available"; fi

PGDB_HEALTH="$(docker inspect -f '{{.State.Health.Status}}' pg_db 2>/dev/null || true)"
if [ "$PGDB_HEALTH" = "healthy" ]; then
    ok "pg_db container running and healthy"
else
    error "pg_db container not healthy (status: ${PGDB_HEALTH:-not running}) — both scheduled scripts depend on it"
fi

for r in redis-PROD redis-STAGING redis_dev-0-4 redis_dev-0-5; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$r" 2>/dev/null || true)" = "true" ]; then
        ok "$r running"
    else
        error "$r not running — backup.sh SAVEs all four instances and fails loud on a missing one"
    fi
done

# --------------------------------------------- 3. maintenance-script environment
section "Maintenance-script environment"
BK_BASE=/opt/resources/backups
if [ -d "$BK_BASE" ] && [ -w "$BK_BASE" ]; then
    ok "$BK_BASE writable"
else
    error "$BK_BASE missing or not writable by $(id -un) — backup.sh cannot run"
fi

BK_LOG="$BK_BASE/backup.log"
if [ -f "$BK_LOG" ]; then
    last="$(tail -1 "$BK_LOG")"
    if [ -z "$(find "$BK_LOG" -mmin -1560 2>/dev/null)" ]; then
        error "backup.log stale (last write >26h ago) — nightly backup did not run; last line: $last"
    elif echo "$last" | grep -q ' OK '; then
        ok "backup.log fresh, last line OK ($(echo "$last" | cut -d' ' -f1))"
    elif echo "$last" | grep -q ' SKIPPED'; then
        warn "backup.log last line is SKIPPED — a previous backup was still running; check for a wedged pg_dump"
    else
        error "backup.log last line is not OK: $last"
    fi
else
    error "$BK_LOG missing — no backup has ever logged here"
fi

WD_LOG=/opt/run-logs/partition-watchdog.log
if { [ -f "$WD_LOG" ] && [ -w "$WD_LOG" ]; } || { [ ! -f "$WD_LOG" ] && [ -w /opt/run-logs ]; }; then
    ok "watchdog log writable ($WD_LOG)"
else
    error "$WD_LOG not writable by $(id -un) — check-partition-horizon.sh cannot record runs"
fi

# The schedule lives in matt-teixeira's USER crontab (standing decision:
# pre-existing user-crontab entries stay put until the fleet consolidation).
CRON_N="$(crontab -l 2>/dev/null | grep -v '^ *#' | grep -c '/opt/apps/pg_manage_v2/scripts/' || true)"
if [ "$CRON_N" = "2" ]; then
    ok "2 cron entries reference /opt/apps/pg_manage_v2/scripts (backup + watchdog)"
elif [ "$CRON_N" = "0" ]; then
    warn "no pg_manage_v2 entries in THIS user's crontab — expected 2 in matt-teixeira's (run preflight as that user to verify the schedule)"
else
    warn "$CRON_N cron entries reference this app (expected 2) — compare against scripts/README.md"
fi

# --------------------------------------------------------------------- 4. .env
section ".env (seeding tooling)"
if [ -f .env ]; then
    # DST_* is rotation-critical (DST_PASSWORD is the registered superuser
    # value) — absence is an error. The Azure-side groups only matter when the
    # dormant seeding tooling is used; presence-only, and absence warns so a
    # trimmed .env gets reconciled against .env.example.
    for key in DST_HOST DST_PORT DST_USER DST_PASSWORD DST_DB; do
        v="$(env_val "$key")"
        if [ -z "$v" ]; then
            error ".env: $key is empty or missing (rotation-registered group)"
        else
            case "$key" in
                *PASSWORD*) ok ".env: $key set (masked)" ;;
                *) ok ".env: $key=$v" ;;
            esac
        fi
    done
    AZ_MISSING=0
    for key in SRC_HOST SRC_PORT SRC_USER SRC_PASSWORD SRC_DB \
               PROD_HOST PROD_PORT PROD_DB PROD_USER PROD_PW \
               STAGING_HOST STAGING_PORT STAGING_DB STAGING_USER STAGING_PW; do
        [ -n "$(env_val "$key")" ] || { AZ_MISSING=$((AZ_MISSING+1)); warn ".env: $key empty/missing (seeding tooling)"; }
    done
    [ "$AZ_MISSING" = 0 ] && ok "Azure-side keys all present (presence-only — probing Azure prod is deliberately out of scope)"
fi

# ------------------------------------------------- 5. external services (AUTH)
section "External services (authenticated checks)"

# 5a. Superuser credential (DST_PASSWORD) — the rotation-registered secret.
# MUST run from a sibling container on pg_net, never `docker exec pg_db psql`:
# pg_hba trusts local/loopback, so an exec'd psql succeeds with a WRONG
# password (that path hid a rotated password for three weeks on a sibling
# app). Deliberate deviation from the tooling's own route
# (host.docker.internal): the point here is credential validity, and pg_net
# forces the hostssl+scram rule. AUTH-ONLY: SELECT 1, nothing written.
DST_USER_V="$(env_val DST_USER)"; DST_PW_V="$(env_val DST_PASSWORD)"
DST_SSLMODE_V="$(env_val DST_SSLMODE)"; DST_SSLMODE_V="${DST_SSLMODE_V:-require}"
if [ -z "$DST_PW_V" ]; then
    error "DST_PASSWORD empty — cannot verify the rotation-registered credential"
elif ! docker image inspect postgres:16 >/dev/null 2>&1; then
    # An unverified check must never look like a passing one.
    warn "postgres:16 image absent — superuser auth NOT verified (fix: docker pull postgres:16)"
else
    out=$(docker run --rm --network pg_net \
        -e PGPASSWORD="$DST_PW_V" -e PGSSLMODE="$DST_SSLMODE_V" -e PGCONNECT_TIMEOUT=10 \
        postgres:16 \
        psql -h pg_db -p 5432 -U "$DST_USER_V" -d "$PG_DB" -tAc "SELECT 'ok'" 2>&1)
    if [ "$(echo "$out" | tail -1 | tr -d '[:space:]')" = "ok" ]; then
        ok "PostgreSQL auth OK as $DST_USER_V (sibling container, sslmode=$DST_SSLMODE_V, db=$PG_DB)"
    elif echo "$out" | grep -qi "password authentication failed\|no password supplied"; then
        error "PostgreSQL rejected DST_PASSWORD — likely a rotation this copy missed; both .env copies need the current value"
    else
        error "PostgreSQL check failed: $(echo "$out" | head -2)"
    fi
fi

# 5b. The scripts' own access path: `docker exec pg_db psql` under local
# trust. This proves EXEC ACCESS for backup.sh/the watchdog, NOT credentials
# (local trust accepts anything) — 5a above is the credential check.
if docker exec -i pg_db psql -U postgres -d "$PG_DB" -tAc "SELECT 1" >/dev/null 2>&1; then
    ok "docker-exec psql access to db '$PG_DB' (the scripts' own path — access check, not auth)"
else
    error "docker exec pg_db psql -d $PG_DB failed — backup.sh and the watchdog both use this path"
fi

# 5c. Redis: authenticated PING per instance via its own mounted auth.conf —
# exactly backup.sh's mechanism. redis-cli exits 0 even on NOAUTH, so the
# REPLY TEXT is checked, never the exit code (the backup.sh lesson).
for r in redis-PROD redis-STAGING redis_dev-0-4 redis_dev-0-5; do
    reply=$(docker exec "$r" sh -c 'redis-cli -a "$(awk "/^requirepass/{print \$2}" /usr/local/etc/redis/auth.conf)" --no-auth-warning PING' 2>/dev/null || true)
    if [ "$reply" = "PONG" ]; then
        ok "$r authenticated PING -> PONG"
    else
        error "$r authenticated PING failed (reply: '${reply:-none}') — backup.sh's SAVE would fail the same way"
    fi
done

# ---------------------------------------------------------------- 6. app files
section "Application files"
for f in scripts/backup.sh scripts/check-partition-horizon.sh build-release.sh preflight-check.sh .env.example CLAUDE.md infra/pg_db/docker-compose.yaml infra/pg_db/RUNBOOK.md; do
    if [ -f "$f" ]; then ok "$f present"; else error "$f missing"; fi
done
for f in scripts/backup.sh scripts/check-partition-horizon.sh; do
    [ -x "$f" ] || error "$f not executable — cron invokes it directly"
done
if docker compose -f infra/pg_db/docker-compose.yaml config --quiet 2>/dev/null; then
    ok "infra/pg_db/docker-compose.yaml validates (config --quiet)"
else
    error "infra/pg_db/docker-compose.yaml fails 'docker compose config --quiet'"
fi

# ------------------------------------------------------------------ 7. summary
section "Summary"
echo "  $OKS ok, $WARNINGS warnings, $ERRORS errors"
if [ "$ERRORS" -gt 0 ]; then
    echo "  RESULT: FAIL"
    exit 1
fi
[ "$WARNINGS" -gt 0 ] && echo "  RESULT: PASS (with warnings — a clean run should report zero)"
[ "$WARNINGS" -eq 0 ] && echo "  RESULT: PASS"
# Explicit success exit: without it the script's status is the last [ ] test,
# which is FALSE on a warnings-only run (the bug found in monday's copy).
exit 0
