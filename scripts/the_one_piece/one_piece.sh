#!/usr/bin/env bash
set -euo pipefail

# Base directory for all app repos
APP_USER="${APP_USER:-$(whoami)}"
APP_ROOT="${APP_ROOT:-/home/${APP_USER}/apps}"

mkdir -p "$APP_ROOT"
cd "$APP_ROOT"

echo "Using APP_ROOT=$APP_ROOT"

clone_if_missing() {
  local repo_url="$1"
  local target_dir="$2"

  if [[ -d "$target_dir/.git" ]]; then
    echo ">>> $target_dir already exists, skipping clone"
  else
    echo ">>> Cloning $repo_url into $target_dir"
    git clone "$repo_url" "$target_dir"
  fi
}

echo "========================================"
echo ">>> Cloning repositories"
echo

clone_if_missing "git@github.com:Matt-Teixeira/pg_manage_v2.git" "pg_manage_v2"
clone_if_missing "git@github.com:Matt-Teixeira/redis-admin.git"   "redis-admin"
clone_if_missing "git@github.com:Matt-Teixeira/data_acquisition.git" "data_acquisition"
clone_if_missing "git@github.com:AvanteHS-RTT/utils.git"          "$APP_ROOT/data_acquisition/utils"

echo
echo "========================================"
echo ">>> Optional: set global git config (only needed once per host)"
echo

if ! git config --global user.email >/dev/null 2>&1; then
  git config --global user.email "matt.teixeira@avantehs.com"
  git config --global user.name  "Matt Teixeira"
  echo "Global git config set."
else
  echo "Global git config already set, skipping."
fi

echo
echo "========================================"
echo ">>> Branch checkout (if needed)"
echo

# Example: switch data_acquisition to DEV_docker branch
if [[ -d "$APP_ROOT/data_acquisition/.git" ]]; then
  cd "$APP_ROOT/data_acquisition"
  # Only switch if not already on DEV_docker
  current_branch="$(git rev-parse --abbrev-ref HEAD || echo "")"
  if [[ "$current_branch" != "DEV_docker" ]]; then
    echo "Switching data_acquisition to DEV_docker..."
    git switch -c DEV_docker --track origin/DEV_docker || git switch DEV_docker
  else
    echo "data_acquisition already on DEV_docker"
  fi
fi

echo
echo "========================================"
echo "NEXT STEPS:"
echo "1) Populate the following .env files manually:"
echo "   - $APP_ROOT/pg_manage_v2/.env        (Azure/local PG creds, *_TABLES, DAYS_BACK, etc.)"
echo "   - $APP_ROOT/redis-admin/.env        (Redis ports/passwords)"
echo "   - $APP_ROOT/data_acquisition/.env   (PG, Redis, paths, UID/GID, etc.)"
echo
echo "2) When those are ready, run:  ./02_provision_env.sh"
echo
echo "Bootstrap complete ✅"
