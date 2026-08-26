#!/usr/bin/env bash
# Release pg_manage_v2: mirror THIS working tree to /opt/apps/<APP_NAME>,
# apply the #RELEASE: .env overrides, stamp the released commit, chown to svc.
# Fleet paradigm (data_acquisition/docs/migration_CLAUDE.md Part 1) — adapted
# from data_acquisition's build-release.sh.
#
# Admin-repo shape: NO image build step. The scheduled jobs are host bash
# scripts; the pg_manage seeding image is operator-built (setup doc STEP 5)
# and not part of a release. That also means no svc HOME dance is needed —
# nothing here runs docker as svc.
#
# Flow:
#   1. Clean-tree guard      — refuse to release a dirty tree (untracked counts)
#   2. Mirror via tar-pipe   — working tree -> $DEST, with excludes
#   3. Transform .env        — apply #RELEASE:KEY=VALUE, strip markers
#      (no #RELEASE: keys exist today; machinery kept so adding one Just Works)
#   4. Stamp RELEASE_SHA     — into the DEPLOYED .env only (idempotent);
#      scripts/backup.sh + scripts/check-partition-horizon.sh grep it into
#      their log lines (sha=<sha>), 'dev-tree' when absent
#   5. chown svc:docker      — cron (matt-teixeira) reads/executes via group
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
RELEASE_USER="svc"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"

for arg in "$@"; do
    case "$arg" in
        --allow-dirty) ALLOW_DIRTY=1 ;;
        *) echo "ERROR: unknown argument '$arg' (only --allow-dirty is accepted)"; exit 1 ;;
    esac
done

# --- 1. Clean-tree guard (BEFORE anything touches $DEST) ---------------------
# The tar-pipe mirrors the WORKING TREE, not a git ref. A dirty release would
# put code in /opt/apps that exists in no commit: unreproducible, untraceable,
# nothing to roll back to. Untracked files count — tar would copy them.
GIT_SHA="unknown"
if git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_SHA="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    GIT_BRANCH="$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

    if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
        if [ "$ALLOW_DIRTY" = "1" ]; then
            echo "WARNING: working tree is dirty, releasing anyway (--allow-dirty)."
        else
            echo "ERROR: working tree is dirty — refusing to release."
            git -C "$SRC" status --short
            exit 1
        fi
    fi

    if git -C "$SRC" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
        AHEAD="$(git -C "$SRC" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)"
        [ "$AHEAD" -gt 0 ] && echo "WARNING: $AHEAD commit(s) on '$GIT_BRANCH' not pushed to upstream."
    else
        echo "WARNING: branch '$GIT_BRANCH' has no upstream — this release exists only on this host."
    fi
else
    echo "WARNING: $SRC is not a git repository — cannot verify what is being released."
fi

# --- Destination (derived, then re-validated) --------------------------------
APP_NAME="$(grep -E '^APP_NAME=' "$SRC/.env" | head -1 | cut -d= -f2 | tr -d '[:space:]')"
[ -n "$APP_NAME" ] || { echo "ERROR: APP_NAME not set in $SRC/.env"; exit 1; }
DEST="/opt/apps/$APP_NAME"
case "$DEST" in
    /opt/apps/?*) : ;;
    *) echo "ERROR: refusing unsafe DEST '$DEST'"; exit 1 ;;
esac
if [ "$DEST" = "$SRC" ]; then
    echo "ERROR: SRC and DEST are the same directory — run this from a dev tree, not the release copy."
    exit 1
fi

echo "==> releasing $APP_NAME  commit: $GIT_SHA  ->  $DEST"

# --- 2. Wipe + tar-pipe mirror -----------------------------------------------
# This repo has no gitignored bulk (git status --ignored shows only .env, which
# MUST ship — it is transformed in place below). Excludes are therefore just
# repo plumbing. node_modules is excluded/preserved for symmetry with the fleet
# scripts even though none exists on the host today (deps live in the image).
# Script exec bits (tracked 100755) survive the tar-pipe.
sudo mkdir -p "$DEST"
sudo find "$DEST" -mindepth 1 -maxdepth 1 ! -name node_modules -exec rm -rf {} +
sudo tar -C "$SRC" \
    --exclude='./node_modules' \
    --exclude='./.git' \
    --exclude='./.claude' \
    -cf - . | sudo tar -C "$DEST" -xf -

# --- 3. Apply #RELEASE: overrides to the DEPLOYED .env ------------------------
# Two passes over the same file: collect overrides, then rewrite active lines
# and drop the marker lines. Idempotent — after one pass no markers remain.
tmp_env="$(mktemp)"
sudo awk '
    FNR==NR {
        if ($0 ~ /^#RELEASE:/) {
            l = substr($0, 10)
            e = index(l, "=")
            if (e > 0) {
                k = substr(l, 1, e-1)
                v = substr(l, e+1)
                sub(/[ \t]+#.*$/, "", v)
                gsub(/^[ \t]+|[ \t]+$/, "", k)
                gsub(/^[ \t]+|[ \t]+$/, "", v)
                ov[k] = v
            }
        }
        next
    }
    {
        if ($0 ~ /^#RELEASE:/) next
        if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
            e = index($0, "=")
            k = substr($0, 1, e-1)
            if (k in ov) { print k "=" ov[k]; next }
        }
        print
    }
' "$DEST/.env" "$DEST/.env" > "$tmp_env"
sudo cp "$tmp_env" "$DEST/.env"
rm -f "$tmp_env"

# --- 4. Stamp RELEASE_SHA (idempotent: delete then append) ---------------------
# backup.sh and check-partition-horizon.sh grep this into every log line they
# write (backup.log / partition-watchdog.log), so the run record identifies
# the commit that produced it. Never set by hand; a dev clone has no key and
# logs 'dev-tree' instead.
sudo sed -i '/^# Injected by build-release.sh/d; /^RELEASE_SHA=/d' "$DEST/.env"
printf '\n# Injected by build-release.sh — do not edit by hand.\nRELEASE_SHA=%s\n' \
    "$GIT_SHA" | sudo tee -a "$DEST/.env" >/dev/null

# --- 5. Ownership ------------------------------------------------------------
sudo chown -R "${RELEASE_USER}:docker" "$DEST"
# svc owns it; docker-group members (the admins on this box, incl. the cron
# user matt-teixeira) read and execute via group. .env stays group-readable
# (640): the scripts must grep RELEASE_SHA from it at run time.
sudo chmod 640 "$DEST/.env" || true

echo "==> release complete: $DEST  commit: $GIT_SHA  (no image build — admin repo)"
echo "    verify: grep '^RELEASE_SHA=' $DEST/.env ; (cd $DEST && bash preflight-check.sh)"
