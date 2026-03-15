#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./start-siaan.sh [--bootstrap] [--port <port>] [--workflow <path>]

Options:
  --bootstrap        Run mise/mix setup steps before starting.
  --port <port>      Enable dashboard on the given port.
  --workflow <path>  Workflow file path (default: elixir/WORKFLOW.md).
  -h, --help         Show this help.

Environment:
  ./.env             Loaded automatically when present.
  GITHUB_TOKEN       Required for GitHub tracker mode.
  GH_TOKEN           Accepted as an alias for GITHUB_TOKEN.

This script starts siaan directly on the host. For containerized runtime usage,
prefer: docker compose up -d --build siaan
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elixir_dir="$script_dir/elixir"
env_file="$script_dir/.env"

resolve_absolute_path() {
  local path="$1"
  local dir
  local base
  local absolute_dir

  dir="$(dirname "$path")"
  base="$(basename "$path")"

  if absolute_dir="$(cd "$dir" 2>/dev/null && /bin/pwd -P)"; then
    printf '%s/%s\n' "$absolute_dir" "$base"
  else
    printf '%s\n' "$path"
  fi
}

extract_tracker_kind() {
  local workflow_path="$1"

  awk '
    function normalize_kind_value(value) {
      sub(/^[[:space:]]*kind:[[:space:]]*/, "", value)
      sub(/[[:space:]]*(,|}|#.*)?$/, "", value)
      gsub(/^["'"'"']/, "", value)
      gsub(/["'"'"']$/, "", value)
      return tolower(value)
    }

    function print_inline_tracker_kind(line, candidate) {
      candidate = line

      if (!match(candidate, /kind:[[:space:]]*["'"'"']?[^,}#[:space:]]+["'"'"']?/)) {
        return 0
      }

      candidate = substr(candidate, RSTART, RLENGTH)
      print normalize_kind_value(candidate)
      return 1
    }

    BEGIN {
      in_tracker = 0
      tracker_indent = -1
    }

    {
      if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) {
        next
      }

      match($0, /[^[:space:]]/)
      indent = RSTART ? RSTART - 1 : 0
    }

    /^[[:space:]]*tracker:[[:space:]]*{/ {
      if (print_inline_tracker_kind($0)) {
        exit
      }

      next
    }

    /^[[:space:]]*tracker:[[:space:]]*$/ {
      in_tracker = 1
      tracker_indent = indent
      next
    }

    in_tracker {
      if (indent <= tracker_indent) {
        exit
      }

      if ($0 ~ /^[[:space:]]*kind:[[:space:]]*/) {
        line = $0
        sub(/^[[:space:]]*kind:[[:space:]]*/, "", line)
        sub(/[[:space:]]*(#.*)?$/, "", line)
        gsub(/^["'"'"']/, "", line)
        gsub(/["'"'"']$/, "", line)
        print tolower(line)
        exit
      }
    }
  ' "$workflow_path"
}

bootstrap="false"
port=""
workflow="$elixir_dir/WORKFLOW.md"

if [[ -f "$env_file" ]]; then
  # Load simple KEY=VALUE entries from the repo-local .env for local runs.
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
fi

if [[ -z "${GITHUB_TOKEN:-}" ]] && [[ -n "${GH_TOKEN:-}" ]]; then
  export GITHUB_TOKEN="$GH_TOKEN"
fi

if [[ -z "${GH_TOKEN:-}" ]] && [[ -n "${GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="$GITHUB_TOKEN"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap)
      bootstrap="true"
      shift
      ;;
    --port)
      if [[ $# -lt 2 ]]; then
        echo "error: --port requires a value" >&2
        usage
        exit 1
      fi
      port="$2"
      shift 2
      ;;
    --workflow)
      if [[ $# -lt 2 ]]; then
        echo "error: --workflow requires a value" >&2
        usage
        exit 1
      fi
      workflow="$2"
      shift 2
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

workflow="$(resolve_absolute_path "$workflow")"

if ! command -v mise >/dev/null 2>&1; then
  echo "error: 'mise' is required. Install from https://mise.jdx.dev/getting-started.html" >&2
  exit 1
fi

if [[ ! -f "$workflow" ]]; then
  echo "error: workflow file not found: $workflow" >&2
  exit 1
fi

tracker_kind="$(extract_tracker_kind "$workflow")"

if [[ "$tracker_kind" == "github" ]] && [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "error: GITHUB_TOKEN is not set." >&2
  echo "set it in .env, export GITHUB_TOKEN=..., or export GH_TOKEN=..." >&2
  exit 1
fi

cd "$elixir_dir"

if [[ "$bootstrap" == "true" ]]; then
  mise trust
  mise install
  mise exec -- mix setup
  mise exec -- mix build
fi

cmd=(
  mise exec -- ./bin/siaan
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
)

if [[ -n "$port" ]]; then
  cmd+=(--port "$port")
fi

cmd+=("$workflow")

echo "Starting siaan with workflow: $workflow"
exec "${cmd[@]}"
