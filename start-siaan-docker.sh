#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./start-siaan-docker.sh [--follow-logs]

Options:
  --follow-logs  Stream `docker compose logs -f siaan` after startup.
  -h, --help     Show this help.

Behavior:
  - Loads ./.env automatically when present.
  - Fetches the latest origin/main and rebases the current branch onto it.
  - Starts the `siaan` service with `docker compose up -d --build`.
  - Persists runtime logs under ./.runtime/logs inside the repo.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="$script_dir/.env"
runtime_dir="$script_dir/.runtime"
follow_logs="false"

if [[ -f "$env_file" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --follow-logs)
      follow_logs="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: '$command_name' is required but was not found in PATH" >&2
    exit 1
  fi
}

ensure_clean_worktree() {
  if [[ -n "$(git -C "$script_dir" status --porcelain --untracked-files=no)" ]]; then
    echo "error: tracked git changes detected; commit or stash them before starting siaan" >&2
    exit 1
  fi
}

sync_with_origin_main() {
  local current_branch

  if ! current_branch="$(git -C "$script_dir" symbolic-ref --quiet --short HEAD)"; then
    echo "error: unable to determine current git branch" >&2
    exit 1
  fi

  echo "Syncing branch '$current_branch' with origin/main"
  git -C "$script_dir" fetch origin main --prune
  git -C "$script_dir" rebase origin/main
}

require_command git
require_command docker
ensure_clean_worktree
sync_with_origin_main

mkdir -p "$runtime_dir/logs"

cd "$script_dir"
docker compose up -d --build siaan

if [[ "$follow_logs" == "true" ]]; then
  exec docker compose logs -f siaan
fi

echo "siaan started via docker compose"
echo "Logs: docker compose logs -f siaan"
